// SystemPowerObserver.swift
// Delays the final sleep acknowledgement until battery cleanup completes.

import Foundation
import IOKit
import IOKit.pwr_mgt

@MainActor
protocol SystemPowerObserving: AnyObject {
    var activeSleepRequest: SystemSleepRequest? { get }
    func start(
        willSleep: @escaping @MainActor (SystemSleepRequest) async -> Bool,
        didComplete: @escaping @MainActor (SystemSleepCompletionEvent) -> Void
    ) throws
    func resolvePendingSleepRequestsForShutdown()
    func stop()
}

@MainActor
final class SystemPowerObserver: SystemPowerObserving {
    typealias SleepHandler = @MainActor (SystemSleepRequest) async -> Bool

    private static let acknowledgementDeadline: TimeInterval = 25
    private let transport: SystemPowerTransport
    private var sleepHandler: SleepHandler?
    private var completionHandler: (@MainActor (SystemSleepCompletionEvent) -> Void)?
    private struct PendingSleepRequest {
        let request: SystemSleepRequest
        let operation: SleepAcknowledgedOperation
    }

    private var pendingSleepOperations: [Int: PendingSleepRequest] = [:]
    private var requestGeneration: UInt64 = 0

    private(set) var activeSleepRequest: SystemSleepRequest?

    init(transport: SystemPowerTransport = IOKitSystemPowerTransport()) {
        self.transport = transport
    }

    func start(
        willSleep: @escaping SleepHandler,
        didComplete: @escaping @MainActor (SystemSleepCompletionEvent) -> Void
    ) throws {
        stop()
        sleepHandler = willSleep
        completionHandler = didComplete

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
        completionHandler = nil
        activeSleepRequest = nil
    }

    func resolvePendingSleepRequestsForShutdown() {
        for (_, request) in pendingSleepOperations {
            request.operation.invalidate(
                resolving: request.request.kind.canVeto ? .reject : .allow
            )
        }
        pendingSleepOperations.removeAll()
    }

    private func receive(messageType: UInt32, token: Int) {
        switch messageType {
        case SystemPowerMessage.canSystemSleep:
            handleSleepRequest(token: token, kind: .vetoableIdleSleep)
        case SystemPowerMessage.systemWillSleep:
            handleSleepRequest(token: token, kind: .forcedSystemSleep)
        case SystemPowerMessage.systemWillNotSleep:
            resolvePendingSleepRequestsForShutdown()
            activeSleepRequest = nil
            completionHandler?(.negotiationCancelled)
        case SystemPowerMessage.systemHasPoweredOn:
            resolvePendingSleepRequestsForShutdown()
            activeSleepRequest = nil
            completionHandler?(.poweredOn)
        default:
            break
        }
    }

    private func handleSleepRequest(token: Int, kind: SystemSleepRequestKind) {
        guard pendingSleepOperations[token] == nil else { return }
        requestGeneration &+= 1
        let request = SystemSleepRequest(
            id: UUID(),
            generation: requestGeneration,
            kind: kind,
            deadlineUptimeNanoseconds: Self.monotonicDeadline(
                after: Self.acknowledgementDeadline
            )
        )
        activeSleepRequest = request
        guard let sleepHandler else {
            transport.resolve(token: token, decision: .allow)
            return
        }
        let timeoutDecision: SleepAcknowledgementDecision = kind.canVeto ? .reject : .allow
        let operation = SleepAcknowledgedOperation(
            deadlineUptimeNanoseconds: request.deadlineUptimeNanoseconds,
            timeoutDecision: timeoutDecision
        ) { [weak self, transport] decision in
            transport.resolve(token: token, decision: decision)
            Task { @MainActor in
                self?.completeSleepRequest(token: token)
            }
        }
        pendingSleepOperations[token] = PendingSleepRequest(
            request: request,
            operation: operation
        )
        let task = Task { @MainActor in
            let prepared = await sleepHandler(request)
            operation.finish(prepared || !kind.canVeto ? .allow : .reject)
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

enum SystemSleepRequestKind: String, Codable, Equatable, Sendable {
    case vetoableIdleSleep
    case forcedSystemSleep

    var canVeto: Bool { self == .vetoableIdleSleep }
}

struct SystemSleepRequest: Codable, Equatable, Sendable {
    let id: UUID
    let generation: UInt64
    let kind: SystemSleepRequestKind
    let deadlineUptimeNanoseconds: UInt64
}

enum SystemSleepCompletionEvent: String, Codable, Equatable, Sendable {
    case negotiationCancelled
    case poweredOn
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
            self?.finishFromTimeout(timeoutDecision)
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
        resolve(decision, cancelOperation: false, cancelTimeout: true)
    }

    func invalidate(resolving decision: SleepAcknowledgementDecision) {
        resolve(decision, cancelOperation: true, cancelTimeout: true)
    }

    private func finishFromTimeout(_ decision: SleepAcknowledgementDecision) {
        resolve(decision, cancelOperation: true, cancelTimeout: false)
    }

    private func resolve(
        _ decision: SleepAcknowledgementDecision,
        cancelOperation: Bool,
        cancelTimeout: Bool
    ) {
        let result: (
            shouldComplete: Bool,
            operationTask: Task<Void, Never>?,
            timeoutTask: Task<Void, Never>?
        ) = lock.withLock {
            guard !completed else { return (false, nil, nil) }
            completed = true
            let operation = operationTask
            let timeout = timeoutTask
            operationTask = nil
            timeoutTask = nil
            return (true, operation, timeout)
        }
        guard result.shouldComplete else { return }
        if cancelOperation { result.operationTask?.cancel() }
        if cancelTimeout { result.timeoutTask?.cancel() }
        completion(decision)
    }
}
