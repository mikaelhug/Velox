# Sourced (not run) by build.sh and build-app.sh: choose the macOS SDK `swift build`
# compiles against.
#
# Normally that is simply the default — the newest. But Command Line Tools 27.0 ship the
# macOS 27 SDK WITHOUT the SwiftUIMacros compiler plugin that SDK's `@State` expands
# through, so with CLT alone VeloxApp cannot compile against it at all (Xcode 27 carries the
# plugin; CI builds there). When the default SDK fails that exact probe, fall back to the
# newest installed SDK that passes, and say so. The deployment target lives in
# Package.swift and is unaffected, so either way the product is the same macOS 15+ app.
# An explicit SDKROOT always wins.
velox_select_sdk() {
    if [ -n "${SDKROOT:-}" ]; then
        echo "==> macOS SDK: $SDKROOT (from SDKROOT)"
        return
    fi
    local probe sdk
    probe="$(mktemp -d)"
    printf 'import SwiftUI\nstruct P: View { @State var n = 0; var body: some View { Text("") } }\n' \
        > "$probe/p.swift"
    if xcrun swiftc -typecheck "$probe/p.swift" 2>/dev/null; then
        rm -rf "$probe"
        return
    fi
    # Versioned names only: MacOSX27.sdk is a symlink to MacOSX27.0.sdk, and probing the
    # same SDK twice doubles the cost of the failing case.
    for sdk in $(ls -d "$(dirname "$(xcrun --sdk macosx --show-sdk-path)")"/MacOSX[0-9]*.[0-9]*.sdk \
                     2>/dev/null | sort -rV); do
        if xcrun swiftc -sdk "$sdk" -typecheck "$probe/p.swift" 2>/dev/null; then
            rm -rf "$probe"
            export SDKROOT="$sdk"
            echo "==> note: the default macOS SDK can't compile SwiftUI's @State here (no SwiftUIMacros" \
                 "plugin in these Command Line Tools) — building against $(basename "$sdk")" >&2
            return
        fi
    done
    rm -rf "$probe"
    echo "==> warning: no installed macOS SDK compiles SwiftUI's @State — VeloxApp will fail;" \
         "install Xcode or a newer Command Line Tools" >&2
}
velox_select_sdk
