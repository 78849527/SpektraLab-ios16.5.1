# SpectraPort — native iOS 16.5.1 port of the SpektraLab engine

This is an **unofficial source port** of [JamesQiu2005/SpektraLab](https://github.com/JamesQiu2005/SpektraLab).
It is not a lookalike LUT application. The original C++20 pipeline, the spectral film/print model,
the baked measured profiles, and the exact Metal shaders are the dependency.

## Current milestone

M0: independently generated SwiftUI iPhone project, native static C++20 engine, iOS-targeted
Metal library, the original C ABI, and a PhotoKit-to-ProPhoto RGB-to-engine live-tier render
path. The UI limits interactive decode to a 1440-pixel edge.

**Not yet validated on a real iPhone.** CI compilation and on-device rendering/parity must pass
before calling this working or compatible. The IPA is unsigned and cannot be installed without
user-side signing. RAW-specific decode and full-resolution export are not yet implemented.

## Build on macOS with Xcode

Requires Xcode with iOS SDK, command-line Metal compiler, and XcodeGen.

```sh
brew install xcodegen
bash ios/scripts/build-engine.sh
cd ios && xcodegen generate --spec project.yml
xcodebuild -project SpectraPort.xcodeproj -scheme SpectraPort \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

The actual minimum deployment target is iOS 16.0; the target test device is iOS 16.5.1.
The macOS app under modern_UI is unchanged.

## Essential parity checks before release

1. Confirm that iPhoneOS Metal links and all original kernels load.
2. Confirm the original engine's startup math-mode probe passes with safe math.
3. Render a shared reference input on macOS and iOS; compare film/print output by pixel,
   not merely by visual impression.
4. Verify the packed RGBA16 ProPhoto RGB output is colour-managed correctly by CoreGraphics.
5. Measure peak memory on iPhone, verify preview cancellation/session release and test
   out-of-memory handling before allowing full-resolution input.
6. Validate signing/installation/launch on an **actual iOS 16.5.1 device**.

Do not disable the engine's safety probe or replace the 81-wavelength model with a LUT to
make CI pass. iOS-specific fixes belong in port-scoped changes.

## Legal

The upstream app and engine are GPL-3.0-or-later. Film and paper profiles and print LUTs are
CC BY-SA 4.0; preserve attribution, original notices and share-alike requirements. SpektraLab's
name and icon are protected trademarks; this distributable uses its own name and must not imply
it is an official release.
