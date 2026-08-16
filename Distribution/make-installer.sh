#!/bin/zsh

set -euo pipefail

readonly script_dir="${0:A:h}"
readonly repo_root="${script_dir:h}"
readonly version="1.0"
readonly output_dir="${1:-${repo_root}/dist}"
readonly output_pkg="${output_dir}/BatteryGuard-${version}-Installer.pkg"

readonly battery_commit="8287c31802e4ca5baff0a97e9d48ab07a0b8a398"
readonly battery_sha256="ce1917ba2176851bf6096f1a343ff9e1306c748e1ee2c5fbe9e37fa3cd45bf04"
readonly smc_sha256="e3b4392c966dee700f3e1d6cc3812c0d487954c3d6d77b91f521a9590aadae44"
readonly smc_source_commit="e1bd672bcd2d72eddff9b6da7b9cae38e35c4206"

readonly -A source_hashes=(
  smc.c "13c0336cc51045de9f095d2e38bce6dc36dcccd145b3ff450b9c309768dbcf23"
  smc.h "eda500485ba3663b8597acf88a09c9aa02fd2ed876bb4076ac776425ee8b5244"
  Makefile "882fed32d0a175c17a99c6180a65879f37a3d0199f1832d69c9fcdbc6c1a3ce4"
  LICENSE "ab15fd526bd8dd18a9e77ebc139656bf4d33e97fc7238cd11bf60e2b9b8666c6"
  README.md "d9dfd3373b3a4eedc6cde72daee69119f7e2e5dba177021f93caac48a02123dc"
)

fail() {
  print -u2 -- "error: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

download_verified() {
  local url="$1"
  local destination="$2"
  local expected_hash="$3"

  /usr/bin/curl --fail --location --silent --show-error \
    --proto '=https' --tlsv1.2 \
    --output "$destination" "$url"
  local actual_hash
  actual_hash="$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}')"
  [[ "$actual_hash" == "$expected_hash" ]] || \
    fail "checksum mismatch for ${url}: expected ${expected_hash}, received ${actual_hash}"
}

for command_name in curl shasum xcodebuild codesign pkgbuild productbuild pkgutil ditto; do
  require_command "$command_name"
done

[[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "the installer can only be built on Apple Silicon"
[[ -d "${repo_root}/BatteryGuard.xcodeproj" ]] || fail "run this script from the BatteryGuard repository"
[[ -z "$(/usr/bin/git -C "$repo_root" status --porcelain --untracked-files=normal)" ]] || \
  fail "commit or remove source changes before building a distributable package"

work_dir="$(/usr/bin/mktemp -d /tmp/batteryguard-installer.XXXXXX)"
cleanup() {
  /bin/rm -rf "$work_dir"
}
handle_signal() {
  trap - INT TERM
  exit 130
}
trap cleanup EXIT
trap handle_signal INT TERM

readonly derived_data="${work_dir}/DerivedData"
readonly dependencies="${work_dir}/Dependencies"
readonly payload="${work_dir}/Payload"
readonly packages="${work_dir}/Packages"
readonly expanded_pkg="${work_dir}/Expanded"
readonly installer_assets="${payload}/Library/Application Support/BatteryGuard/InstallerAssets"

/bin/mkdir -p \
  "$dependencies/smc-source" \
  "$installer_assets/smc-source" \
  "$installer_assets/BatteryGuardSMCReader-source" \
  "$packages" \
  "$output_dir"

download_verified \
  "https://raw.githubusercontent.com/actuallymentor/battery/${battery_commit}/battery.sh" \
  "$dependencies/battery" \
  "$battery_sha256"
download_verified \
  "https://raw.githubusercontent.com/actuallymentor/battery/${battery_commit}/dist/smc" \
  "$dependencies/smc" \
  "$smc_sha256"

for source_name source_hash in ${(kv)source_hashes}; do
  download_verified \
    "https://raw.githubusercontent.com/hholtmann/smcFanControl/${smc_source_commit}/smc-command/${source_name}" \
    "$dependencies/smc-source/${source_name}" \
    "$source_hash"
done

download_verified \
  "https://raw.githubusercontent.com/actuallymentor/battery/${battery_commit}/LICENSE" \
  "$dependencies/Battery-CLI-MIT.txt" \
  "a2b9af548380c1fae9d668e538e3ca36894038b301a371f52f817f678dc88d27"

/usr/bin/grep -qF 'BATTERY_CLI_VERSION="v1.3.4"' "$dependencies/battery" || \
  fail "the pinned battery script does not declare the supported v1.3.4 contract"

print -- "Building BatteryGuard Release app…"
/usr/bin/xcodebuild \
  -project "${repo_root}/BatteryGuard.xcodeproj" \
  -scheme BatteryGuard \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=YES \
  build >/dev/null

readonly app_path="${derived_data}/Build/Products/Release/BatteryGuard.app"
[[ -d "$app_path" ]] || fail "Release app was not produced"
/usr/bin/codesign --verify --deep --strict "$app_path"
[[ "$(/usr/bin/file -b "${app_path}/Contents/MacOS/BatteryGuard")" == *"arm64"* ]] || \
  fail "Release app is not an Apple Silicon executable"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${app_path}/Contents/Info.plist")" == "14.0" ]] || \
  fail "unexpected deployment target"

/usr/bin/ditto "$app_path" "${payload}/Applications/BatteryGuard.app"
/usr/bin/install -m 755 "$dependencies/battery" "$installer_assets/battery"
/usr/bin/install -m 755 "$dependencies/smc" "$installer_assets/smc"
/bin/cp "$dependencies/Battery-CLI-MIT.txt" "$installer_assets/Battery-CLI-MIT.txt"
/bin/cp "$dependencies/smc-source/"* "$installer_assets/smc-source/"
/bin/cp "${repo_root}/LICENSE" "$installer_assets/BatteryGuard-MIT.txt"
/bin/cp "${repo_root}/SMCTemperatureReader/main.c" "$installer_assets/BatteryGuardSMCReader-source/main.c"
/bin/cp "${repo_root}/SMCTemperatureReader/README.md" "$installer_assets/BatteryGuardSMCReader-source/README.md"
/bin/cp \
  "${repo_root}/SMCTemperatureReader/SMCTemperatureReader-GPL-2.0.txt" \
  "$installer_assets/BatteryGuardSMCReader-source/LICENSE"
/bin/cp "${script_dir}/Templates/battery.sudoers" "$installer_assets/battery.sudoers"
/bin/cp "${script_dir}/Templates/Third-Party-Notices.md" "$installer_assets/Third-Party-Notices.md"
/bin/cp "${script_dir}/UNINSTALL.md" "$installer_assets/UNINSTALL.md"
/usr/bin/xattr -cr "$payload"
/usr/bin/codesign --verify --deep --strict "${payload}/Applications/BatteryGuard.app"

/usr/bin/pkgbuild \
  --root "$payload" \
  --ownership recommended \
  --identifier com.jiwon.batteryguard.friend-installer.payload \
  --version "$version" \
  --install-location / \
  --scripts "${script_dir}/Scripts" \
  "$packages/BatteryGuard-payload.pkg" >/dev/null

readonly staged_output_pkg="${work_dir}/BatteryGuard-${version}-Installer.pkg"
/usr/bin/productbuild \
  --distribution "${script_dir}/Distribution.xml" \
  --resources "${script_dir}/Resources" \
  --package-path "$packages" \
  "$staged_output_pkg" >/dev/null

/usr/sbin/pkgutil --expand-full "$staged_output_pkg" "$expanded_pkg"
[[ -f "$expanded_pkg/Distribution" ]] || fail "final package could not be expanded"
[[ -f "$expanded_pkg/BatteryGuard-payload.pkg/Payload/Applications/BatteryGuard.app/Contents/MacOS/BatteryGuard" ]] || \
  fail "final package does not contain BatteryGuard.app"
[[ -f "$expanded_pkg/BatteryGuard-payload.pkg/Payload/Library/Application Support/BatteryGuard/InstallerAssets/battery" ]] || \
  fail "final package does not contain the battery CLI"
[[ -f "$expanded_pkg/BatteryGuard-payload.pkg/Payload/Library/Application Support/BatteryGuard/InstallerAssets/smc" ]] || \
  fail "final package does not contain the SMC executable"
[[ -f "$expanded_pkg/BatteryGuard-payload.pkg/Payload/Library/Application Support/BatteryGuard/InstallerAssets/battery.sudoers" ]] || \
  fail "final package does not contain the least-privilege sudoers template"
[[ -f "$expanded_pkg/BatteryGuard-payload.pkg/Payload/Library/Application Support/BatteryGuard/InstallerAssets/smc-source/LICENSE" ]] || \
  fail "final package does not contain the SMC corresponding-source license"
[[ -f "$expanded_pkg/BatteryGuard-payload.pkg/Payload/Library/Application Support/BatteryGuard/InstallerAssets/BatteryGuardSMCReader-source/main.c" ]] || \
  fail "final package does not contain the bundled reader corresponding source"
[[ -f "$expanded_pkg/BatteryGuard-payload.pkg/Payload/Library/Application Support/BatteryGuard/InstallerAssets/UNINSTALL.md" ]] || \
  fail "final package does not contain safe removal guidance"
[[ -z "$(/usr/bin/find "$expanded_pkg/BatteryGuard-payload.pkg/Payload" -type l -print -quit)" ]] || \
  fail "final package payload unexpectedly contains a symbolic link"
/usr/bin/cmp -s "$script_dir/Scripts/preinstall" "$expanded_pkg/BatteryGuard-payload.pkg/Scripts/preinstall" || \
  fail "packaged preinstall script differs from the reviewed source"
/usr/bin/cmp -s "$script_dir/Scripts/postinstall" "$expanded_pkg/BatteryGuard-payload.pkg/Scripts/postinstall" || \
  fail "packaged postinstall script differs from the reviewed source"

/bin/mv -f "$staged_output_pkg" "$output_pkg"

print -- "Created: ${output_pkg}"
/usr/bin/shasum -a 256 "$output_pkg"
print -- "Note: this package is unsigned; the recipient must use macOS Privacy & Security → Open Anyway."
