# Charging Activity Remediation

## Scope and evidence

Personal local app; no hardware mutations, CLI changes, native charging settings,
new distribution automation, or continuous fast polling. Existing verified control,
Heat Protection, LED ownership and shutdown rules remain unchanged.

The November 2 trace confirms prompt connection detection and disagreement between
powerd's Charging log and AppleSmartBattery.IsCharging. It does not establish when
current started flowing or when the raw flag finally changed. A public IOPS flag is
another report, not an independent sensor or a guaranteed faster source.

## Delivery order

1. `fix/charging-activity-observation`: read the current IOPS source and the unique
   internal battery's optional charging flag from one blob; retain paired raw
   measurements. Add typed, bounded, batched transition diagnostics with session
   IDs, monotonic event/read times and no identifiers. Reading an unchanged value
   does not prove a new sensor sample. Preserve old diagnostic schema decoding.
   Reuse DiagnosticLog in a separate 100-event PowerObservations.json ring so
   routine evidence cannot displace safety events or be starved by their priority.
   Flush its ordered queue after verified shutdown and before termination.
2. `fix/charging-activity-presentation`: pure presentation-only activity resolution;
   separate charging permission, system reporting and battery activity. Conflicting
   or missing evidence stays explicit. Remove unproven macOS-cause wording and the
   unconditional Top Up charging-bolt claim. Preserve safety-mode priority and
   existing control-facing measurements. Correlate projected display changes with
   observation sessions and existing verified control events.
3. `test/charging-activity-latency`: deterministic late-data (2/60/120 seconds),
   missed-event, reverse-edge, failed-read, restart and no-control-side-effect tests.
   Use evidence to decide whether extra reads help. Keep the 30-second watchdog;
   do not add a 5/10/20-second retry schedule without demonstrating a relevant gap.
   Record read/publish budgets and limits. No observation deadline may trigger a
   charge command, recovery lock or claim of hardware failure.

## Verification

- Isolated XCTest host, fake providers/backends, temporary diagnostics only.
- Strict concurrency / warnings-as-errors tests, Release build, Debug analyze.
- Review each diff, retain separate commits and dependent PR bases.
- Hardware timing reproduction remains opt-in. Automated late-report tests do not
  prove a real charger, firmware or OS timing change.
- No merge or installed-app replacement is implied by creating these PRs.

## Progress

- Observation: implemented; 386 strict-concurrency tests passed. Separate routine
  context is drained before immediate safety diagnostics and normal termination.
- Presentation: implemented; 393 strict-concurrency tests passed. Paired evidence
  stays invalid after a safety-only raw-flag change until a fresh paired read;
  Top Up projection diagnostics include bolt/icon/headline/detail changes.
- Latency and budgets: implemented; 398 strict-concurrency tests passed.
- Real-hardware reproduction: not run.

Final local verification (2026-11-02): strict-concurrency / warnings-as-errors
XCTest passed 398/398, Release build passed, Debug analyze passed, diff whitespace
check passed. Result bundle: `/tmp/BatteryGuard-activity-pr3-full-20261102`.
Read-only cumulative review found no remaining code blockers after the paired
evidence and projection-deduplication fixes. Installed-app rendering is unverified.

## Latency decision and regression coverage

- Keep the existing 100/500/1000/2000 ms connection settlement and 30-second
  watchdog. Additional activity retry timers are not justified by the available
  hardware trace. Public IOPS and raw battery reports can both remain stale;
  faster rereading does not make their underlying samples fresher.
- Synthetic reports arriving 2, 60 and 120 seconds after a power edge remain
  observable after settlement finishes. A conflicting system report is shown as
  conflicting, then a fresh agreeing pair enables the charging indication.
- Per isolated notification-driven synthetic case: startup + dedicated edge + four settlement reads + two
  routine updates = 8 source reads and 7 battery reads. The dedicated edge reads
  only the source. Fifty duplicate notifications coalesce to one additional pair,
  with no extra activity publication or diagnostic change. Monitoring infrastructure
  is disabled in these cases: this budget excludes the real 30-second watchdog
  reads during the 60/120-second waits and is not a live performance measurement.
  No new timer is added.
- A missed activity callback is recovered by one watchdog pair. The 30-second
  interval is a nominal awake-process fallback, not a hard UI deadline across
  sleep, main-thread stalls or OS data caching.
- Failed source/battery/charging-flag reads cannot reuse previous success.
  Reverse edges and restart replace the observation session/generation; stale
  settlement and queued projection work cannot publish into the new session.
- Presentation-only changes leave backend battery and LED operations unchanged.
  Readiness, failure recovery and control measurements retain their existing rules.

## Remaining opt-in validation

The automated work does not establish physical charging onset or eliminate an OS
reporting delay. With explicit hardware-test/install approval, compare the current
verified CLI tuple, AC edge, both reported flags, current direction and projected
display using the two diagnostic files. Record when evidence first changes, not a
freshness claim based only on reread time. Only add another bounded read schedule
if this evidence demonstrates available data missed by existing notifications.
