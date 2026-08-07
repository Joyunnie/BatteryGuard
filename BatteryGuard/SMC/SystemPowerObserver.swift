// SystemPowerObserver.swift
// Delays the final sleep acknowledgement until battery cleanup completes.

import Foundation
import IOKit
import IOKit.pwr_mgt

@MainActor
final class SystemPowerObserver {
    typealias SleepHandler = @MainActor () async -> Void

    private static let acknowledgementDeadline: TimeInterval = 25
    // Swift cannot import IOMessage.h's nested iokit_common_msg macros.
    private static let canSystemSleepMessage: UInt32 = 0xe000_0270
    private static let systemWillSleepMessage: UInt32 = 0xe000_0280
    private static let systemHasPoweredOnMessage: UInt32 = 0xe000_0300

    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var runLoopSource: CFRunLoopSource?
    private var sleepHandler: SleepHandler?
    private var wakeHandler: (@MainActor () -> Void)?

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
                Task { @MainActor in
                    observer.receive(messageType: messageType, token: token)
                }
            },
            &notifier
        )
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
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        rootPort = 0
        notifier = 0
        notificationPort = nil
        runLoopSource = nil
        sleepHandler = nil
        wakeHandler = nil
    }

    private func receive(messageType: UInt32, token: Int) {
        switch messageType {
        case Self.canSystemSleepMessage:
            acknowledge(token)
        case Self.systemWillSleepMessage:
            guard let sleepHandler else {
                acknowledge(token)
                return
            }
            let operation = SleepAcknowledgedOperation(
                deadline: Self.acknowledgementDeadline
            ) { [weak self] in
                Task { @MainActor in self?.acknowledge(token) }
            }
            let task = Task { @MainActor in
                await sleepHandler()
                operation.finish()
            }
            operation.setTask(task)
        case Self.systemHasPoweredOnMessage:
            wakeHandler?()
        default:
            break
        }
    }

    private func acknowledge(_ token: Int) {
        guard rootPort != 0 else { return }
        IOAllowPowerChange(rootPort, token)
    }
}

final class SleepAcknowledgedOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let completion: @Sendable () -> Void
    private var timeoutTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    init(deadline: TimeInterval, completion: @escaping @Sendable () -> Void) {
        self.completion = completion
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            self?.finish(cancelOperation: true)
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

    func finish() {
        finish(cancelOperation: false)
    }

    private func finish(cancelOperation: Bool) {
        var taskToCancel: Task<Void, Never>?
        let shouldComplete = lock.withLock {
            guard !completed else { return false }
            completed = true
            if cancelOperation { taskToCancel = operationTask }
            operationTask = nil
            return true
        }
        guard shouldComplete else { return }
        taskToCancel?.cancel()
        timeoutTask?.cancel()
        timeoutTask = nil
        completion()
    }
}
