# BatteryGuard Agent Guide

## Scope

- This is a personal, local-only macOS app for one Apple Silicon Mac.
- Optimize for hardware safety, correctness, recovery, and maintainability—not public distribution.
- Do not add CI, branch protection, notarization, App Store support, localization, Intel support, auto-update, public installer/docs, or release automation unless explicitly requested.
- Preserve unrelated and pre-existing user changes. Keep diffs small and reversible.

## Product Assumption

- BatteryGuard is the sole owner of advanced charge control (`maintain`, Top Up, Discharge, Heat Protection); macOS Charge Limit should not compete with it.
- If only an 80% limit is required, prefer macOS native Charge Limit and reduce BatteryGuard to monitoring/history.
- Treat changing this ownership model as an explicit product decision.

## Architecture

```text
UI intent -> @MainActor ChargeController -> BatteryCommandRunner actor -> battery CLI
                  ^                              |
IOKit readings ---+                    result + verified CLI status
```

- IOKit is the source of truth for measurements; verified CLI status is the source of truth for charge control; UI state is derived from both.
- Represent charge control with one mutually exclusive state enum, not independent booleans.
- Use operation IDs/generations so stale async completions cannot overwrite newer intent.
- Cancel the owning Swift task when preempting; stale work must not issue compensation or cleanup commands after newer safety intent starts.
- Carry one semantic operation ID through controller transitions, CLI commands, verified status reads, and diagnostics; command/event IDs remain independently unique.
- Give shared observable UI state explicit main-actor isolation; keep Core Data work on its configured context/queue.
- Model asynchronous store readiness explicitly and await it; never use fixed sleeps as an initialization contract.
- Keep abstractions minimal: use `ChargeBackend` plus an in-memory Core Data configuration; add a `BatteryHistoryStore` protocol only if a second implementation becomes necessary.
- Reuse existing views, IOKit monitoring, and history code. Replace unsafe process/state internals incrementally; do not rewrite the app wholesale.

## Hardware and Command Safety

- Serialize one-shot commands and long-running launches through one FIFO runner; keep each semantic control operation atomic through its status verification.
- A spawned process is not success: await termination and capture exit code, stdout, and stderr.
- Apply monotonic timeouts, bounded output capture, cancellation, and process-group cleanup; never use broad `pkill -f` matching.
- Treat cleanup failure as a terminal runner failure and reject later commands instead of continuing in an unknown state.
- Verify control-changing commands with a subsequent status read before updating UI state.
- Verify the complete expected control tuple: charging, discharging, maintain level, and exact worker state; a matching subset is not success.
- Treat maintain as valid only when exactly one matching worker exists and the PID file points to it; stale or duplicate workers are failures.
- Stop exact maintain worker PIDs before Top Up, Discharge, or charging-off transitions. Never signal an unrelated process group.
- Coalesce rapid slider changes and block conflicting or duplicate operations.
- Validate persisted limits and thresholds at every boundary.
- Before using the privileged CLI, validate executable path, symlink target, owner/mode, version, and required capabilities.
- Never recommend or execute an unpinned `curl | bash` installer flow.
- Do not report missing temperature/health/current values as plausible measurements such as `0` or `100%`; model them as unavailable.
- Reject nonfinite or physically implausible sensor values before any safety decision.

## State and Lifecycle Invariants

- Maintain, Top Up, Discharge, and Heat Protection are mutually coordinated; Heat Protection must never be bypassed by another control.
- Enter a state only after its command succeeds and the resulting state is verified.
- Keep charge controls disabled until initialization, initial reconciliation, and the initial maintain operation finish.
- On failure, preserve an actionable error instead of silently falling back to a misleading state.
- Treat persistence and `NSApplication` policy return failures as observable failures; never open a missing diagnostic file or report a rejected policy as applied.
- Reconcile actual CLI and battery state on launch, wake, and after command completion; tolerate changes made from Terminal.
- Define crash recovery from observed state, never from stale in-memory assumptions.
- Normal app quit should not stop persistent maintain mode. Provide a separate explicit action to disable BatteryGuard control.
- Quit during Top Up or Discharge must cancel the long operation, restore the recorded maintain limit, and verify level, worker liveness, and non-discharge state before exit.
- Delay AppKit termination until safety cleanup succeeds; a timeout or cleanup failure must cancel normal termination instead of merely logging and exiting.
- Do not expose a stop/disable command unless its result can be verified through an observable CLI state.
- If temperature sensing is unavailable while heat protection is enabled, surface the degraded protection clearly and avoid unsafe automatic charging decisions.
- When LED control is disabled or external power is removed, restore automatic LED behavior.
- Route every LED intent through one generation-ordered actor/worker; stale writes and blink tasks must not outlive newer intent.

## Testing

- Default automated tests must never invoke the real battery CLI, mutate real login items, or use the production Core Data store.
- Use fake `ChargeBackend` implementations, an in-memory history store, and temporary fixture executables.
- Cover every safety-relevant transition across success, failure, timeout, cancellation, stale completion, launch reconciliation, and wake reconciliation.
- Keep real-hardware checks manual or opt-in and never run them without explicit user approval.
- Assert outcomes and state; “does not crash” is not a sufficient test.
- Keep persisted diagnostic fields stable and typed, give every event a unique ID, and test migration of the previous local schema.
- Record history from the verified effective control state, not directly from the stored preference.
- Prefer safety-path completeness over superficial coverage percentages or trivial view tests.

## Verification

Safe default checks:

```sh
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug build-for-testing
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Release build
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug analyze
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug build-for-testing SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
```

- Do not run the full existing test suite until real hardware/login-item/store side effects have been isolated.
- For manual hardware validation, record status before and after each operation and restore the intended maintain state at the end.

## Implementation Order

1. Patch immediate safety issues, conflicting controls, unsafe default-test side effects, and quit recovery.
2. Centralize process execution, descendant policy, bounded lifecycle, and atomic status/worker verification.
3. Run privileged CLI preflight before any hardware command.
4. Complete async initialization/readiness, then introduce the single reconciled charge state model.
5. Rebuild lifecycle, Heat Protection, Top Up, Discharge, and LED ownership on that model.
6. Fix monitoring/history accuracy, diagnostics, and remaining UI truthfulness.
7. Complete automated coverage and run controlled, opt-in hardware validation.

## Reject a Change If

- Tests touch real hardware or persistent system state by default.
- Command success is assumed before exit and verification.
- Independent booleans remain competing sources of charge state.
- Heat Protection can be bypassed.
- launch, quit, crash, sleep/wake, timeout, or stale-completion behavior is undefined.
- A privileged executable is trusted only because it exists.
- A failure is hidden or shown as success.
