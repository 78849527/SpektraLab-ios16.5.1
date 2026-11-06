import SwiftUI

/// The photo is shown *before* the editable crop, with rotation/straighten
/// already applied. A crop border and its draggable corners share one fitted
/// rect, avoiding a separate UIImage scroll/zoom state.
struct PhotoCropCanvas: View {
    let image: UIImage
    @Binding var geometry: PhotoGeometry

    @State private var movingFrom: CGRect?
    @State private var resizingFrom: CGRect?

    var body: some View {
        GeometryReader { viewport in
            let photo = MaskPhotoGeometry.fittedRect(
                image: image.size, viewport: viewport.size)
            let r = PhotoGeometry.bounded(geometry.crop)
            // Use the identical aspect-fit rectangle and normalized-photo
            // projection shared with the local mask overlay.
            let selection = MaskPhotoGeometry.cropRect(r, in: photo)

            ZStack(alignment: .topLeading) {
                Color.black
                if photo.width > 0 && photo.height > 0 {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: photo.width, height: photo.height)
                        .position(x: photo.midX, y: photo.midY)
                        .allowsHitTesting(false)

                    shade(CGRect(x: photo.minX, y: photo.minY,
                                 width: photo.width, height: max(0, selection.minY - photo.minY)))
                    shade(CGRect(x: photo.minX, y: selection.maxY,
                                 width: photo.width, height: max(0, photo.maxY - selection.maxY)))
                    shade(CGRect(x: photo.minX, y: selection.minY,
                                 width: max(0, selection.minX - photo.minX), height: selection.height))
                    shade(CGRect(x: selection.maxX, y: selection.minY,
                                 width: max(0, photo.maxX - selection.maxX), height: selection.height))

                    Path { path in
                        for step in [1.0 / 3, 2.0 / 3] {
                            let x = selection.minX + selection.width * step
                            let y = selection.minY + selection.height * step
                            path.move(to: CGPoint(x: x, y: selection.minY))
                            path.addLine(to: CGPoint(x: x, y: selection.maxY))
                            path.move(to: CGPoint(x: selection.minX, y: y))
                            path.addLine(to: CGPoint(x: selection.maxX, y: y))
                        }
                    }
                    .stroke(.white.opacity(0.34), lineWidth: 0.7)
                    .allowsHitTesting(false)

                    Rectangle().fill(.white.opacity(0.001))
                        .frame(width: selection.width, height: selection.height)
                        .contentShape(Rectangle())
                        .position(x: selection.midX, y: selection.midY)
                        .gesture(moveGesture(photo: photo))

                    Rectangle().stroke(.white, lineWidth: 1.3)
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY)
                        .allowsHitTesting(false)

                    ForEach(CropCorner.allCases, id: \.self) { corner in
                        let p = cornerPoint(corner, in: selection)
                        Circle()
                            .fill(DarkroomStyle.accent)
                            .frame(width: 11, height: 11)
                            .frame(width: 38, height: 38)
                            .contentShape(Rectangle())
                            .position(p)
                            .gesture(cornerGesture(corner, photo: photo))
                            .accessibilityLabel("拖动裁剪角")
                    }
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .coordinateSpace(name: "PhotoCropCanvas")
            .clipped()
        }
        .accessibilityIdentifier("PhotoCropCanvas")
    }

    private func shade(_ rect: CGRect) -> some View {
        Rectangle()
            .fill(.black.opacity(0.52))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    private func cornerPoint(_ corner: CropCorner, in rect: CGRect) -> CGPoint {
        CGPoint(x: corner.left ? rect.minX : rect.maxX,
                y: corner.top ? rect.minY : rect.maxY)
    }

    private func moveGesture(photo: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("PhotoCropCanvas"))
            .onChanged { change in
                if movingFrom == nil { movingFrom = geometry.crop }
                guard let start = movingFrom, photo.width > 0, photo.height > 0 else { return }
                geometry = geometry.moved(by: CGSize(
                    width: change.translation.width / photo.width,
                    height: change.translation.height / photo.height), from: start)
            }
            .onEnded { _ in movingFrom = nil }
    }

    private func cornerGesture(_ corner: CropCorner, photo: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("PhotoCropCanvas"))
            .onChanged { change in
                if resizingFrom == nil { resizingFrom = geometry.crop }
                guard let start = resizingFrom, photo.width > 0, photo.height > 0 else { return }
                let point = MaskPhotoGeometry.normalized(change.location, in: photo)
                geometry = geometry.resized(corner: corner, to: point,
                                             from: start, imageSize: image.size)
            }
            .onEnded { _ in resizingFrom = nil }
    }
}

struct PhotoGeometryControls: View {
    @Binding var geometry: PhotoGeometry
    let imageSize: CGSize
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("裁剪与几何")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DarkroomStyle.primary)
                Spacer()
                Menu {
                    ForEach(CropAspectPreset.allCases) { preset in
                        Button {
                            geometry = geometry.selectingAspect(
                                preset, imageSize: imageSize)
                        } label: {
                            if geometry.aspect == preset {
                                Label(preset.rawValue, systemImage: "checkmark")
                            } else {
                                Text(preset.rawValue)
                            }
                        }
                    }
                } label: {
                    Label(geometry.aspect.rawValue, systemImage: "aspectratio")
                }
                .disabled(disabled)
            }
            HStack(spacing: 8) {
                action("左转", icon: "rotate.left") {
                    geometry = geometry.turned(-1)
                }
                action("右转", icon: "rotate.right") {
                    geometry = geometry.turned(1)
                }
                action("左右翻转", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    var next = geometry
                    next.flipHorizontal.toggle()
                    geometry = next
                }
                action("上下翻转", icon: "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                    var next = geometry
                    next.flipVertical.toggle()
                    geometry = next
                }
            }
            DarkroomControlRow(
                label: "水平拉直",
                value: Binding(
                    get: { geometry.straightenDegrees },
                    set: { value in
                        var next = geometry
                        next.straightenDegrees = value
                        geometry = next
                    }),
                range: -15...15, step: 0.1, suffix: "°", disabled: disabled
            )
            HStack {
                Text("拖动照片内的裁剪框，或拖动四角改变范围。旋转会重置裁剪框。")
                    .font(.system(size: 10))
                    .foregroundStyle(DarkroomStyle.secondary)
                Spacer()
                Button("重置") { geometry = .identity }
                    .font(.system(size: 11))
                    .disabled(disabled || geometry.isIdentity)
            }
        }
    }

    private func action(_ title: String, icon: String,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon)
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .tint(DarkroomStyle.accent)
        .disabled(disabled)
    }
}
