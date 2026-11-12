#!/bin/bash
# Builds the sender and receiver binaries with plain swiftc/clang, without
# SwiftPM. Use this when `swift build` fails on a command-line-tools-only
# install ("Invalid manifest ... PackageDescription" link errors).
#
# Output: .build-swiftc/universal/{LunaSender,LunaReceiver}
# Pass the output dir to make-apps.sh via LUNA_BIN (make-apps.sh does this
# automatically when swift build is unusable).
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --sdk macosx --show-sdk-path)
OUT=.build-swiftc
rm -rf "$OUT"
mkdir -p "$OUT"

# Some Command Line Tools 16.x installs ship the same SwiftBridging module
# twice (module.modulemap and bridging.modulemap), which breaks every Swift
# compile with "redefinition of module 'SwiftBridging'". Hide the duplicate
# with a throwaway VFS overlay instead of editing system files.
SWIFTC=(swiftc)
CLT_SWIFT_INC=/Library/Developer/CommandLineTools/usr/include/swift
if [ -f "$CLT_SWIFT_INC/module.modulemap" ] && [ -f "$CLT_SWIFT_INC/bridging.modulemap" ]; then
  : > "$OUT/empty.modulemap"
  cat > "$OUT/overlay.json" <<OV
{"version":0,"case-sensitive":"false","roots":[{"type":"directory","name":"$CLT_SWIFT_INC","contents":[{"type":"file","name":"bridging.modulemap","external-contents":"$PWD/$OUT/empty.modulemap"}]}]}
OV
  SWIFTC=(swiftc -vfsoverlay "$PWD/$OUT/overlay.json")
fi

build_arch() {  # build_arch <arch>
  local arch=$1 d="$OUT/$1"
  mkdir -p "$d"
  local sender_t="$arch-apple-macos13.0" recv_t="$arch-apple-macos10.15"

  # Hand-written module map for the private CoreGraphics declarations.
  mkdir -p "$d/cvd"
  cat > "$d/cvd/module.modulemap" <<MM
module CVD {
    header "$PWD/Sources/CVD/include/CGVirtualDisplay.h"
    link framework "CoreGraphics"
    export *
}
MM
  clang -c -arch "$arch" -mmacosx-version-min=10.15 -isysroot "$SDK" \
    -I Sources/CVD/include Sources/CVD/CVD.m -o "$d/CVD.o"

  # Shared libraries are built once per deployment target so the receiver
  # keeps its 10.15 floor while the sender gets macOS 13.
  for kind in sender recv; do
    local t=$sender_t
    [ $kind = recv ] && t=$recv_t
    local m="$d/$kind-mod" l="$d/$kind-lib"
    mkdir -p "$m" "$l"
    "${SWIFTC[@]}" -O -parse-as-library -emit-library -static \
      -module-name LunaProto -emit-module -emit-module-path "$m/LunaProto.swiftmodule" \
      -target "$t" -sdk "$SDK" Sources/LunaProto/*.swift -o "$l/libLunaProto.a"
    "${SWIFTC[@]}" -O -parse-as-library -emit-library -static \
      -module-name LunaMedia -emit-module -emit-module-path "$m/LunaMedia.swiftmodule" \
      -I "$m" -target "$t" -sdk "$SDK" Sources/LunaMedia/*.swift -o "$l/libLunaMedia.a"
  done

  "${SWIFTC[@]}" -O -module-name LunaSender -target "$sender_t" -sdk "$SDK" \
    -I "$d/sender-mod" -L "$d/sender-lib" -lLunaProto -lLunaMedia \
    -Xcc -fmodule-map-file="$d/cvd/module.modulemap" "$d/CVD.o" \
    -framework AppKit -framework ScreenCaptureKit -framework VideoToolbox \
    -framework CoreMedia -framework CoreVideo -framework Network \
    -framework IOKit -framework SystemConfiguration \
    Sources/LunaSender/*.swift -o "$d/LunaSender"

  "${SWIFTC[@]}" -O -module-name LunaReceiver -target "$recv_t" -sdk "$SDK" \
    -I "$d/recv-mod" -L "$d/recv-lib" -lLunaProto -lLunaMedia \
    -framework AppKit -framework AVFoundation -framework CoreMedia \
    -framework VideoToolbox -framework Network -framework IOKit \
    -framework SystemConfiguration \
    Sources/LunaReceiver/*.swift -o "$d/LunaReceiver"
}

build_arch arm64
build_arch x86_64

mkdir -p "$OUT/universal"
for app in LunaSender LunaReceiver; do
  lipo -create "$OUT/arm64/$app" "$OUT/x86_64/$app" -output "$OUT/universal/$app"
done
echo "Built: $OUT/universal/LunaSender  $OUT/universal/LunaReceiver"
