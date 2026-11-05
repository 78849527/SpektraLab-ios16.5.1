# SpectraPort — native iOS 16.5.1 port of original SpektraLab

**Unofficial source port**, not endorsed by SpektraLab. Preserves the original
C++20, Metal shaders, spectral material model, measured profiles and C ABI.

## Current iOS build: v0.7.0 / Build 8

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
