import SwiftUI

/// Build 24 / Scheme A: a local-editing photo surface with a fixed viewport.
/// Images produced by live grade/mask updates replace pixels only; there is
/// no UIScrollView or zoom state to recompute when a slider moves.
///
/// Exactly one fittedRect is passed to the photo and its mask handles.
/// Ordinary editing still uses InlineZoomPreview, including pinch and loupe.
struct LocalMaskCanvas: View {
    let image: UIImage
    @Binding var masks: [EditMask]
    @Binding var selectedID: UUID?

    var body: some View {
        GeometryReader { viewport in
            let photoRect = MaskPhotoGeometry.fittedRect(
                image: image.size, viewport: viewport.size
            )
            ZStack(alignment: .topLeading) {
                Color.black
                if !photoRect.isEmpty {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: photoRect.width, height: photoRect.height)
                        .position(x: photoRect.midX, y: photoRect.midY)
                        .allowsHitTesting(false)

                    InlineMaskOverlay(
                        masks: $masks,
                        selectedID: $selectedID,
                        photoRect: photoRect
                    )
                    .frame(width: viewport.size.width, height: viewport.size.height)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .clipped()
        }
        .accessibilityIdentifier("LocalMaskCanvas")
    }
}
