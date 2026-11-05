import SwiftUI
import UIKit

/// An on-demand photo from the full-tier engine. This is a separate,
/// memory-bounded render (<=12.5MP), never an upscaled 1440px preview.
struct DetailInspection: Identifiable {
    let id = UUID()
    let result: HighResExportResult
}

final class DetailImageScrollView: UIScrollView {
    let picture = UIImageView()
    private var intrinsicPixels: CGSize = .zero
    private var needsFit = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bouncesZoom = true
        picture.contentMode = .scaleToFill
        addSubview(picture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    func setImage(_ image: UIImage) {
        intrinsicPixels = image.size
        picture.image = image
        picture.frame = CGRect(origin: .zero, size: intrinsicPixels)
        needsFit = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard intrinsicPixels.width > 0, intrinsicPixels.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let fit = min(bounds.width / intrinsicPixels.width,
                      bounds.height / intrinsicPixels.height)
        minimumZoomScale = fit
        maximumZoomScale = max(1.5, fit * 12)
        if needsFit {
            zoomScale = fit
            needsFit = false
        }
        centerImage()
    }

    func centerImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal,
                                   bottom: vertical, right: horizontal)
    }
}

struct DetailZoomView: UIViewRepresentable {
    let imageURL: URL

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var loadedURL: URL?
        weak var scroll: DetailImageScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? DetailImageScrollView)?.picture
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? DetailImageScrollView)?.centerImage()
        }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scroll else { return }
            if scroll.zoomScale > scroll.minimumZoomScale * 1.5 {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
                return
            }
            // Zoom to about 1 source pixel per logical point, bounded for
            // retina display and CPU/GPU limits. The actual image isn't resized.
            let target = min(scroll.maximumZoomScale, max(1.0, scroll.minimumZoomScale * 3))
            let centre = recognizer.location(in: scroll.picture)
            let region = CGSize(width: scroll.bounds.width / target,
                                height: scroll.bounds.height / target)
            scroll.zoom(to: CGRect(x: centre.x - region.width / 2,
                                   y: centre.y - region.height / 2,
                                   width: region.width,
                                   height: region.height), animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = DetailImageScrollView()
        scroll.delegate = context.coordinator
        context.coordinator.scroll = scroll
        let gesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.doubleTap(_:))
        )
        gesture.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(gesture)
        loadImage(into: scroll, context: context)
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        guard let scroll = uiView as? DetailImageScrollView else { return }
        if context.coordinator.loadedURL != imageURL {
            loadImage(into: scroll, context: context)
        }
    }

    private func loadImage(into scroll: DetailImageScrollView, context: Context) {
        context.coordinator.loadedURL = imageURL
        if let image = UIImage(contentsOfFile: imageURL.path) {
            scroll.setImage(image)
        }
    }
}

struct DetailInspectionView: View {
    let inspection: DetailInspection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DetailZoomView(imageURL: inspection.result.url)
                    .background(Color.black)

                VStack(spacing: 5) {
                    Text(inspection.result.summary)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center)
                    Text("双指缩放、拖动查看局部；双击放大／复位。修改参数后重新生成高清检查。")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("高清局部检查")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
