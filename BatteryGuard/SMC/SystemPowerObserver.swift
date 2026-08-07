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
    // Swift cannot import IOMessage.h's nested iokit_common_msg macros.
    private static let canSystemSleepMessage: UInt32 = 0xe000_0270
    private static let systemWillSleepMessage: UInt32 = 0xe000_0280
    private static let systemWillNotSleepMessage: UInt32 = 0xe000_0290
    private static let systemHasPoweredOnMessage: UInt32 = 0xe000_0300

    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var runLoopSource: CFRunLoopSource?
    private var sleepHandler: SleepHandler?
    private var wakeHandler: (@MainActor () -> Void)?
    private struct PendingSleepRequest {
        let canVeto: Bool
        let operation: SleepAcknowledgedOperation
    }

    private var pendingSleepOperations: [Int: PendingSleepRequest] = [:]
    private let powerChangeResponder = PowerChangeResponder()
    private var sleepTransitionInProgress = false

    var requiresChargingDisabledForSleepTransition: Bool { sleepTransitionInProgress }

    func start(
        willSleep: @escaping SleepHandler,
        didWake: @escaping @MainActor () -> Void
    ) throws {
        stop()
        sleepHandler = willSleep
        wakeHandler = didWake

        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            context,
            &notificationPort,
            { context, _, messageType, messageArgument in
                guard let context else { return }
                let observer = Unmanaged<SystemPowerObserver>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                let token = Int(bitPattern: messageArgument)
                // This callback is delivered by the source installed on the main
                // run loop, so start the absolute IOKit budget without queueing.
                MainActor.assumeIsolated {
                    observer.receive(messageType: messageType, token: token)
                }
            },
            &notifier
        )
        powerChangeResponder.activate(rootPort)
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

    func stop() {
        resolvePendingSleepRequestsForShutdown()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
        }
        powerChangeResponder.close()
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        rootPort = 0
        notifier = 0
        notificationPort = nil
        runLoopSource = nil
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
        case Self.canSystemSleepMessage:
            // Latch the whole accepted/rejected negotiation window. Shutdown is
            // conservative until IOKit reports that sleep was cancelled or ended.
            sleepTransitionInProgress = true
            handleSleepRequest(token: token, canVeto: true, deadline: deadline)
        case Self.systemWillSleepMessage:
            // Keep this latched after acknowledgement: IOAllowPowerChange means
            // the non-vetoable transition may still suspend the process.
            sleepTransitionInProgress = true
            handleSleepRequest(token: token, canVeto: false, deadline: deadline)
        case Self.systemWillNotSleepMessage:
            wakeHandler?()
            sleepTransitionInProgress = false
        case Self.systemHasPoweredOnMessage:
            wakeHandler?()
            sleepTransitionInProgress = false
        default:
            break
        }
    }

    private func handleSleepRequest(token: Int, canVeto: Bool, deadline: UInt64) {
        guard let sleepHandler else {
            powerChangeResponder.resolve(token: token, decision: .allow)
            return
        }
        let timeoutDecision: SleepAcknowledgementDecision = canVeto ? .reject : .allow
        let operation = SleepAcknowledgedOperation(
            deadlineUptimeNanoseconds: deadline,
            timeoutDecision: timeoutDecision
        ) { [weak self, powerChangeResponder] decision in
            powerChangeResponder.resolve(token: token, decision: decision)
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

private final class PowerChangeResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var port: io_connect_t = 0

    func activate(_ port: io_connect_t) {
        lock.withLock { self.port = port }
    }

    func resolve(token: Int, decision: SleepAcknowledgementDecision) {
        lock.withLock {
            guard port != 0 else { return }
            switch decision {
            case .allow: IOAllowPowerChange(port, token)
            case .reject: IOCancelPowerChange(port, token)
            }
        }
    }

    func close() {
        lock.withLock {
            guard port != 0 else { return }
            IOServiceClose(port)
            port = 0
        }
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
            completion(decision)
            return true
        }
        guard shouldComplete else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    func invalidate(resolving decision: SleepAcknowledgementDecision) {
        let didInvalidate = lock.withLock {
            guard !completed else { return false }
            completed = true
            operationTask = nil
            completion(decision)
            return true
        }
        guard didInvalidate else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}
