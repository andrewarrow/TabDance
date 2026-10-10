#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
swift build -c release

app="${PWD}/dist/TabDance.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/TerminalLab "$app/Contents/MacOS/TerminalLab"
cp Info.plist "$app/Contents/Info.plist"
cp THIRD_PARTY_LICENSES.txt "$app/Contents/Resources/THIRD_PARTY_LICENSES.txt"
cp -R .build/release/SwiftTerm_SwiftTerm.bundle "$app/Contents/Resources/"
codesign --force --sign - "$app"
print "Built $app"
