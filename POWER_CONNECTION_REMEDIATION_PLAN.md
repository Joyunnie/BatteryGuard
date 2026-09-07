# Power Connection Remediation Plan

## Status

- Target: PR #33 (`fix/power-connection-presentation`)
- State: complete; implementation, automated verification, hostile review remediation, commits, and PR #33 update finished
- Severity: P2 user-visible correctness; merge-blocking for this PR's stated goal
- Hardware impact: none. This work must remain read-only with respect to battery control.

## Goal

Make every connection refresh use current evidence, recover when power-source notifications are missed, and keep recovery UI on the same `BatteryPresentation` contract as the other surfaces.

## Confirmed Pre-remediation Problems

### 1. Cached IOPS source is reused as current evidence

`lastPowerSourceKind` currently serves both as an edge-comparison baseline and as input to connection resolution. If an AC-to-battery notification is missed, the cached `.ac` can override a fresh detached battery dictionary indefinitely. The watchdog and visibility refresh only reread `BatteryInfo`, so neither can repair that state.

The same conflation can turn a failed current IOPS read into stale success during settlement.

### 2. Recovery UI bypasses `BatteryPresentation`

`ChargeRecoveryStatusView` still reads `manualRecoveryStatusTitle`, which derives connection text from `BatteryInfo.isPluggedIn`. It can disagree with the transition-aware title and power label produced by `BatteryPresentation`, especially while the source is transitioning or uncertain.

### 3. Tests prove timer existence, not missed-event recovery

The registration-failure test confirms that a watchdog is scheduled but does not prove that a later source change is detected or presented correctly.

## Scope

### Included

- Separate the previous-source baseline from fresh source evidence.
- Read current IOPS source during startup, pre-monitor visibility, watchdog, routine, registration-reconciliation, settlement, and trailing refreshes.
- Route newly detected source changes through the existing generation-owned settlement.
- Treat a failed current source read as unavailable, never as the cached source.
- Keep controller-requested safety measurement refreshes immediate and independent from presentation settlement.
- Migrate recovery titles to `BatteryPresentation` and remove superseded title helpers.
- Add deterministic missed-notification, failed-read, stale-generation, and UI-projection tests.
- Mark the earlier refresh plan's no-trailing-read statement as superseded.
- Run all safe automated verification gates and update PR #33.

### Excluded

- ChargeMode, CLI verification, Maintain, Top Up, Discharge, Heat Protection, LED, shutdown, or sleep/wake policy changes.
- New actors, services, continuous polling, shorter watchdog intervals, or new timers/wakeup sources.
- More than one paired `BatteryInfo`/IOPS sample per steady-state watchdog, visibility, routine, or registration-reconciliation refresh.
- CI, release/version automation, distribution work, installation, or public-product support.
- Real CLI/SMC mutation and automatic unplug/replug testing.

## Invariants

1. `lastPowerSourceKind` is only a previous-value baseline used to detect edges.
2. `resolvedPowerConnection` receives the source value read for the current refresh; it never receives a cached substitute after a failed read.
3. Fresh explicit charger evidence may confirm connection without IOPS.
4. Fresh IOPS `.ac` may confirm connection; fresh IOPS `.battery` must not erase explicit attached-charger evidence.
5. Explicit disconnected battery evidence plus unavailable IOPS remains uncertain, not confirmed disconnected or stale connected.
6. A source change found by any trigger starts the existing bounded settlement instead of publishing an immediate guessed stable state.
7. `BatteryInfo.isPluggedIn` and `ControlMeasurement` retain their current compatibility behavior.
8. Presentation refreshes never call the charge backend or change LED intent.
9. Same-direction bursts do not extend the anchored deadline; reverse edges, stop, and restart invalidate stale work.
10. Steady state retains the existing notification-driven design and 30-second watchdog.
11. A pre-monitor presentation refresh is a one-shot observation: it may establish a baseline and publish a result, but it never starts settlement, a timer, or notification infrastructure.
12. Controller-requested safety refreshes read and publish only `BatteryInfo`; they do not read presentation source state, start settlement, call the backend, or change LED intent.

## Implementation Plan

### Step 1: Introduce one fresh snapshot path

Refactor `BatteryMonitor` so a presentation refresh obtains one paired snapshot containing:

- the current `BatteryInfo?`;
- the current `BatteryPowerSourceKind?` from the same refresh attempt.

Keep the values separate rather than adding them to `BatteryInfo`. Split the APIs by purpose:

- `refreshBatteryInfo()` remains the measurement-only path used by `ChargeController` safety/exit settlement;
- one narrow internal presentation-refresh entry reads the paired snapshot, publishes its `BatteryInfo`, and evaluates connection state;
- `startMonitoring()` resets stale baseline state and performs one initial paired read rather than two unrelated reads.

Before monitoring starts, the presentation entry performs exactly one paired read, publishes the observation, and returns without settlement or infrastructure startup.

Reason: connection presentation needs both observations, while charge-control measurements must not start depending on presentation-only source state.

### Step 2: Separate edge baseline from resolution evidence

Use the fresh source value for `resolvedPowerConnection`. Use `lastPowerSourceKind` only to compare the newly read source with the previous known source.

- Fresh source differs from the known baseline: update the baseline and start a confirmed-direction settlement.
- Fresh source matches: resolve the connection using that fresh value.
- Fresh source is unavailable: keep the baseline for later edge comparison, but resolve using `nil`.
- No baseline exists and a fresh source is available: establish the baseline without inventing an edge.

Reason: cached observations are useful for change detection but are not proof of the current physical state.

### Step 3: Route every read trigger through the fresh path

Use the common path for:

- the 30-second watchdog;
- menu/Dashboard visibility refresh;
- coalesced routine notifications;
- observer-registration reconciliation;
- each settlement offset;
- the same-generation trailing refresh.

Controller direct refresh calls remain on the measurement-only API. During active settlement, visibility/routine/watchdog presentation refreshes only mark the same generation pending; they do not create a second settlement or an independent read.

Read budgets count the two providers separately:

- initial startup sample: at most one IOPS read plus one `BatteryInfo` read;
- monitoring-infrastructure startup: one additional post-registration reconciliation sample, also at most one IOPS read plus one `BatteryInfo` read;
- pre-monitor presentation request: at most one IOPS read plus one `BatteryInfo` read, with no settlement or trailing work;
- dedicated transition notification with no established source baseline: a successful signal read is reused with one `BatteryInfo` read; if that signal read is unavailable, one coalesced paired retry is allowed, for a total of at most two IOPS reads plus one `BatteryInfo` read;
- each steady watchdog, visibility, coalesced routine, or registration-reconciliation refresh: at most one IOPS read plus one `BatteryInfo` read;
- unchanged source: zero settlement reads;
- a confirmed or payload-less physical edge: the existing single edge-signal IOPS read, then at most four settlement attempts at anchored offsets 100/500/1000/2000 ms; each attempt performs at most one IOPS read plus one `BatteryInfo` read;
- same-direction bursts do not restart the deadline; a reverse edge invalidates the old generation and gives the new generation its own bounded budget;
- pending work for the finishing generation permits at most one trailing paired sample.

Expose a narrow internal watchdog/visibility refresh entry point if needed so tests can invoke the behavior without waiting for a real timer.

Reason: a fallback is only real if it can reconstruct both inputs after callbacks are lost.

### Step 4: Preserve settlement generation rules

At every settlement offset:

1. read a fresh source value;
2. apply existing direction/reverse-edge generation logic;
3. read fresh `BatteryInfo`;
4. resolve the candidate with the fresh source from that attempt;
5. revalidate monitoring and transition generations after the reads and before publishing either measurement or connection state.

If the current source read fails, do not substitute `lastPowerSourceKind`. The final settlement attempt is authoritative: its resolved candidate may become stable, while unresolved final evidence becomes `uncertain(previous:)` even if an earlier attempt produced a stable candidate.

Reason: this retains bounded convergence while preventing failed reads from becoming stale success.

### Step 5: Finish the shared presentation migration

- Make `ChargeRecoveryStatusView` consume the current `BatteryPresentation` title, icon, and tone for manual recovery.
- Pass the presentation explicitly from MenuBar, Dashboard, and Settings parents.
- Make Settings observe the same `BatteryMonitor` instance and inject it from `BatteryGuardApp`.
- Remove `manualRecoveryStatusTitle` and `primaryChargeStatusTitle` after all consumers and tests are migrated.
- Keep recovery detail, observed CLI tuple, and recovery buttons unchanged.

Reason: one projection is only useful if no visible status independently reconstructs connection truth.

### Step 6: Add focused regression tests

Required monitor tests:

1. cached AC, callbacks missed, fresh Battery + explicit detached evidence -> watchdog path begins settlement and converges to disconnected;
2. cached Battery, callbacks missed, fresh AC -> visibility path begins settlement and converges to connected;
3. current IOPS reads fail during settlement -> cached AC is not reused and unresolved evidence becomes uncertain;
4. an earlier stable settlement candidate followed by an unresolved final pair -> uncertain rather than stale stable success;
5. cached AC, fresh detached `BatteryInfo`, fresh IOPS failure, and no active settlement -> uncertain(previous: connected), baseline retained, no settlement;
6. a reverse source discovered by the active settlement after a coalesced fallback request invalidates the previous generation;
7. stop/restart prevents stale fallback or trailing publication;
8. steady-state, pre-monitor, and no-baseline fallbacks remain within their numeric provider-read budgets;
9. failed transition-notification registration plus a later source change is repaired by an explicitly invoked watchdog refresh.

Required presentation tests:

10. manual recovery with stable connected, transitioning, uncertain, and disconnected observations uses one title, icon, and tone contract.

Existing coverage to rerun rather than duplicate:

- external battery-flag precedence and source `.ac`/`.battery` conflict resolution;
- `ControlMeasurement` equality when only presentation evidence changes;
- generation invalidation, same-direction burst anchoring, and notification coalescing.

Optional completeness tests, only if they remain small:

- source `.other` and malformed/missing flag combinations remain uncertain.

Reason: tests should exercise the recovery action, not merely assert that a timer exists.

### Step 7: Reconcile documentation

- Add a superseded note to `BATTERY_UI_REFRESH_FIX_PLAN.md` where it says active settlement never creates a later read.
- Update `POWER_CONNECTION_PRESENTATION_PLAN.md` execution results only after implementation and verification pass.
- Update Checkpoint 26 in `REFACTOR_PLAN.md` from automated-complete to review-remediated-complete only after all required local gates pass and the complete PR diff has no merge-blocking findings.
- Keep optional physical unplug/replug validation explicitly separate and pending.

Reason: future work must not choose between two contradictory refresh contracts.

### Step 8: Verify and update PR #33

Run, in order:

```sh
xcodebuild test -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug -destination 'platform=macOS' SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Release -destination 'platform=macOS,arch=arm64' build
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug -destination 'platform=macOS,arch=arm64' analyze
git diff --check
git diff --cached --check
```

Then:

- review the complete PR diff again;
- confirm no test invoked the real battery CLI, SMC mutation, login-item mutation, production store, or installation;
- commit the remediation in logical units;
- run `git diff --check origin/main...HEAD` against the committed PR diff;
- push normally;
- replace the PR verification section with the new test count and review result.

## Acceptance Criteria

- A missed power-source callback is repaired by watchdog or visibility refresh.
- No path uses cached `.ac` as current connection evidence after a fresh source read fails.
- A fallback-detected edge uses the same bounded settlement and generation invalidation as notification-detected edges.
- Stable, transitioning, and uncertain states remain truthful under AC-to-battery and battery-to-AC changes.
- Menu bar label, menu popover, Dashboard, Settings recovery status, and power detail agree in title, icon, and tone through `BatteryPresentation`.
- Controller measurement, backend calls, charge mode, and LED intent are unchanged by presentation-only updates.
- All automated tests, strict concurrency, warnings-as-errors, Release build, Analyze, and diff checks pass.
- Startup, pre-monitor, steady-state, edge-settlement, and trailing provider reads stay within the documented numeric budgets.
- The PR documents that physical unplug/replug observation remains optional and read-only.

## Completion Record

- Steps 1-4: complete. Current paired evidence, baseline-only source history, trigger routing, final-attempt authority, generation invalidation, and one trailing refresh are implemented.
- Step 5: complete. MenuBar, Dashboard, and Settings recovery status use the shared `BatteryPresentation` title, icon, and tone; obsolete controller title helpers are removed.
- Step 6: complete. Deterministic provider-budget, missed-event, failed-read, final-unresolved, reverse-edge, restart, registration-failure, and projection tests are present.
- Step 7: complete. `AGENTS.md`, the earlier refresh plan, the presentation plan, and Checkpoint 26 of the refactor plan describe the same contract.
- Step 8: complete. All 352 tests passed with strict concurrency and warnings as errors; Release arm64 build, Debug arm64 Analyze, diff checks, complete-diff review, commits, push, and PR #33 body update passed.
- Optional hardware observation remains pending by design. It is read-only, requires deliberate user interaction, and is not an automated or merge acceptance gate.

## PR Rejection Conditions

Reject the remediation if any of the following remains true:

- watchdog or visibility refresh rereads only `BatteryInfo`;
- cached source state is passed to current connection resolution after a source-read failure;
- a fallback source change bypasses settlement or generation checks;
- recovery UI still derives connection wording from `BatteryInfo.isPluggedIn` outside `BatteryPresentation`;
- tests only verify scheduling and do not verify missed-event convergence;
- a new polling loop, hardware mutation, control-policy change, or default real-hardware test is introduced.

## Commit Boundaries

1. `fix: refresh power connection from current evidence`
2. `fix: unify recovery connection presentation`
3. `docs: record power connection review remediation`

Steps 1-8 and all automated acceptance criteria are complete. PR #33 remains open for the separate merge decision.
