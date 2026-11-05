# SpectraPort — native iOS 16.5.1 port of original SpektraLab

**Unofficial source port**, not endorsed by SpektraLab. Preserves the original
C++20, Metal shaders, spectral material model, measured profiles and C ABI.

## Current iOS build: v0.13.0 / Build 19

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
- v0.10.0: the editor's preview surface is itself a native pan/zoom
  UIScrollView. Pinch or double-tap automatically loads an on-demand engine
  full-tier 12.5MP image *in place*, keeping approximately the same viewport.
  The 1440px live preview remains the fast default. This is not a separate
  full-screen detail view, and the full-size render is not performed after
  every slider change. Each successful live render invalidates stale HD detail.
- Directly save the full-tier sRGB JPEG/PNG into the iPhone Photos app using
  PhotoKit add-only permission; no server and no need to open a share sheet.
  The export tab offers both formats; the preview has a JPEG save shortcut.
  User authorization is requested only when saving. When permission is denied,
  the app reports why instead of silently failing. It retains the export file
  for re-sharing, and never moves it when writing the Photos asset.
- v0.11.0 historical: experimental RAW capture existed briefly but was
  removed completely in v0.12.1 after on-device instability.
- Added "降低数码锐利感" (0..1) input pre-processing. Core Image subtly
  reduces excessive spatial high-frequency contrast using Gaussian low-pass
  mixed into the captured image *before* measured film and paper rendering;
  native film grain is preserved. This cannot mathematically undo iPhone ISP
  sharpening already baked into HEIF/JPEG. The same strength is used by the
  preview and full-resolution export and saved with presets. Older presets
  decode with a default of zero. No original C++ model parameters changed.
- Fixes UIKit zoom state leaking into subsequent photos, and image decoder
  overstepping the selected 6MP/12.5MP ceiling. Full-sized source pixels
  are retained when at or below the ceiling.
- v0.11.1: crash-hardening for camera launch: verify NSCameraUsageDescription
  before touching capture authorization, and bind AVCaptureVideoPreviewLayer
  to the configured capture session only when it is running. CI checks the
  *built* Info.plist for the usage key. This does not by itself prove any
  specific device's crash cause: on-device testing/crash logs remain needed.
- Photo preview has an explicit "整张" fit-to-frame button (scale + center)
  and double-tap restore, with no bouncing below minimum zoom. Camera and
  Photos-picker source changes also reset the embedded viewer.
- v0.13.0: new warm-gold dog-head home-screen AppIcon generated locally on
  the CI Mac as native 1024px and all required iPhone renditions. App now
  directly presents the editor instead of the old diagnostic landing page.
  Default cold-start destination is the stable native JPEG camera; a
  persistent "拍摄 / 编辑" startup choice is available at the top-left gear.
  Changing it affects future app launches, not the current edit. Diagnostics
  remain copyable through the top-right information action.
- The top-right share action generates a full-size original-engine JPEG (within
  chosen 6MP/12.5MP export limit) and presents the iOS system
  UIActivityViewController. The Export tab has an explicit "分享到微信 / 其他 App"
  entry and keeps preview share, PNG and add-only Photos saves. WeChat is
  visible only if installed and its sharing extension accepts the image;
  this does not use an unverified WeChat SDK or upload to a server.
- v0.12.2: the yellow Apply Adjustments action is now a fixed-position
  floating button within the photo preview (upper-right, beneath fit-to-frame).
  It appears only for unapplied edits or when automatic preview is off. The
  adjustment ScrollView no longer inserts a transient row, so sliders and
  panel scroll offset remain stable through live parameter changes.
- v0.12.1 simplifies capture: iOS owns the *entire* native
  UIImagePickerController camera screen, including framing, shutter,
  flash (when available), Cancel, Retake and Use Photo. No custom overlays,
  bottom black empty band or capture framing transform. Captured JPEG goes
  straight to the existing original spectral editor. The experimental
  custom AVFoundation camera and RAW developer were deleted from the app,
  not merely hidden. RAW/ProRAW is not available in this version.
- v0.12.0 redesigned photo-first iPhone editor: image occupies about 61.5%
  of the area below the navigation bar, the film/paper/adjustment/preset dock
  scrolls independently below, and five main entries are fixed at bottom:
  Library / Capture / Edit / Presets / More. No top selection tabs.
- Opening the native camera first releases native spectral GPU textures on
  the engine's serial queue.
- Every completed live preview resets the zoom by rebuilding UIScrollView;
  the in-preview fit button also forces a fresh view. The in-preview + / -
  actions remain distinct from pinch and double-tap zoom. The 12.5MP on-
  demand zoom/export and direct PhotoKit save are retained.
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
