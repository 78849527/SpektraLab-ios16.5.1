import SwiftUI
import UIKit

/// Apple's complete stock photo camera: system framing, shutter, flash,
/// Retake/Use Photo and Cancel. Never constructs a custom AVCaptureSession.
struct CapturedCameraPhoto {
    let processedData: Data
    let modeLabel: String
}

struct StableSpectraCameraView: UIViewControllerRepresentable {
    let onCapture: (CapturedCameraPhoto) -> Void
    let onCancel: () -> Void

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        let onCapture: (CapturedCameraPhoto) -> Void
        let onCancel: () -> Void
        private var completed = false

        init(onCapture: @escaping (CapturedCameraPhoto) -> Void,
             onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard !completed else { return }
            completed = true
            guard let image = info[.originalImage] as? UIImage,
                  let jpeg = image.jpegData(compressionQuality: 0.96) else {
                onCancel()
                return
            }
            onCapture(CapturedCameraPhoto(
                processedData: jpeg, modeLabel: "JPEG · iOS 原生相机"
            ))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !completed else { return }
            completed = true
            onCancel()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.cameraDevice = .rear
        picker.mediaTypes = ["public.image"]
        picker.showsCameraControls = true
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        // No cameraOverlayView or geometry override: UIKit owns framing.
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController,
                                context: Context) {}
}
