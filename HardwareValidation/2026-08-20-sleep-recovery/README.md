# Sleep Charging Recovery Hardware Validation

Date: 2026-08-20
Machine scope: the single Apple Silicon Mac used by this personal BatteryGuard installation

## Verdict

All eight operational validation conditions passed. Evidence completeness has the raw-capacity limitation documented below. Safety invariants held across idle sleep, cancellation, short and long clamshell sleep, rapid repetition, and AC removal/insertion while asleep:

- charging was verified disabled and force discharge was off before every observed system sleep;
- a forced event following a vetoable event used read-only verification instead of repeating the mutation;
- wake or cancellation restored verified Maintain 80 within approximately 0.76–1.1 seconds in the directly measured stable paths;
- every final stable state had one exact `maintain_synchronous 80` worker and a matching PID file;
- no stale completion, duplicate worker, forced discharge, timeout, or manual-recovery state was observed.

## Matrix

| Condition | Evidence | Result |
|---|---|---|
| Idle sleep allowed, then wake | `01-idle-sleep-allow.txt` | Pass with platform variance: macOS emitted forced sleep rather than a vetoable-only request |
| Vetoable idle sleep cancelled | `02d-idle-iokit-veto.txt` | Pass: `IOCancelPowerChange` produced `negotiationCancelled`; Maintain restored in ~0.76 s |
| Short clamshell sleep | `04-lid-short-retry.txt` | Pass |
| Clamshell sleep longer than 10 minutes | `03-lid-short.txt` | Pass with documented evidence limitation; 12m27s, visible charge stayed at 70% |
| Rapid sleep/wake repetition | `05-rapid-lid-cycles.txt` | Pass; four cycles |
| Disconnect AC while asleep | `06-disconnect-ac-asleep.txt` | Pass |
| Connect AC while asleep | `07-connect-ac-asleep.txt` | Pass; USB-C plug DarkWake captured |
| Three consecutive forced generations without accumulation | `08-forced-generation-stability.txt` | Pass; conditions co-verified by the four-cycle trial |

The failed/partial attempts for the cancellation scenario are retained in `02-idle-sleep-cancel.txt`, `02b-idle-sleep-cancel-retry.txt`, and `02c-idle-cancel-watcher.txt`. They are excluded from the pass claim and document why the final IOKit-veto method was required.

## Evidence limitation

The preflight and first idle-sleep trial retained `AppleRawCurrentCapacity` and `AppleRawMaxCapacity`. Later trial capture commands accidentally filtered those keys out and retained normalized capacity, percentage, power-source transitions, CLI tuple, operation-correlated diagnostics, and exact worker identity instead. The long clamshell trial still showed 70% at both ends, verified charging-off before sleep, and no unexpected full wake until the lid opened. This limitation is recorded rather than reconstructing or inventing historical raw values.

## Environment restoration

- temporary `pmset` values were restored to `displaysleep 10` and `sleep 1` for AC and battery;
- Amphetamine was restored to an infinite non-trigger session with display sleep prevented and closed-display sleep allowed;
- the one-shot IOKit veto helper was built outside the repository and removed after use;
- final BatteryGuard control and installed-artifact evidence is stored in `99-final-state.txt`.
