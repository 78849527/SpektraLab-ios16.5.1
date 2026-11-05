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
   Source verification confirms the macOS frontend *also* sends
   `product_defaults=true` and a 40-CC filter scale
   (`FilmParams.filterShiftCC`), matching iOS; these two fields were not
   divergences. The desktop "Print Brightness" slider is in stops and sends
   `print_exposure = 2^(-EV)`; iOS now shows the same EV interpretation
   while retaining the historic serialized enlarger exposure ratio. Pre-film
   softening is an iOS-only optional stage and must be disabled for exact
   source parity. Full baseline output equivalence is still unproven.
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
  **linear, radial, luminance and colour**; the iOS colour picker converts
  sRGB user selections to native ROMM/ProPhoto channel values. Sampling
  colours *directly* from the photo is not implemented yet.
  Brush is explicitly rejected (its raster texture is not yet implemented).
- `DesktopLayer2Processor.swift` binds original Mac `layer2` Metal entry
  point with identical uniform layout and 5-channel curve texture. MaskCount
  and mask data are supplied rather than ignored. Neutral Layer 2 retains
  original bytes without an unnecessary GPU round-trip.
- `SpectralRenderer` keeps immutable RGBA16 native print bytes on the preview
  queue. If physical print parameters are unchanged, grade/curve/local edits
  reuse the cached print. Native print/exposure/grain/halation changes still
  call the original C++ engine.
- Same desktop-to-wire print brightness mapping: `print_exposure=2^(-EV)`.
  The UI exposes EV; original direct-ratio presets remain compatible.
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

## Build 21 (0.14.1 beta 2): memory-bounded export and device rollout

- Keep prior Build 20 unchanged. Build 21 has a distinct bundle identifier,
  allowing Build 19, Build 20 and Build 21 to coexist for testing.
- Full-size graded **JPEG** goes from the original Layer2 output Metal
  texture directly into CIImage(mtlTexture:options:) with ROMM colour
  tagging and a Metal-device Core Image context. It avoids the redundant
  8-bytes/pixel GPU-to-CPU readback and CGImage allocation (48MB at 6MP).
- The initial GPU-direct PNG candidate, and its fallback through
  Core Image's PNG writer, both produced transparent-black output in the
  macOS Metal fixtures. Both unsafe PNG writer paths have been rejected.
  PNG now uses the 16-bit CGImage/CPU readback, then Core Graphics performs
  explicit ROMM→sRGB conversion into an opaque 8-bit bitmap and **ImageIO**
  writes the PNG. This requires an extra CPU buffer, so PNG does not enjoy
  the JPEG memory improvement; its pixels and alpha must pass fixture tests.
- Preview still uses the proven readback path; native C++ optical-film
  simulation and original desktop Metal shader are unchanged.
- Build21 tests must decode both GPU-JPEG and CPU-safe-PNG, verify
  nontransparent output and require close matching sRGB center samples.
- The 12.5MP post-print export tier remains disabled pending A15 memory
  validation. Do not interpret a Mac-runner pass as iPhone stability.
- Test 6MP JPEG and PNG with global grade, RGB curves and radial mask,
  then try five repeated exports. Compare results with Build20.
