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
- Presentation: pending.
- Latency and budgets: pending.
- Real-hardware reproduction: not run.
