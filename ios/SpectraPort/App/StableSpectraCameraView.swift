import AVFoundation
import SwiftUI
import UIKit

/// Reliable JPEG capture path backed by Apple's own UIImagePickerController,
/// rather than creating a second custom AVFoundation capture graph next to
/// the spectral Metal engine. No photo-library read permission is needed.
/// Camera format is JPEG for this path. RAW/ProRAW remains a separate
/// opt-in experimental mode until device diagnostics verify its stability.
@MainActor
final class StableCameraBridge: ObservableObject {
    weak var picker: UIImagePickerController?
    @Published var busy = false

    func shutter() {
        guard let picker, !busy else { return }
        busy = true
        picker.takePicture()
    }
}

private struct StableSystemCameraController: UIViewControllerRepresentable {
    @ObservedObject var bridge: StableCameraBridge
    let onResult: (Result<CapturedCameraPhoto, Error>) -> Void

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        let parent: StableSystemCameraController
        init(_ parent: StableSystemCameraController) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.bridge.busy = false
            guard let image = info[.originalImage] as? UIImage,
                  let jpeg = image.jpegData(compressionQuality: 0.95) else {
                parent.onResult(.failure(PortError.message("系统相机没有生成照片")))
                return
            }
            parent.onResult(.success(CapturedCameraPhoto(
                processedData: jpeg, rawDNGURL: nil, modeLabel: "JPEG · 系统相机"
            )))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.bridge.busy = false
            parent.onResult(.failure(PortError.message("用户取消拍摄")))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.cameraDevice = .rear
        picker.mediaTypes = ["public.image"]
        picker.showsCameraControls = false
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        bridge.picker = picker
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    static func dismantleUIViewController(_ picker: UIImagePickerController,
                                          coordinator: Coordinator) {
        // Avoid keeping UIImagePickerController's capture graph alive after
        // returning to the Metal editor.
        picker.delegate = nil
        coordinator.parent.bridge.picker = nil
    }
}

struct StableSpectraCameraView: View {
    let onCapture: (CapturedCameraPhoto) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var bridge = StableCameraBridge()
    @State private var status = "JPEG · iPhone 本机相机"
    @State private var advanced = false

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cameraAvailable {
                StableSystemCameraController(bridge: bridge) { result in
                    switch result {
                    case let .success(photo):
                        onCapture(photo)
                    case let .failure(error):
                        status = error.localizedDescription
                    }
                }
                .ignoresSafeArea()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera.slash").font(.system(size: 45))
                    Text("当前设备无法使用系统相机")
                }
                .foregroundStyle(.white)
            }
            VStack(spacing: 0) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    Spacer()
                    Text("SPECTRAPORT CAMERA")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                    Spacer()
                    Button {
                        advanced = true
                    } label: {
                        Image(systemName: "camera.filters")
                            .font(.system(size: 18))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("进入 RAW 专业测试相机")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .background(.black.opacity(0.74))

                Spacer()

                VStack(spacing: 15) {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(DarkroomStyle.accent)
                            .font(.system(size: 9))
                        Text("JPEG · 稳定模式")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("RAW / ProRAW 测试") {
                            advanced = true
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DarkroomStyle.accent)
                    }
                    .padding(.horizontal, 20)

                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(DarkroomStyle.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        bridge.shutter()
                    } label: {
                        Circle()
                            .fill(.white)
                            .frame(width: 72, height: 72)
                            .overlay(
                                Circle().stroke(DarkroomStyle.accent, lineWidth: 4)
                                    .padding(5)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!cameraAvailable || bridge.busy)
                    .accessibilityLabel("拍摄 JPEG 照片")
                }
                .padding(.top, 13)
                .padding(.bottom, 22)
                .background(DarkroomStyle.background)
            }
        }
        .fullScreenCover(isPresented: $advanced) {
            SpectraCameraView { photo in
                advanced = false
                onCapture(photo)
            }
        }
        .preferredColorScheme(.dark)
    }
}
