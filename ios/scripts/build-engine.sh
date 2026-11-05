#!/usr/bin/env bash
# Compile the *original* C++20 + Metal implementation for iPhoneOS.
# Do not use engine/build.sh: that script explicitly targets macOS >= 15.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/engine"
OUT="$ROOT/ios/build"
RESOURCE_OUT="$ROOT/ios/SpectraPort/Resources/engine"
SDK="${SDK:-iphoneos}"
MIN="16.0"
ARCH="${ARCH:-arm64}"

if [[ "$SDK" != "iphoneos" && "$SDK" != "iphonesimulator" ]]; then
  echo "SDK must be iphoneos or iphonesimulator" >&2
  exit 2
fi
if [[ "$SDK" == "iphoneos" ]]; then
  MIN_FLAG="-miphoneos-version-min=$MIN"
else
  MIN_FLAG="-mios-simulator-version-min=$MIN"
fi
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
mkdir -p "$OUT/objects" "$OUT/air" "$RESOURCE_OUT"
if [[ ! -f "$ENGINE/resources/spektrafilm_constants.bin" ]]; then
  echo "Missing tracked engine/resources/spektrafilm_constants.bin" >&2
  exit 1
fi
if [[ ! -f "$ENGINE/third_party/metal-cpp/Metal/Metal.hpp" ]]; then
  echo "Missing vendored metal-cpp headers" >&2
  exit 1
fi

# Do not compile Vulkan, Windows or desktop-only UI sources.
SOURCES=(
  "$ENGINE"/src/core/*.cpp
  "$ENGINE"/src/pipeline/blur.cpp
  "$ENGINE"/src/pipeline/contrast_mask.cpp
  "$ENGINE"/src/pipeline/engine.cpp
  "$ENGINE"/src/pipeline/overscan.cpp
  "$ENGINE"/src/pipeline/pipeline.cpp
  "$ENGINE"/src/pipeline/scene_latitude.cpp
  "$ENGINE"/src/gpu/metal_gpu.cpp
  "$ENGINE"/src/gpu/metal_impl.cpp
)
OBJECTS=()
for src in "${SOURCES[@]}"; do
  obj="$OUT/objects/$(basename "${src%.cpp}").o"
  echo "[C++] $(basename "$src")"
  xcrun --sdk "$SDK" clang++ -arch "$ARCH" -isysroot "$SYSROOT" "$MIN_FLAG" \
    -std=c++20 -O2 -DNDEBUG \
    -I"$ENGINE/include" -I"$ENGINE/src" -I"$ENGINE/src/core" \
    -I"$ENGINE/third_party/metal-cpp" \
    -c "$src" -o "$obj"
  OBJECTS+=("$obj")
done
xcrun --sdk "$SDK" libtool -static -o "$OUT/libspektrafilm_engine.a" "${OBJECTS[@]}"

# Precision is part of SpektraLab's physical-model correctness contract.
# Fail rather than silently substituting fast-math shaders.
AIRS=()
for shader in "$ENGINE"/src/shaders/*.metal; do
  air="$OUT/air/$(basename "${shader%.metal}").air"
  echo "[Metal] $(basename "$shader")"
  xcrun --sdk "$SDK" metal "$MIN_FLAG" \
    -fmetal-math-mode=safe -fmetal-math-fp32-functions=precise \
    -Werror -c "$shader" -o "$air"
  AIRS+=("$air")
done
xcrun --sdk "$SDK" metallib "${AIRS[@]}" -o "$OUT/spektrafilm.metallib"

rsync -a "$ENGINE/resources/" "$RESOURCE_OUT/"
cp "$OUT/spektrafilm.metallib" "$RESOURCE_OUT/spektrafilm.metallib"
if [[ -d "$ENGINE/resources_product/profiles" ]]; then
  mkdir -p "$RESOURCE_OUT/profiles"
  cp "$ENGINE"/resources_product/profiles/*.json "$RESOURCE_OUT/profiles/"
  cp "$ENGINE/resources_product/NOTICE.md" "$RESOURCE_OUT/PRODUCT_PROFILES_NOTICE.md"
fi
echo "Original engine and iOS Metal library prepared: $OUT"
