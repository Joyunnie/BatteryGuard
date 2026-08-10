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

## Distribution limitation

This repository currently has no Developer ID Application or Developer ID
Installer certificate. The generated package is therefore suitable for a
trusted friend, but macOS will show an unidentified-developer warning. A
warning-free package requires Developer ID signing and Apple notarization.
