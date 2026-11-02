#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
xcrun swiftc Sources/Configuration.swift Tests/CoreChecks/main.swift -o build/core-checks
build/core-checks
xcrun swiftc -parse-as-library Sources/Configuration.swift Sources/ColorProfile.swift Sources/HDR.swift Tests/DisplaySettings/main.swift -framework ColorSync -o build/display-settings-check
build/display-settings-check
python3 -B Tests/release-check.py
zsh build.sh
