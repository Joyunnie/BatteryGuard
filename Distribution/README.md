# Friend Installer

`make-installer.sh` creates one macOS Installer package containing:

- the arm64 Release build of BatteryGuard;
- the pinned, hardware-verified battery CLI contract (`v1.3.4`);
- the matching `smc` executable and corresponding GPL source snapshot;
- a least-privilege sudoers policy for the console user; and
- Korean setup guidance for macOS battery settings.

The dependency files are downloaded from immutable upstream commits and
SHA-256 verified before packaging. No downloaded script is executed during the
build or installation.

```sh
./Distribution/make-installer.sh
```

The result is written to `dist/BatteryGuard-1.0-Installer.pkg`. The
package is intentionally not committed.

Because the package is unsigned, send its printed SHA-256 through a separate
trusted message. Before opening it, the recipient should run:

```sh
shasum -a 256 BatteryGuard-1.0-Installer.pkg
```

Install only when the result exactly matches the separately received value.

Before a build, the script requires a clean Git worktree. It then validates
the pinned battery CLI version string, builds an arm64 Release app, creates the
package in a temporary directory, expands and inspects the finished payload,
and only then replaces the file in `dist/`.

## Installation and removal

The recipient must read the ownership guidance shown by Installer. Installation
starts BatteryGuard in monitoring-only mode and does not claim charge control.
Use **BatteryGuard Control** only after disabling macOS Charge Limit and other
battery-control apps.

Removal is intentionally manual because silently removing a persistent Maintain
worker would be unsafe. Follow `UNINSTALL.md`: release BatteryGuard control in
the app and verify normal charging before removing the installed files.

## Distribution limitation

This repository currently has no Developer ID Application or Developer ID
Installer certificate. The generated package is therefore suitable for a
trusted friend, but macOS will show an unidentified-developer warning. A
warning-free package requires Developer ID signing and Apple notarization.
