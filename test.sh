#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
xcrun swiftc Sources/Configuration.swift Tests/CoreChecks/main.swift -o build/core-checks
build/core-checks
zsh build.sh
