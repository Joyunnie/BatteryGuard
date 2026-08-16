# Safe removal

Do not delete BatteryGuard while it owns Maintain, Top Up, Discharge, or Heat
Protection.

1. Connect power and open BatteryGuard.
2. In Settings, choose **Disable BatteryGuard Control** and wait until the app
   reports system control / monitoring only.
3. Confirm there is no active Discharge or Top Up operation and quit the app
   normally.
4. Verify the battery CLI reports charging enabled, discharging disabled, and
   no Maintain worker. If verification fails, reopen BatteryGuard and retry the
   control-release action. Do not continue with removal.
5. After verification, an administrator may remove these exact paths:

   ```sh
   sudo rm -f /private/etc/sudoers.d/battery
   sudo rm -f /usr/local/co.palokaj.battery/battery
   sudo rm -f /usr/local/co.palokaj.battery/smc
   sudo rm -f /usr/local/co.palokaj.battery/Battery-CLI-MIT.txt
   sudo rm -f /usr/local/co.palokaj.battery/Third-Party-Notices.md
   sudo rmdir /usr/local/co.palokaj.battery
   sudo rm -rf "/Library/Application Support/BatteryGuard"
   sudo rm -rf /Applications/BatteryGuard.app
   ```

The final two commands remove only the fixed BatteryGuard application-support
directory and application bundle. Keep the app installed if any earlier safety
verification is uncertain.
