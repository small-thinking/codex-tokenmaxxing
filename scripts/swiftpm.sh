#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p .build/module-cache .build/cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"

# Some upgraded CLT installations retain a private Swift 5 interface next to
# a Swift 6 public interface and dylib. Use the matching public interface in a
# project-local mirror; never change the installed Apple toolchain.
swift_bin="$(xcrun --find swift)"
manifest_api="$(dirname "$swift_bin")/../lib/swift/pm/ManifestAPI"
module_dir="$manifest_api/PackageDescription.swiftmodule"
arch_name="$(uname -m)"
public_interface="$module_dir/$arch_name-apple-macos.swiftinterface"
private_interface="$module_dir/$arch_name-apple-macos.private.swiftinterface"
if [ -f "$public_interface" ] && [ -f "$private_interface" ] &&
   [ "$(sed -n '2p' "$public_interface")" != "$(sed -n '2p' "$private_interface")" ]; then
    compatibility_dir="$project_dir/.build/swiftpm-libs"
    mkdir -p "$compatibility_dir/ManifestAPI/PackageDescription.swiftmodule"
    cp "$manifest_api/libPackageDescription.dylib" "$compatibility_dir/ManifestAPI/"
    cp "$public_interface" "$compatibility_dir/ManifestAPI/PackageDescription.swiftmodule/"
    export SWIFTPM_CUSTOM_LIBS_DIR="$compatibility_dir"
fi
exec swift "$@" --disable-sandbox --cache-path "$project_dir/.build/cache" \
    --config-path "$project_dir/.build/config" --security-path "$project_dir/.build/security"
