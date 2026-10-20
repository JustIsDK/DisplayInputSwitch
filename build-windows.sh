#!/bin/zsh
set -euo pipefail
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
cd "${0:A:h}"
sdk="${DOTNET_BIN:-$PWD/.dotnet/dotnet}"
if [[ ! -x "$sdk" ]]; then sdk=dotnet; fi
"$sdk" publish Windows/DisplayInputSwitch.csproj -c Release -r win-x64 \
  --self-contained true -p:PublishSingleFile=true -p:EnableWindowsTargeting=true \
  -o build/windows-x64
