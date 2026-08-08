# License Map

- BatteryGuard application code is licensed under the repository-level MIT
  license in `LICENSE`.
- `SMCTemperatureReader/` is a separate GPL-2.0-or-later executable derived
  from the `smc-command` code in hholtmann/smcFanControl. Its source retains
  the upstream copyright notices and its license is stored at
  `SMCTemperatureReader/SMCTemperatureReader-GPL-2.0.txt`.

The helper communicates with BatteryGuard only through a subprocess stdout
contract. Anyone distributing its executable separately must provide the
corresponding source under GPL-2.0-or-later.
