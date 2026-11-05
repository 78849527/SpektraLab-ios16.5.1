# iOS ↔ desktop Layer 1 / Layer 2 parity contract

**Status:** feature-branch groundwork. This document and the Swift math
models do **not** imply that tone curves, colour grading, or masks are
already visible or applied in the iOS editor. The shipping v0.13.0 renderer
continues to use the original C++/Metal engine, without the desktop Layer 2
post-print GPU pass.

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
