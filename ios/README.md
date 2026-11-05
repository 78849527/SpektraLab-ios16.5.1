# SpectraPort — native iOS 16.5.1 port of original SpektraLab

**Unofficial source port**, not endorsed by SpektraLab. Preserves the original
C++20, Metal shaders, spectral material model, measured profiles and C ABI.

## Current iOS build: v0.4.0 / Build 5

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
- Continuous realtime preview, RAW-specialized decode, full-resolution
  export and full film/paper parity remain future work. Some film/paper
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
