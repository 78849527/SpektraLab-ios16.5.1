# iOS ↔ desktop Layer 1 / Layer 2 parity contract

**Status (feature branch):** the original macOS curves, adjustments
and complete local-mask *models*, and the unmodified Shaders.metal::layer2
kernel, now compile for iPhoneOS 16. The iOS branch connects Layer 2 to
**both** the 1440-pixel realtime preview and its full-resolution JPEG/PNG
export, with all-identity bypass, the original five-channel curve LUT,
four-zone colour balance and analytical linear/radial/luminance local masks.
A cached copy of the original 16-bit ProPhoto print prevents unrelated
Layer 2 edits from reopening or reprinting the 81-wavelength negative.

**The released v0.13.0 Build 19 is unchanged.** Branch builds are not a
shipping quality or physical-device validation. Do not release the branch
without tests on the actual A15 iPhone at 6MP and 12.5MP, cross-platform
pixel comparisons, and memory/thermal validation.

## Three distinct targets

1. **Layer 1 / measured spectral print:** keep original C++20 engine, original
   Metal shaders and measured film/paper profiles. On all platforms verify
   the identical source image linearization, white point, input colour space,
   parameter JSON, active/default values, rendering mode and print output.
   The iOS port currently fixes `product_defaults=true`,
   `filter_shift_scale=40` and a user-tunable pre-film softness, which means
   default desktop equivalence is NOT established. Compare with the *actual*
   desktop API requests rather than hardcoding guessed defaults.
2. **Layer 2 / scan adjustments:** reuse exact Mac
   `Model/Adjustments.swift`, `Model/CurveMath.swift`,
   `Model/Mask.swift` data models, with `Canvas/Shaders.metal::layer2`
   as the reference arithmetic. The Windows Tauri code explicitly ports these
   models in `desktop/src/shared/adjustments.ts` plus WebGL shader. Preserve
   processing order: white balance → exposure/contrast/brightness →
   highlights/shadows → black/white point → saturation → colour balance →
   five-channel monotone cubic curves → local masks → vignette. Mac working
   space is ProPhoto (ROMM encoding), Windows WebGL has an explicitly
   sRGB-like pivot. Do not silently use a different mid-grey in iOS.
3. **Local edits / masks:** Mac's implementation has 5 mask kinds (linear,
   radial, luminance, colour, brush) and geometry-independent coordinates,
   but `FeatureFlags.masks=false` explicitly disables the feature in the
   current Mac product due to unresolved interaction design. Its tone mask
   is also disabled. Do not describe it as a shipped macOS feature or quietly
   enable it in an iOS public release. Review interaction before enabling;
   distinguish mask compositing from the engine's contrast mask.

## Validation gates before user-facing iOS UI

- Compile and test shared CurveMath and Adjustments models directly from the
  original Mac source, including the Fritsch–Carlson 256-entry five-row LUT.
- Implement the Mac Layer 2 *after* the original spectral print; no substitute
  Core Image slider effects presented as the same functionality.
- Match colours using an explicit ROMM working space and correct exposure
  pivot; verify both the live preview and full JPEG/PNG export are processed.
- Differential fixtures: identity layer must be pixel-preserving; exposures,
  curve table, highlights, gradients and 16-bit colour patches must compare
  to desktop outputs with stated tolerances and explicit conversion paths.
- Add touch curves, histograms and parameter tabs only once the pass is
  actually active for both preview and export; avoid a nonfunctional UI.
- Masks require selection, geometry, inversion, feather, layering, brush
  pressure/strokes and serialized sidecar settings. Prove identical
  full-resolution export, zoom and re-render.
- Test on the verified iPhone A15 with 6MP and 12.5MP size ceilings, memory
  headroom, repeated photo switches and cancellation.

## Current feature branch

`feature/ios16-desktop-layer2-parity`

This branch deliberately does not publish a replacement IPA until the layer
is connected end-to-end and cross-platform fixtures pass. The existing
`port/ios16-native-engine` release remains safe.

## Implemented on the feature branch

- `Engine/DesktopCurveMath.swift` — desktop monotone cubic interpolation,
  five 256-element LUT rows; a touch curve UI with endpoint constraints.
- `Engine/DesktopAdjustments.swift` — exact Mac 16-bit encoded ROMM post-print
  controls, including colour balance. A touch colour wheel edits the same
  `ColorZone` values as macOS.
- `Engine/DesktopMasks.swift` — exact macOS EditMask and component models.
  The iOS GPU adapter packs original `MaskUniform` structs for linear,
  radial, luminance and colour analytic masks. The iPhone UI currently offers
  **linear, radial and luminance**; a colour-range picker is not ready.
  Brush is explicitly rejected (its raster texture is not yet implemented).
- `DesktopLayer2Processor.swift` binds original Mac `layer2` Metal entry
  point with identical uniform layout and 5-channel curve texture. MaskCount
  and mask data are supplied rather than ignored. Neutral Layer 2 retains
  original bytes without an unnecessary GPU round-trip.
- `SpectralRenderer` keeps immutable RGBA16 native print bytes on the preview
  queue. If physical print parameters are unchanged, grade/curve/local edits
  reuse the cached print. Native print/exposure/grain/halation changes still
  call the original C++ engine.
- Existing saves decode missing `adjustments` and `masks` as neutral/empty.
  Settings snapshots and preset serialization carry Mac-compatible edits.

## Automated checks

The branch-only GitHub Actions workflow:
1. compares the copied Mac Swift source byte-for-byte, except documented
   imports/helpers, and verifies historical presets decode to neutral;
2. compiles the **original** Mac Metal kernel for the iPhoneOS 16 SDK;
3. builds the full original C++ spectral engine plus the iOS Swift app and
   checks the extra post-print metallib is in the bundle;
4. runs a conditional macOS Metal pixel-fixture executable: identity, +1 EV,
   red-curve adjustment, radial and linear mask selection, and four-zone
   colour balance. If the hosted Mac exposes no Metal GPU, it explicitly
   reports `SKIPPED_GPU_RUNTIME`, **not** a GPU test pass.

Remaining acceptance gates: verify GPU fixtures actually execute; inspect
high-resolution A15 peak memory and exports; add interactive colour-range
selection and brush rasterisation or visibly mark unsupported; compare
ProPhoto/D65 transforms and matched default/autoexposure/filter parameters
against Windows and macOS on the same image. These gates are not complete.
