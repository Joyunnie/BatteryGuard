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
- Represent failure recovery with a typed disposition. Only a Heat Protection failure may enter the automatic Heat retry/restore path; an uncertain hardware failure requires explicit recovery.
- Use operation IDs/generations so stale async completions cannot overwrite newer intent.
- Cancel the owning Swift task when preempting; stale work must not issue compensation or cleanup commands after newer safety intent starts.
- Carry one semantic operation ID through controller transitions, CLI commands, verified status reads, and diagnostics; command/event IDs remain independently unique.
- Give shared observable UI state explicit main-actor isolation; keep Core Data work on its configured context/queue.
- Model asynchronous store readiness explicitly and await it; never use fixed sleeps as an initialization contract.
- Keep abstractions minimal: use `ChargeBackend` plus an in-memory Core Data configuration; add a `BatteryHistoryStore` protocol only if a second implementation becomes necessary.
- Keep the POSIX ownership journal implementation in `BatteryControlOwnershipJournal`; `UserSettings` retains ownership loading, transitions, and persistence errors. Keep tuple matching and observed-state interpretation in `ChargeReconciliationPolicy`, shutdown mapping in `ChargeShutdownPlanner`, Heat Protection decisions in `HeatProtectionPolicy`, Top Up/Discharge progress and exit decisions in `LongRunningChargePolicy`, temperature freshness in `SafetyTemperatureCache`, and state presentation in `ChargeState`. Hardware reads, task ownership, and published state remain in `ChargeController`.
- Reuse existing views, IOKit monitoring, and history code. Replace unsafe process/state internals incrementally; do not rewrite the app wholesale.

## Hardware and Command Safety

- Serialize one-shot commands and long-running launches through one FIFO runner; keep each semantic control operation atomic through its status verification.
- A spawned process is not success: await termination and capture exit code, stdout, and stderr.
- Apply monotonic timeouts, bounded output capture, cancellation, and process-group cleanup; never use broad `pkill -f` matching.
- Long-running timeouts must fire autonomously; status polling is not the timeout mechanism.
- Reject truncated command/status output instead of parsing an incomplete result.
- Treat cleanup failure as a terminal runner failure and reject later commands instead of continuing in an unknown state.
- Verify control-changing commands with a subsequent status read before updating UI state.
- Verify the complete expected control tuple: charging, discharging, maintain level, and exact worker state; a matching subset is not success.
- For battery CLI v1.3.4 force discharge, the verified tuple is charging enabled, discharging true, and the Maintain worker stopped. Do not require charging disabled: `CHTE=00` permits the forced `CHIE=08` discharge path.
- Treat maintain as valid only when exactly one worker with the expected target exists and the PID file points to it; stale, mismatched, or duplicate workers are failures.
- Bind every worker selected for termination to its process start identity and revalidate that identity immediately before each signal; a reused PID must never be signaled.
- Never trust the CLI's “killing old maintain process” log by itself. Re-read the PID file and exact command line; the script can leave an orphaned stale worker after external commands.
- Read PID files without following links or blocking on special files; accept only bounded, current-user-owned regular files.
- Stop exact maintain worker PIDs before Top Up, Discharge, or charging-off transitions. Never signal an unrelated process group.
- Coalesce rapid slider changes and block conflicting or duplicate operations.
- Validate persisted limits and thresholds at every boundary.
- Before using the privileged CLI, validate executable path, symlink target, owner/mode, version, and required capabilities.
- Support only the explicitly verified battery CLI version and revalidate its file identity immediately before each mutation.
- Give the privileged script a minimal PATH containing only its validated directory and fixed system directories; never search user-writable tool directories.
- Never recommend or execute an unpinned `curl | bash` installer flow.
- Do not report missing temperature/health/current values as plausible measurements such as `0` or `100%`; model them as unavailable.
- Do not dump raw IOKit dictionaries or battery identifiers to stdout or diagnostics.
- Reject nonfinite or physically implausible sensor values before any safety decision.
- Keep battery measurement delivery notification-driven, suppress identical snapshots, and use only a low-frequency watchdog for missed notifications.
- Sample SMC temperatures adaptively: a clearly safe IOKit reading may use the slower cadence, but near-threshold, unavailable, and explicit safety-transition reads must retain the fast/forced path.
- Batch only routine diagnostics. Safety, failure, control, and lifecycle events must flush immediately, including any pending routine context.

## State and Lifecycle Invariants

- Maintain, Top Up, Discharge, and Heat Protection are mutually coordinated; Heat Protection must never be bypassed by another control.
- Enter a state only after its command succeeds and the resulting state is verified.
- Keep charge controls disabled until initialization, initial reconciliation, and the initial maintain operation finish.
- On failure, preserve an actionable error instead of silently falling back to a misleading state.
- Treat persistence and `NSApplication` policy return failures as observable failures; never open a missing diagnostic file or report a rejected policy as applied.
- Reconcile actual CLI and battery state on launch, wake, and after command completion; tolerate changes made from Terminal.
- Run low-frequency and app-activation reconciliation as read-only observation. Never silently overwrite a Terminal change.
- Compare the complete expected tuple after every reconciliation read. Surface mismatch as external drift, show the observed state, and lock conflicting controls; a failed or inconsistent status read is unknown, not stale success.
- For Top Up and Discharge, require both the expected CLI tuple and a live BatteryGuard-owned process; a matching external command is drift, not success.
- Revalidate the operation generation and expected mode after an async status read so stale reconciliation cannot overwrite wake or newer safety intent.
- Own long-running liveness probes as cancellable tasks and validate both probe and operation generations after every await; a stale probe must not mutate shutdown or a later Top Up/Discharge session.
- Show drift as expected versus observed state with an explicit read-only retry path; never hide the recovery target behind a disabled control.
- Define crash recovery from observed state, never from stale in-memory assumptions.
- Normal app quit should not stop persistent maintain mode. Provide a separate explicit action to disable BatteryGuard control.
- Persist control-release intent before mutating hardware so a crash cannot silently reclaim Maintain on restart; finalize the preference only after verification.
- Store charge-control ownership in a crash-durable journal. Model `batteryGuard`, `releasing`, and `system` separately; never infer a completed release from a pending record or a compatible read-only status.
- A missing ownership journal is unclaimed/system control, not proof of BatteryGuard ownership. Migrate legacy ownership only once behind a durable migration marker.
- A persisted `releasing` state must actively rerun and verify the release transaction on launch or explicit retry. Periodic and wake reconciliation may observe it but must not finalize it.
- Treat a durable ownership commit as an irreversible boundary for that operation: later task cancellation or LED/UI cleanup failure must not roll the journal back or relabel it as the previous owner.
- Use persisted ownership immediately to lock controller-owned Heat Protection, LED, and charge actions, including while the visible mode is transitioning.
- Releasing control must stop owned long operations and exact Maintain workers, run the CLI stop action, and verify charging restored, no discharge, and no worker.
- In monitoring-only mode, allow known charging on or off because native Charge Limit may pause charging; still require no discharge, no Maintain worker, and no BatteryGuard-owned long operation.
- Never claim to detect native Charge Limit from charging state alone. Require the user to choose one owner and confirm native Charge Limit is off before re-enabling BatteryGuard control.
- Quit during Top Up or Discharge must cancel the long operation, restore the recorded maintain limit, and verify level, worker liveness, and non-discharge state before exit.
- Acquire the sleep assertion before starting or restoring Discharge. If assertion acquisition fails, do not mutate hardware; retain it after any uncertain recovery failure.
- Delay AppKit termination until safety cleanup succeeds; a timeout or cleanup failure must cancel normal termination instead of merely logging and exiting.
- Tear down monitoring and observers only after verified shutdown cleanup; keep failed shutdowns alive and retryable.
- Keep the Discharge sleep assertion until cancellation and verified safe-state recovery succeed; a failed cleanup must retain it for retry.
- If an owned Discharge process is lost, retain its sleep assertion through external drift and release it only after a full Maintain tuple is verified.
- If initialization fails before the backend becomes available, quit through local teardown without issuing hardware cleanup commands to the unavailable backend.
- Reject normal quit while an externally owned charge/discharge or unknown control state is active, without tearing down the controller, so the user can correct the state and retry.
- Re-read external drift immediately before choosing the quit policy; never trust a periodic snapshot for shutdown safety.
- Do not expose a stop/disable command unless its result can be verified through an observable CLI state.
- If temperature sensing is unavailable while heat protection is enabled, surface the degraded protection clearly and avoid unsafe automatic charging decisions.
- Present the same maximum safety temperature used by policy, including sensor provenance and freshness; prioritize control/lifecycle failures over sensor warnings.
- Preserve external drift across wake with read-only reconciliation; never silently reapply Maintain over it.
- When LED control is disabled or external power is removed, restore automatic LED behavior.
- Treat LED restoration as best-effort peripheral cleanup after verified battery cleanup; report its failure without trapping the app in termination.
- Route every LED intent through one generation-ordered actor/worker; stale writes and blink tasks must not outlive newer intent.
- Apply one freshness policy to cached SMC temperatures on every Heat Protection path, including disable/re-enable transitions; stale data is unavailable.

## Testing

- Default automated tests must never invoke the real battery CLI, mutate real login items, or use the production Core Data store.
- Shared objects constructed by the XCTest host must also use inert monitoring, in-memory storage, isolated defaults, and disabled diagnostics.
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
