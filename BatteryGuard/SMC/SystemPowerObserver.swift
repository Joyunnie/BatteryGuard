// SystemPowerObserver.swift
// Delays the final sleep acknowledgement until battery cleanup completes.

import Foundation
import IOKit
import IOKit.pwr_mgt

@MainActor
protocol SystemPowerObserving: AnyObject {
    var requiresChargingDisabledForSleepTransition: Bool { get }
    func start(
        willSleep: @escaping @MainActor (_ deadlineUptimeNanoseconds: UInt64) async -> Bool,
        didWake: @escaping @MainActor () -> Void
    ) throws
    func resolvePendingSleepRequestsForShutdown()
    func stop()
}

@MainActor
final class SystemPowerObserver: SystemPowerObserving {
    typealias SleepHandler = @MainActor (_ deadlineUptimeNanoseconds: UInt64) async -> Bool

    private static let acknowledgementDeadline: TimeInterval = 25
    private let transport: SystemPowerTransport
    private var sleepHandler: SleepHandler?
    private var wakeHandler: (@MainActor () -> Void)?
    private struct PendingSleepRequest {
        let canVeto: Bool
        let operation: SleepAcknowledgedOperation
    }

    private var pendingSleepOperations: [Int: PendingSleepRequest] = [:]
    private var sleepTransitionInProgress = false

    var requiresChargingDisabledForSleepTransition: Bool { sleepTransitionInProgress }

    init(transport: SystemPowerTransport = IOKitSystemPowerTransport()) {
        self.transport = transport
    }

    func start(
        willSleep: @escaping SleepHandler,
        didWake: @escaping @MainActor () -> Void
    ) throws {
        stop()
        sleepHandler = willSleep
        wakeHandler = didWake

        do {
            try transport.start { [weak self] messageType, token in
                self?.receive(messageType: messageType, token: token)
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        resolvePendingSleepRequestsForShutdown()
        transport.stop()
        sleepHandler = nil
        wakeHandler = nil
        sleepTransitionInProgress = false
    }

    func resolvePendingSleepRequestsForShutdown() {
        for (_, request) in pendingSleepOperations {
            request.operation.invalidate(resolving: request.canVeto ? .reject : .allow)
        }
        pendingSleepOperations.removeAll()
    }

    private func receive(messageType: UInt32, token: Int) {
        let deadline = Self.monotonicDeadline(after: Self.acknowledgementDeadline)
        switch messageType {
        case SystemPowerMessage.canSystemSleep:
            // Latch the whole accepted/rejected negotiation window. Shutdown is
            // conservative until IOKit reports that sleep was cancelled or ended.
            sleepTransitionInProgress = true
            handleSleepRequest(token: token, canVeto: true, deadline: deadline)
        case SystemPowerMessage.systemWillSleep:
            // Keep this latched after acknowledgement: IOAllowPowerChange means
            // the non-vetoable transition may still suspend the process.
            sleepTransitionInProgress = true
            handleSleepRequest(token: token, canVeto: false, deadline: deadline)
        case SystemPowerMessage.systemWillNotSleep:
            wakeHandler?()
            sleepTransitionInProgress = false
        case SystemPowerMessage.systemHasPoweredOn:
            wakeHandler?()
            sleepTransitionInProgress = false
        default:
            break
        }
    }

    private func handleSleepRequest(token: Int, canVeto: Bool, deadline: UInt64) {
        guard let sleepHandler else {
            transport.resolve(token: token, decision: .allow)
            return
        }
        let timeoutDecision: SleepAcknowledgementDecision = canVeto ? .reject : .allow
        let operation = SleepAcknowledgedOperation(
            deadlineUptimeNanoseconds: deadline,
            timeoutDecision: timeoutDecision
        ) { [weak self, transport] decision in
            transport.resolve(token: token, decision: decision)
            Task { @MainActor in
                self?.completeSleepRequest(token: token)
            }
        }
        pendingSleepOperations[token] = PendingSleepRequest(
            canVeto: canVeto,
            operation: operation
        )
        let task = Task { @MainActor in
            let prepared = await sleepHandler(deadline)
            operation.finish(prepared || !canVeto ? .allow : .reject)
        }
        operation.setTask(task)
    }

    private func completeSleepRequest(
        token: Int
    ) {
        pendingSleepOperations.removeValue(forKey: token)
    }

    private static func monotonicDeadline(after interval: TimeInterval) -> UInt64 {
        let duration = UInt64(interval * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        let result = now.addingReportingOverflow(duration)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

enum SystemPowerMessage {
    // Swift cannot import IOMessage.h's nested iokit_common_msg macros.
    static let canSystemSleep: UInt32 = 0xe000_0270
    static let systemWillSleep: UInt32 = 0xe000_0280
    static let systemWillNotSleep: UInt32 = 0xe000_0290
    static let systemHasPoweredOn: UInt32 = 0xe000_0300
}

protocol SystemPowerTransport: AnyObject, Sendable {
    @MainActor
    func start(
        handler: @escaping @MainActor (_ messageType: UInt32, _ token: Int) -> Void
    ) throws
    func resolve(token: Int, decision: SleepAcknowledgementDecision)
    @MainActor func stop()
}

private final class IOKitSystemPowerTransport: SystemPowerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responderPort: io_connect_t = 0
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var runLoopSource: CFRunLoopSource?
    private var handler: (@MainActor (UInt32, Int) -> Void)?

    @MainActor
    func start(
        handler: @escaping @MainActor (_ messageType: UInt32, _ token: Int) -> Void
    ) throws {
        stop()
        self.handler = handler
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            context,
            &notificationPort,
            { context, _, messageType, messageArgument in
                guard let context else { return }
                let transport = Unmanaged<IOKitSystemPowerTransport>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                let token = Int(bitPattern: messageArgument)
                MainActor.assumeIsolated {
                    transport.handler?(messageType, token)
                }
            },
            &notifier
        )
        lock.withLock { responderPort = rootPort }
        guard rootPort != 0,
              let notificationPort,
              let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue()
        else {
            stop()
            throw BatteryError.unsupported("시스템 잠자기 이벤트를 등록할 수 없습니다.")
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func resolve(token: Int, decision: SleepAcknowledgementDecision) {
        lock.withLock {
            guard responderPort != 0 else { return }
            switch decision {
            case .allow: IOAllowPowerChange(responderPort, token)
            case .reject: IOCancelPowerChange(responderPort, token)
            }
        }
    }

    @MainActor
    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
        }
        lock.withLock {
            if responderPort != 0 {
                IOServiceClose(responderPort)
                responderPort = 0
            }
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        rootPort = 0
        notifier = 0
        notificationPort = nil
        runLoopSource = nil
        handler = nil
    }
}

enum SleepAcknowledgementDecision: Equatable, Sendable {
    case allow
    case reject
}

final class SleepAcknowledgedOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let completion: @Sendable (SleepAcknowledgementDecision) -> Void
    private var timeoutTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    init(
        deadlineUptimeNanoseconds: UInt64,
        timeoutDecision: SleepAcknowledgementDecision,
        completion: @escaping @Sendable (SleepAcknowledgementDecision) -> Void
    ) {
        self.completion = completion
        timeoutTask = Task { [weak self] in
            let now = DispatchTime.now().uptimeNanoseconds
            if deadlineUptimeNanoseconds > now {
                try? await Task.sleep(nanoseconds: deadlineUptimeNanoseconds - now)
            }
            self?.finish(timeoutDecision)
        }
    }

    func setTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            if completed { return true }
            operationTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func finish(_ decision: SleepAcknowledgementDecision) {
        let shouldComplete = lock.withLock {
            guard !completed else { return false }
            completed = true
            operationTask = nil
            return true
        }
        guard shouldComplete else { return }
        completion(decision)
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    func invalidate(resolving decision: SleepAcknowledgementDecision) {
        let didInvalidate = lock.withLock {
            guard !completed else { return false }
            completed = true
            operationTask = nil
            return true
        }
        guard didInvalidate else { return }
        completion(decision)
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}
