#!/bin/bash
# Builds LunaProto with swiftc and runs Tests/parser-fuzz.swift against it.
# Run ./build-swiftc.sh first (it produces the LunaProto module/library).
set -euo pipefail
cd "$(dirname "$0")/.."
D=.build-swiftc/arm64
[ "$(uname -m)" = x86_64 ] && D=.build-swiftc/x86_64
SWIFTC=(swiftc)
[ -f .build-swiftc/overlay.json ] && SWIFTC=(swiftc -vfsoverlay "$PWD/.build-swiftc/overlay.json")
"${SWIFTC[@]}" -O -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -I "$D/recv-mod" -L "$D/recv-lib" -lLunaProto \
  -framework Network -framework SystemConfiguration \
  Tests/parser-fuzz.swift -o .build-swiftc/parser-fuzz
.build-swiftc/parser-fuzz
