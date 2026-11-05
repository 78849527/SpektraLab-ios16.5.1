# SpectraPort — native iOS 16.5.1 port of original SpektraLab

**Unofficial source port**, not endorsed by SpektraLab. Preserves the original
C++20, Metal shaders, spectral material model, measured profiles and C ABI.

## Current iOS build: v0.9.1 / Build 12

- Minimum iOS 16.0, target validation iOS 16.5.1 and Apple A15 GPU.
- Metal engine real preview rendering and photo import verified on one A15 device by user at v0.2.1.
- Film catalogue is read from the original packaged \`engine/profiles/*.json\`, including
  measured colour negative still and cine stocks (no fake LUT substitutes).
- Paper catalogue reads original color photo-paper profiles.
- UI controls send **real engine schema parameters** in the original
  \`spk_open\` delta: film_stock, print_stock, exposure_compensation_ev,
  grain_amount, halation_amount, print_exposure, m_filter_shift, y_filter_shift.
- Film choice selects its preferred print paper if available. Paper may be
  overridden manually. Parameters are rendered only on **Apply** to avoid
  overloading an older iPhone with multiple in-flight sessions.
- Preserves diagnostic homepage, editor back button and copyable diagnostics;
  adds film, paper, parameters and measured engine render time.
- Limits interactive preview to 1440px long edge.
- Original C++/Metal engine and source/negative buffers now persist between Apply actions.
  The engine receives only changed parameter fields via spk_set_params, and uses
  spk_reprint to reuse negatives for print-only changes.
- Preview-only JPEG and PNG share/saving via the iOS share sheet, explicitly
  converted from original ProPhoto RGB engine output to sRGB.
- Original full-tier export is now available at two explicit size ceilings:
  6 MP (safer) or 12.5 MP (higher memory), after metadata preflight.
  Images above the selected ceiling are *downsampled* and reported as such;
  never claim the output equals the full source resolution when it doesn't.
- Full export drops native live session caches and creates a new high-res session,
  calls `spk_render(..., "full")` with original film and paper profiles,
  uses striped engine execution, and outputs sRGB JPEG/PNG directly from
  borrowed RGBA16 storage. The preview UIImage remains on screen.
- Export stage messages indicate real workflow phases, not fabricated percentages.
- Saves up to 30 named original film/paper/slider presets in on-device UserDefaults;
  tracks the six most recently used film-paper pairs locally without cloud storage.
- Last-export metadata includes output file format and actual byte size. The
  current editing session can re-share its most recent file without re-rendering.
- iOS 16 darkroom UI: horizontal swipeable film cards (filter by brand or cine),
  dropdown list for all film stocks and measured papers, expandable parameter
  sections, precise slider +/- controls, and persistent bottom Apply action.
- The original C++20 and Metal spectral code, session cache, preset storage,
  export file sharing, and 6MP/12.5MP full-tier flow are unchanged.
- v0.8.0: editor has always-visible top navigation tabs for Film / Paper /
  Adjust / Presets / Export, eliminating long vertical page scrolling.
  The Adjust tab keeps the image visible above focused Shoot/Print controls.
- Real engine-computed live preview uses 240 ms debounce and a single in-flight
  session render. Never queues intermediate slider values: the latest values
  win, stale renders do not replace the preview. Manual immediate refresh and
  a realtime on/off switch remain available.
- Not a 60fps shader overlay: normal ~200-300 ms original GPU film render is
  performed after a gesture pauses, with the original negative caching.
- v0.8.1 effect verification: the iOS app now passes the original engine's
  `product_defaults=true` at `spk_open`, disabling print auto-compensation
  so camera exposure has a visible effect. It also sets the native
  `filter_shift_scale=40` to make M/Y slider units meaningful (previously
  only 1 CC per unit, below obvious visual thresholds). This changes the
  rendered look versus earlier iOS versions; stock profiles and C++ algorithms
  are unchanged.
- The app reads C++ parameters with `spk_get_params` before accepting a
  render and checks all six slider values, two stock IDs, and filter scale.
  The preview can switch between previous and current film render, showing
  sample mean RGB pixel change over an 80x80 sRGB sample. This is diagnostic,
  not perceptual Delta E or a quality score.
- v0.9.0 local detail inspection: explicitly re-renders the current photo
  at the original engine's full tier, with a 12.5MP A15 memory ceiling,
  using the same exact film/paper parameters. Opens a UIKit-powered local
  viewer with pinch zoom, pan, double-tap-to-zoom. This is not an enlarged
  1440px preview; >12.5MP source photos are downsampled and labeled.
  The detailed image is produced on demand, not continuously at 12.5MP.
- Halation correction: the engine's halation_amount is physically an area
  multiplier of back-reflection, not a generic halo-brightness knob. At zero,
  the iOS app now also sets halation_active=false, disabling both the base
  reflections and scattering. C++ parameter readback verifies the switch.
  On ordinary scenes, halation may be hard to see even with a positive setting;
  inspect high-contrast bright lamp edges rather than global RGB difference.
- All photo processing, measured profiles, Metal compute and user presets are
  local and offline. Download/update and possibly iCloud-backed Photos assets
  may require connectivity; the app itself has no photo upload API.
- v0.9.1: photo paper selection mirrors film stock selection, with swipeable
  horizontally scrolling cards, Kodak/Fujifilm category filters and a complete
  dropdown fallback; source data remains measured original paper JSON.
- All +/- parameter buttons use >=44pt hit targets, explicit step boundaries,
  and integer-step arithmetic (avoids rounding drift for 0.05 M/Y and print
  exposure adjustments). The controls share the existing live engine bindings.
- Continuous realtime preview, RAW-specialized decode, high-res output above
  12.5 MP, advanced peak-memory profiling, and all profile/paper parity remain
  future work. Some film/paper
  combinations may have model limitations; report any error using Copy Status.

## Building and downloading

Build workflow: \`.github/workflows/ios16.yml\`; on branch \`port/ios16-native-engine\`
it uses iPhoneOS SDK, builds the upstream static engine and MSL kernels, and
generates the unsigned iPhoneOS IPA. A successful build publishes an **unofficial
GitHub prerelease** with a direct publicly accessible IPA asset.

Unsigned apps require user-side signing. CI success is not proof of iOS 16.5.1
runtime or every selected profile; on-device verification is still required.

## Legal

Application/engine GPL-3.0-or-later; measured profile and print LUT
data CC BY-SA 4.0. Keep upstream notices and attribution. SpektraLab name and
icon belong to their holders; this app uses the distinct SpectraPort name.
