import AVFoundation
import SwiftUI
import UIKit

enum SpectraCaptureMode: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case heif = "HEIF"
    case bayerRAW = "RAW (DNG)"
    case appleProRAW = "Apple ProRAW"

    var id: String { rawValue }
}

struct CapturedCameraPhoto {
    let processedData: Data?
    let rawDNGURL: URL?
    let modeLabel: String
}

final class SpectraCameraController: NSObject, ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var capturing = false
    @Published private(set) var status = "准备本地相机…"
    @Published private(set) var modes: [SpectraCaptureMode] = [.jpeg]

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.twogou.spectraport.camera")
    private let output = AVCapturePhotoOutput()
    private var configured = false
    private var rawFormats: [SpectraCaptureMode: OSType] = [:]
    private var activeProcessor: SpectraCaptureProcessor?
    var onCapture: ((CapturedCameraPhoto) -> Void)?

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startConfiguredSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                if allowed {
                    self?.startConfiguredSession()
                } else {
                    DispatchQueue.main.async {
                        self?.status = "未获得相机权限，可在系统设置里允许相机访问"
                    }
                }
            }
        case .denied, .restricted:
            status = "相机权限不可用，请到「设置 → SpectraPort → 相机」开启"
        @unknown default:
            status = "未知相机授权状态"
        }
    }

    private func startConfiguredSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.configured { try self.configureSession() }
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async {
                    self.ready = self.session.isRunning
                    self.status = self.session.isRunning
                        ? "设备支持的拍摄格式已检测，可直接拍摄并修图"
                        : "相机会话未能启动"
                }
            } catch {
                DispatchQueue.main.async { self.status = "无法启动相机：" + error.localizedDescription }
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw PortError.message("找不到后置广角相机")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw PortError.message("无法连接后置相机")
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            throw PortError.message("无法连接拍照输出")
        }
        session.addOutput(output)

        // Apple recommends enabling before session.startRunning().
        if output.isAppleProRAWSupported {
            output.isAppleProRAWEnabled = true
        }

        var detected: [SpectraCaptureMode] = [.jpeg]
        if output.availablePhotoCodecTypes.contains(.hevc) {
            detected.append(.heif)
        }
        for format in output.availableRawPhotoPixelFormatTypes {
            if AVCapturePhotoOutput.isBayerRAWPixelFormat(format),
               rawFormats[.bayerRAW] == nil {
                rawFormats[.bayerRAW] = format
                detected.append(.bayerRAW)
            }
            if AVCapturePhotoOutput.isAppleProRAWPixelFormat(format),
               rawFormats[.appleProRAW] == nil {
                rawFormats[.appleProRAW] = format
                detected.append(.appleProRAW)
            }
        }
        configured = true
        DispatchQueue.main.async { self.modes = detected }
    }

    func takePhoto(_ mode: SpectraCaptureMode) {
        guard ready, !capturing else { return }
        capturing = true
        status = mode == .appleProRAW || mode == .bayerRAW
            ? "正在拍摄 RAW＋JPEG…"
            : "正在拍摄 " + mode.rawValue + "…"
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let codec: AVVideoCodecType = mode == .heif ? .hevc : .jpeg
            let requestedMode: SpectraCaptureMode
            let settings: AVCapturePhotoSettings
            if let raw = self.rawFormats[mode] {
                requestedMode = mode
                settings = AVCapturePhotoSettings(
                    rawPixelFormatType: raw,
                    processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg]
                )
            } else {
                requestedMode = mode == .heif && self.output.availablePhotoCodecTypes.contains(.hevc)
                    ? .heif : .jpeg
                settings = AVCapturePhotoSettings(
                    format: [AVVideoCodecKey: requestedMode == .heif ? codec : AVVideoCodecType.jpeg]
                )
            }
            settings.photoQualityPrioritization = .quality
            if let conn = self.output.connection(with: .video),
               conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            let delegate = SpectraCaptureProcessor(mode: requestedMode) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.capturing = false
                    self.activeProcessor = nil
                    switch result {
                    case let .success(photo):
                        self.status = photo.modeLabel + " · 拍摄完成"
                        self.onCapture?(photo)
                    case let .failure(error):
                        self.status = "拍摄失败：" + error.localizedDescription
                    }
                }
            }
            self.activeProcessor = delegate
            self.output.capturePhoto(with: settings, delegate: delegate)
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.ready = false }
        }
    }
}

private final class SpectraCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let mode: SpectraCaptureMode
    private let complete: (Result<CapturedCameraPhoto, Error>) -> Void
    private var processed: Data?
    private var rawURL: URL?
    private var captureError: Error?

    init(mode: SpectraCaptureMode,
         completion: @escaping (Result<CapturedCameraPhoto, Error>) -> Void) {
        self.mode = mode
        self.complete = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error { captureError = error; return }
        guard let content = photo.fileDataRepresentation() else {
            captureError = PortError.message("相机没有返回有效照片文件")
            return
        }
        if photo.isRawPhoto {
            do {
                let support = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                )[0].appendingPathComponent("CameraRAW", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: support, withIntermediateDirectories: true
                )
                let file = support.appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("dng")
                try content.write(to: file, options: .atomic)
                rawURL = file
            } catch {
                captureError = PortError.message("无法保留 RAW 原片：" + error.localizedDescription)
            }
        } else {
            processed = content
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if let error { complete(.failure(error)); return }
        if let captureError { complete(.failure(captureError)); return }
        guard rawURL != nil || processed != nil else {
            complete(.failure(PortError.message("相机没有生成照片")))
            return
        }
        complete(.success(CapturedCameraPhoto(
            processedData: processed,
            rawDNGURL: rawURL,
            modeLabel: mode.rawValue
        )))
    }
}

private final class CameraPreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

private struct SpectraCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = CameraPreviewSurface()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct SpectraCameraView: View {
    let onCapture: (CapturedCameraPhoto) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = SpectraCameraController()
    @State private var selectedMode: SpectraCaptureMode = .jpeg

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button {
                        camera.stop()
                        dismiss()
                    } label: {
                        Label("关闭", systemImage: "xmark")
                    }
                    Spacer()
                    Text("SPECTRAPORT CAMERA")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                    Spacer()
                }
                .padding(15)
                .foregroundStyle(.white)

                SpectraCameraPreview(session: camera.session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                VStack(spacing: 16) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(camera.modes) { mode in
                                Button(mode.rawValue) { selectedMode = mode }
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(selectedMode == mode ? .black : .white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(
                                        selectedMode == mode
                                            ? DarkroomStyle.accent : DarkroomStyle.raised,
                                        in: Capsule()
                                    )
                            }
                        }
                        .padding(.horizontal, 15)
                    }
                    Text(camera.status)
                        .font(.system(size: 11))
                        .foregroundStyle(DarkroomStyle.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                    Button {
                        camera.takePhoto(selectedMode)
                    } label: {
                        Circle()
                            .fill(.white)
                            .frame(width: 72, height: 72)
                            .overlay(
                                Circle().stroke(DarkroomStyle.accent, lineWidth: 4)
                                    .padding(5)
                            )
                    }
                    .disabled(!camera.ready || camera.capturing)
                    .opacity(camera.ready && !camera.capturing ? 1 : 0.45)
                    .accessibilityLabel("拍摄 " + selectedMode.rawValue)
                }
                .padding(.vertical, 18)
                .background(DarkroomStyle.background)
            }
        }
        .onAppear {
            camera.onCapture = onCapture
            camera.start()
        }
        .onDisappear { camera.stop() }
        .preferredColorScheme(.dark)
    }
}
