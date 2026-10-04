#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
support="$root/.build/toolchain-support"
mkdir -p "$support"
args=()
developer="$(xcode-select -p)"
manifest="$developer/usr/lib/swift/pm/ManifestAPI"
# Some partially upgraded CLT installations retain Swift 5.9 private interfaces
# beside Swift 6 libraries. Fix only a project-local copy, never the installation.
if [[ -f "$manifest/PackageDescription.swiftmodule/arm64-apple-macos.private.swiftinterface" ]] &&
   grep -q 'enum SwiftVersion' "$manifest/PackageDescription.swiftmodule/arm64-apple-macos.private.swiftinterface" &&
   grep -q 'enum SwiftLanguageMode' "$manifest/PackageDescription.swiftmodule/arm64-apple-macos.swiftinterface"; then
    if [[ ! -d "$support/libs/ManifestAPI" ]]; then
        mkdir -p "$support/libs"
        cp -R "$manifest" "$support/libs/"
        rm -f "$support/libs/ManifestAPI/PackageDescription.swiftmodule/"*.private.swiftinterface
    fi
    export SWIFTPM_CUSTOM_LIBS_DIR="$support/libs"
fi
if [[ -f "$developer/usr/include/swift/module.modulemap" && -f "$developer/usr/include/swift/bridging.modulemap" ]] &&
   grep -q 'module SwiftBridging' "$developer/usr/include/swift/module.modulemap"; then
    touch "$support/empty.modulemap"
    /usr/bin/python3 - "$developer" "$support" <<'PY'
import json,sys
from pathlib import Path
developer,support=sys.argv[1:]
Path(support,'overlay.json').write_text(json.dumps({'version':0,'roots':[{'type':'file','name':developer+'/usr/include/swift/module.modulemap','external-contents':support+'/empty.modulemap'}]}))
PY
    args=(-Xswiftc -vfsoverlay -Xswiftc "$support/overlay.json")
fi
export CLANG_MODULE_CACHE_PATH="$support/module-cache"
command="$1"
shift
exec swift "$command" --package-path "$root" "${args[@]}" "$@"
