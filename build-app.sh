#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
xcodebuild -project TabDance.xcodeproj -scheme TabDance \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath .build/xcode -skipPackagePluginValidation "$@" build

app="${PWD}/dist/TabDance.app"
mkdir -p "${PWD}/dist"
rm -rf "$app"
ditto .build/xcode/Build/Products/Release/TabDance.app "$app"
print "Built $app"
