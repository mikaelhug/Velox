# Sourced (not run) by every script that invokes `swift`: select the Xcode toolchain the host
# is built with, and refuse to build with anything else.
#
# Velox builds against the macOS SDK of XCODE_MAJOR (versions.env), exactly as the release CI
# does. That SDK's SwiftUI expands `@State` through the SwiftUIMacros plugin, which ships only
# with Xcode, so the Command Line Tools can't build the app at all. This used to fall back to
# an older SDK instead — and the local build then quietly differed from the one users got:
# SwiftUI ran `VeloxApp.init` twice only in the SDK-27 build, the local build never showed it.
# So: use Xcode's developer dir even when `xcode-select` still points at the CLT, and fail
# loudly when the right toolchain isn't there. An explicit DEVELOPER_DIR wins.
velox_select_toolchain() {
    local want xcode sdk have probe
    want="$(. ./versions.env && echo "$XCODE_MAJOR")"
    if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" != *.app/Contents/Developer ]]; then
        for xcode in /Applications/Xcode.app /Applications/Xcode-"$want"*.app; do
            if [ -d "$xcode/Contents/Developer" ]; then
                export DEVELOPER_DIR="$xcode/Contents/Developer"
                break
            fi
        done
    fi
    # The SDK `swift build` will actually use: SDKROOT when set, else the toolchain's default.
    # Read from the SDK itself — `xcrun --show-sdk-version` ignores an SDKROOT path.
    sdk="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)}"
    have="$(/usr/libexec/PlistBuddy -c 'Print :Version' "$sdk/SDKSettings.plist" 2>/dev/null || echo 0)"
    if [ "${have%%.*}" -lt "$want" ]; then
        echo "error: Velox builds against macOS SDK $want (Xcode $want); this build would use SDK $have ($sdk)." >&2
        if [ -n "${SDKROOT:-}" ]; then
            echo "       Unset SDKROOT." >&2
        else
            echo "       Install Xcode $want, then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
        fi
        return 1
    fi
    probe="$(mktemp -d)"
    printf 'import SwiftUI\nstruct P: View { @State var n = 0; var body: some View { Text("") } }\n' \
        > "$probe/p.swift"
    if ! xcrun swiftc -sdk "$sdk" -typecheck "$probe/p.swift" 2>/dev/null; then
        rm -rf "$probe"
        echo "error: this toolchain can't compile SwiftUI's @State against macOS SDK $have — the" >&2
        echo "       SwiftUIMacros plugin ships only with Xcode. Select Xcode $want:" >&2
        echo "       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
        return 1
    fi
    rm -rf "$probe"
    echo "==> toolchain: $(xcrun swift --version 2>/dev/null | sed -n 's/.*\(Swift version [0-9.]*\).*/\1/p' | head -1)," \
         "macOS SDK $have ($sdk)"
}
velox_select_toolchain
