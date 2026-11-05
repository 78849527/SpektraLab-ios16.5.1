import Foundation
import Photos

/// PhotoKit's add-only authorization is sufficient: the application
/// never enumerates the user's library to save a processed image.
/// All writes happen on device with the already generated JPEG/PNG file.
enum PhotoLibrarySaver {
    static func requestAddPermission(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        func finish(_ status: PHAuthorizationStatus) {
            DispatchQueue.main.async {
                switch status {
                case .authorized, .limited:
                    completion(.success(()))
                case .denied, .restricted:
                    completion(.failure(PortError.message(
                        "相册写入权限被关闭，请在 iPhone「设置 → SpectraPort → 照片」允许添加照片"
                    )))
                case .notDetermined:
                    completion(.failure(PortError.message("尚未获得照片写入权限")))
                @unknown default:
                    completion(.failure(PortError.message("未知相册权限状态")))
                }
            }
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: finish)
        } else {
            finish(status)
        }
    }

    static func saveGeneratedFile(
        _ url: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            DispatchQueue.main.async {
                completion(.failure(PortError.message("导出文件不存在，请重新导出")))
            }
            return
        }
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false // retain it for the share button
            request.addResource(with: .photo, fileURL: url, options: options)
        }, completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(
                        error ?? PortError.message("系统相册写入失败")
                    ))
                }
            }
        })
    }
}
