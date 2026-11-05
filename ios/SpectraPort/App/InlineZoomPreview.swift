import SwiftUI
import UIKit

/// Uses the existing native UIScrollView photo loupe inside the editor.
/// While pinching a 1440px preview, asks the owner for a separately rendered
/// full-tier (max 12.5MP) image; switching to the high-res file preserves
/// approximately the same centre and relative zoom.
struct InlineZoomPreview: UIViewRepresentable {
    let preview: UIImage
    let highResolutionURL: URL?
    let onNeedsHighResolution: () -> Void

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scroll: DetailImageScrollView?
        var loadedID: String?
        var requestedForID: String?
        var highResolutionReady = false
        var onNeedsHighResolution: (() -> Void)?
        var updatingProgrammatically = false

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? DetailImageScrollView)?.picture
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let scroll = scrollView as? DetailImageScrollView else { return }
            scroll.centerImage()
            guard !updatingProgrammatically,
                  scroll.isZooming,
                  !highResolutionReady,
                  let id = loadedID,
                  requestedForID != id,
                  scroll.zoomScale > scroll.minimumZoomScale * 1.25 else { return }
            requestedForID = id
            onNeedsHighResolution?()
        }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scroll else { return }
            if scroll.zoomScale > scroll.minimumZoomScale * 1.5 {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
                return
            }
            if !highResolutionReady, let id = loadedID, requestedForID != id {
                requestedForID = id
                onNeedsHighResolution?()
            }
            let desired = min(scroll.maximumZoomScale,
                              max(1.0, scroll.minimumZoomScale * 3.0))
            let centre = recognizer.location(in: scroll.picture)
            let region = CGSize(width: scroll.bounds.width / desired,
                                height: scroll.bounds.height / desired)
            scroll.zoom(to: CGRect(
                x: centre.x - region.width / 2,
                y: centre.y - region.height / 2,
                width: region.width, height: region.height
            ), animated: true)
        }

        func install(image: UIImage, in scroll: DetailImageScrollView,
                     identifier: String, highRes: Bool) {
            updatingProgrammatically = true
            let hadImage = scroll.picture.image != nil
            let oldFit = max(0.0001, scroll.minimumZoomScale)
            let oldZoomFactor = hadImage ? scroll.zoomScale / oldFit : 1.0
            let oldContent = scroll.contentSize
            let normalizedX = hadImage && oldContent.width > 0 ?
                max(0, min(1, (scroll.contentOffset.x + scroll.bounds.width / 2) / oldContent.width)) : 0.5
            let normalizedY = hadImage && oldContent.height > 0 ?
                max(0, min(1, (scroll.contentOffset.y + scroll.bounds.height / 2) / oldContent.height)) : 0.5

            loadedID = identifier
            highResolutionReady = highRes
            // Keep a failed auto-upgrade from triggering repeatedly until
            // another deliberate zoom gesture or a new source image.
            if highRes { requestedForID = identifier }
            scroll.setImage(image)
            scroll.layoutIfNeeded()
            if hadImage, oldZoomFactor > 1.05 {
                let desired = max(scroll.minimumZoomScale,
                                  min(scroll.maximumZoomScale,
                                      scroll.minimumZoomScale * oldZoomFactor))
                let region = CGSize(
                    width: scroll.bounds.width / desired,
                    height: scroll.bounds.height / desired
                )
                let center = CGPoint(x: image.size.width * normalizedX,
                                     y: image.size.height * normalizedY)
                scroll.zoom(to: CGRect(
                    x: center.x - region.width / 2,
                    y: center.y - region.height / 2,
                    width: region.width, height: region.height
                ), animated: false)
            }
            updatingProgrammatically = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> DetailImageScrollView {
        let scroll = DetailImageScrollView()
        scroll.delegate = context.coordinator
        context.coordinator.scroll = scroll
        let gesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.doubleTap(_:))
        )
        gesture.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(gesture)
        updateUIView(scroll, context: context)
        return scroll
    }

    func updateUIView(_ uiView: DetailImageScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onNeedsHighResolution = onNeedsHighResolution
        let identifier = highResolutionURL?.path ?? "preview:\(ObjectIdentifier(preview))"
        guard coordinator.loadedID != identifier else { return }
        if let url = highResolutionURL,
           let highRes = UIImage(contentsOfFile: url.path) {
            coordinator.install(image: highRes, in: uiView,
                                identifier: identifier, highRes: true)
        } else {
            coordinator.install(image: preview, in: uiView,
                                identifier: identifier, highRes: false)
        }
    }
}
