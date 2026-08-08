# BatteryGuardSMCReader

This standalone, read-only helper opens one AppleSMC connection and reads
`TB0T`, `TB1T`, and `TB2T`. It has no write interface. BatteryGuard accepts its
output only when all three expected sensors are present and otherwise falls
back to the separately installed `smc` compatibility path.

The AppleSMC user-client ABI is derived from
[`hholtmann/smcFanControl`](https://github.com/hholtmann/smcFanControl/tree/master/smc-command).
The original devnull and Michael Wilber copyright notices are retained in the
source. This helper is distributed under GPL-2.0-or-later. See the repository
`LICENSES.md` for the intended boundary between this executable and the MIT
BatteryGuard application.
