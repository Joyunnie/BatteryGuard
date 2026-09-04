# Power Connection Presentation Plan

## Goal

Make charger connection changes visible promptly and truthfully without turning display refreshes into battery-control commands or restoring continuous polling.

The app must distinguish:

- physical external-power connection;
- the power source currently supplying the Mac;
- macOS-reported charging activity;
- BatteryGuard's verified charge-control policy.

These signals may converge at different times and must never be collapsed into one Boolean conclusion.

## Existing Implementation to Reuse

- `BatteryMonitor` is already `@MainActor` and owns broad IOPS notifications, the dedicated power-source signal, a low-frequency watchdog, monitoring and transition generations, and one settlement task.
- `BatteryInfo` remains the measurement payload consumed by existing Heat Protection and long-running-operation code.
- `ChargeMode` remains the charge-control source of truth.
- `ChargeState` remains the existing controller/LED state. It must not gain presentation-only transition cases because `updateLED()` consumes it.
- Existing transition tests already cover source lag, same-direction bursts, reverse edges, registration races, cancellation, and watchdog fallback.

## Scope

### Included

- Preserve optional connection evidence from the AppleSmartBattery dictionary instead of treating a missing key as `false`.
- Publish a typed physical-connection observation with stable, transitioning, and uncertain states.
- Reuse the existing generation-owned settlement task.
- Preserve one same-generation trailing refresh requested while settlement is active.
- Add a pure, computed `BatteryPresentation` projection used by the menu popover, Dashboard, and menu-bar label.
- Add focused deterministic tests for the new state, presentation, cancellation, and safety contracts.
- Run Debug, strict-concurrency, Release, Analyze, and safe automated tests.

### Not in scope

- Changing `ChargeMode`, verified CLI tuples, Heat Protection, Top Up, Discharge, shutdown, or sleep/wake control policy.
- Adding hardware commands to power-source callbacks or presentation refreshes.
- Changing or forking the external `battery maintain_synchronous` loop without separate evidence of actual charging-activation delay below the maintain limit.
- Continuous high-frequency polling, a new actor/service, CI, distribution, notarization, or multi-Mac support.
- Automatic hardware mutation or installation during validation.

## Data Model

```text
AppleSmartBattery flags ──> connection evidence ──┐
                                                  ├─> PowerConnectionObservation
IOPS providing source ────────────────────────────┘

BatteryInfo + PowerConnectionObservation + ChargeMode + ChargeState
                                  │
                                  └─> BatteryPresentation (computed, never stored)
```

### Connection evidence

`PowerConnectionEvidence` has three values: `connected`, `disconnected`, and `uncertain`.

- Any explicit `ExternalConnected`, `ExternalChargeCapable`, or `AppleRawExternalConnected` `true`, or `IsCharging == true`, means `connected`.
- All three external flags must be present and `false` before the battery dictionary alone means `disconnected`.
- With no positive attached-charger evidence, any missing external flag keeps the battery-only result `uncertain`. A positive flag wins over false flags because force discharge can make those flags disagree while the charger remains attached.
- `IOPS` `.ac` confirms a connected external power source.
- `IOPS` `.battery` does not override explicit physical-connection evidence because forced discharge can draw from the battery while the charger remains attached.

The existing `BatteryInfo.isPluggedIn` Boolean remains compatibility input for controller safety paths. Its behavior stays conservative: only confirmed connection maps to `true`.

### Published connection observation

Use one enum so impossible combinations cannot be published:

```text
stable(connected | disconnected)
transitioning(previous: connected | disconnected | none)
uncertain(previous: connected | disconnected | none)
```

The transition generation remains internal. It is not UI state.

## Transition Contract

```text
dedicated edge signal
        │
        ├─ publish transitioning(previous) without guessing direction
        └─ existing absolute settlement: 100ms -> 500ms -> 1s -> 2s
                    │
                    ├─ new confirmed state differs from previous -> publish stable(new)
                    ├─ only previous state observed through deadline -> restore stable(previous)
                    └─ reads fail or remain incomplete/unresolved -> publish uncertain(previous)
```

- Same-direction bursts never restart or extend the anchored deadline.
- A reverse edge increments the generation and invalidates the previous task and trailing refresh.
- `stopMonitoring()` invalidates both.
- Broad, visibility, or same-direction refresh requests received during settlement set one trailing-refresh marker for the current generation.
- After settlement cleanup, the trailing refresh runs once only if monitoring and transition generations still match.
- A trailing refresh is a read, not a new settlement and not a hardware command.
- The 30-second watchdog remains a missed-event fallback and does not run during active settlement.
- No 5- or 10-second schedule is added without new hardware evidence showing repeatable convergence after two seconds.

## Presentation Contract

`BatteryPresentation` is a value computed from current inputs. It is never `@Published` and never becomes a second source of truth.

It provides semantic output for:

- status title;
- status and menu-bar icons;
- semantic tone (`success`, `warning`, `info`, `neutral`, `danger`);
- charging-bolt visibility;
- power icon, label, eyebrow, and headline.

SwiftUI `Color` conversion stays in the UI theme. The policy itself has no SwiftUI dependency.

Priority:

1. Manual recovery and safety failures remain visible.
2. A power transition shows direction-neutral checking text.
3. An unresolved transition shows an explicit unknown state.
4. Stable connection uses the existing charge mode/state, while distinguishing limit hold from current non-charging below the limit.
5. The app never says `charging` unless macOS reports `IsCharging == true` or the existing explicit Top Up presentation requires it.

The menu popover, Dashboard, and menu-bar label consume the same projection. Raw measurements such as percentage, temperature, and amperage remain raw measurements and are not synthesized by the presentation policy.

## Safety Invariants

- `PowerConnectionObservation` and `BatteryPresentation` are excluded from `ChargeController.ControlMeasurement`.
- Changing only transition/presentation state cannot call the backend or change LED intent.
- Publishing a real `BatteryInfo` may continue to trigger existing Heat Protection or long-running-operation behavior.
- No stale settlement or trailing refresh may publish after a reverse edge, stop, or monitoring restart.
- No guessed connection, charging activity, amperage, CLI status, or worker state is published as fact.

## Implementation Order

1. Add the typed connection evidence and observation models while preserving `isPluggedIn` compatibility.
2. Extend `BatteryMonitor` publication and settlement finalization with generation-scoped trailing refresh.
3. Add the pure `BatteryPresentation` policy without changing `ChargeState` or LED policy.
4. Migrate all three UI surfaces to the projection.
5. Add focused regression and safety tests.
6. Run the automated verification gates and review the diff.
7. Record results here and in `REFACTOR_PLAN.md` if the implementation is accepted.

Sequential implementation is intentional because the changes share the monitor, controller presentation, and UI state contracts.

## Test Matrix

- Connection evidence: each true signal, all explicit false, missing keys, and `IsCharging` fallback.
- Providing-source interaction: AC confirms connection; battery does not erase explicit attached evidence.
- Transition publication: direction-neutral start, confirmed change, duplicate signal, unchanged deadline, and unresolved deadline.
- Trailing refresh: coalesced once for the same generation; discarded after reverse edge, stop, or restart.
- Presentation: checking, uncertain, connected charging, maintain-at-limit, connected-not-charging below limit, disconnected, Top Up, Discharge, Heat, Sleep, drift, and manual recovery.
- Surface consistency: shared title, icons, tone, bolt, and power label come from the projection.
- Safety: presentation-only changes do not change `ControlMeasurement`, backend operations, or LED intent; genuine hot `BatteryInfo` retains existing Heat behavior.
- Performance: no steady-state settlement reads, at most four settlement reads per physical edge, and at most one additional trailing read only when an in-flight event or visibility request requires it.

## Acceptance Criteria

- A dedicated edge signal makes the UI show a neutral checking state on the next available main-actor turn.
- Confirmed AC connection is displayed without waiting for `IsCharging` to become true.
- Unknown or conflicting input is explicit and never shown as stale success.
- Same-generation trailing work executes at most once; stale trailing work executes zero times.
- No new battery CLI, SMC mutation, LED mutation, or persistent-system side effect is reachable from presentation-only state changes.
- Existing automated safety tests and all listed build/analyze gates pass.
- Repository changes remain limited to this plan, monitor/connection modeling, presentation mapping, affected UI surfaces, tests, and concise architecture documentation.

## Validation Boundary

Automated validation is safe and required. Installing the app or changing charge limits, Top Up, Discharge, Heat settings, or CLI state requires separate explicit approval. A later read-only hardware trial should observe both a naturally below-limit connection and an at-limit Maintain connection before any CLI-control follow-up is proposed.

## Execution Results

Completed on 2026-09-04 on `fix/power-connection-presentation`.

- Preserved the three optional AppleSmartBattery connection flags and added typed evidence/observation states without changing the compatibility behavior consumed by charge-control paths.
- Reused the existing main-actor settlement task and absolute 100/500/1000/2000ms schedule. Duplicate requests coalesce into one same-generation trailing read; reverse broad or dedicated edges, stop, and restart invalidate older work.
- Added one pure `BatteryPresentation` projection and migrated the menu popover, Dashboard, and menu-bar label to it. `ChargeState`, `ChargeMode`, controller measurements, hardware commands, and LED intent were not expanded for presentation state.
- The implementation review found and fixed a broad-notification fallback bug: after direction had been confirmed, a reverse broad edge now starts a newly anchored generation instead of inheriting the first edge's deadline.
- Added connection-evidence, source-resolution, observation publication/deduplication, transition, unresolved-read, trailing refresh, reverse-edge, restart, presentation-priority, and control-measurement isolation tests.
- All 344 tests passed with `SWIFT_STRICT_CONCURRENCY=complete` and `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`. Release build and Debug Analyze passed under the same settings. No real battery CLI, SMC mutation, login-item mutation, production store, app installation, or charge-setting change was used.
- Physical unplug/replug observation remains a separate read-only hardware trial because it requires deliberate user interaction. It is not an automated acceptance gate and must not mutate charge control.
