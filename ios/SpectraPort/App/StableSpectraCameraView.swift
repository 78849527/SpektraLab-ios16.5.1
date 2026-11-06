import AVFoundation
import SwiftUI
import UIKit

/// Photo payload handed back to the editor after a custom camera capture.
struct CapturedCameraPhoto {
    let processedData: Data
    let modeLabel: String
}

private enum CameraFrameGuide: String, CaseIterable, Identifiable {
    case fourThree = "4:3"
    case threeTwo = "3:2"
    case square = "1:1"
    var id: String { rawValue }
    var portraitAspectRatio: CGFloat {
        switch self {
        case .fourThree: return 3.0 / 4.0
        case .threeTwo: return 2.0 / 3.0
        case .square: return 1.0
        }
    }
}

struct StableSpectraCameraView: View {
    let onCapture: (CapturedCameraPhoto) -> Void
    let onCancel: () -> Void
    @StateObject private var camera = SpectraCaptureController()
    @State private var frameGuide: CameraFrameGuide = .fourThree
    @State private var focusMarker: CGPoint?
    @State private var focusToken = UUID()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                CameraPreviewSurface(session: camera.session) { devicePoint, viewPoint in
                    camera.focus(at: devicePoint)
                    focusToken = UUID()
                    let token = focusToken
                    withAnimation(.easeOut(duration: 0.12)) { focusMarker = viewPoint }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        guard focusToken == token else { return }
                        withAnimation(.easeOut(duration: 0.2)) { focusMarker = nil }
                    }
                }
                .ignoresSafeArea()
                CameraCompositionGuide(aspectRatio: frameGuide.portraitAspectRatio)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                if let focusMarker {
                    FocusConfirmationMark()
                        .position(focusMarker)
                        .allowsHitTesting(false)
                }
                if camera.permissionDenied {
                    permissionPrompt
                } else if !camera.isConfigured {
                    startupPrompt
                } else {
                    VStack(spacing: 0) {
                        topBar.padding(.top, max(geometry.safeAreaInsets.top, 48))
                        Spacer(minLength: 8)
                        captureControls.padding(.bottom, max(geometry.safeAreaInsets.bottom, 22))
                    }
                    .padding(.horizontal, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .ignoresSafeArea()
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .alert(
            "相机提示",
            isPresented: Binding(
                get: { camera.errorMessage != nil },
                set: { if !$0 { camera.clearError() } }
            )
        ) {
            Button("知道了") { camera.clearError() }
        } message: {
            Text(camera.errorMessage ?? "")
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.32), in: Circle())
            }
            .accessibilityLabel("关闭相机")
            Spacer()
            VStack(spacing: 2) {
                Text("SPEKTRA")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(.white)
                Text("暗房相机")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button { camera.toggleFlash() } label: {
                Image(systemName: camera.flashEnabled ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(camera.flashEnabled ? DarkroomStyle.accent : .white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.32), in: Circle())
            }
            .disabled(!camera.hasFlash)
            .accessibilityLabel(camera.flashEnabled ? "关闭闪光灯" : "开启闪光灯")
        }
    }

    private var captureControls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                Text("EV")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                Slider(value: $camera.exposureBias, in: -2...2, step: 0.1)
                    .tint(DarkroomStyle.accent)
                    .onChange(of: camera.exposureBias) { value in camera.setExposureBias(value) }
                Text(String(format: "%+.1f", camera.exposureBias))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.42), in: Capsule())

            HStack(spacing: 18) {
                ForEach(CameraFrameGuide.allCases) { option in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { frameGuide = option }
                    } label: {
                        Text(option.rawValue)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(frameGuide == option ? .black : .white)
                            .frame(width: 52, height: 32)
                            .background(
                                frameGuide == option ? DarkroomStyle.accent : .clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(.black.opacity(0.42), in: Capsule())

            Button {
                camera.capture { result in
                    switch result {
                    case let .success(data):
                        onCapture(CapturedCameraPhoto(
                            processedData: data,
                            modeLabel: "JPEG · Spektra 暗房相机"
                        ))
                    case let .failure(error):
                        camera.showError(error.localizedDescription)
                    }
                }
            } label: {
                ZStack {
                    Circle().fill(.white.opacity(camera.isCapturing ? 0.65 : 1))
                        .frame(width: 72, height: 72)
                    Circle().stroke(.black.opacity(0.22), lineWidth: 2)
                        .frame(width: 62, height: 62)
                }
            }
            .buttonStyle(.plain)
            .disabled(!camera.isConfigured || camera.isCapturing)
            .accessibilityLabel("拍摄")
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var startupPrompt: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("正在启动暗房相机…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
            Button("取消", action: onCancel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DarkroomStyle.accent)
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 30))
                .foregroundStyle(DarkroomStyle.accent)
            Text("需要相机权限")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("请在 iPhone「设置 → SpectraPort → 相机」中允许访问，然后返回继续拍摄。")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: 280)
            Button("打开设置") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DarkroomStyle.accent)
            Button("取消", action: onCancel)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.78))
        }
        .padding(24)
        .background(DarkroomStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .padding(28)
    }
}

private struct CameraCompositionGuide: View {
    let aspectRatio: CGFloat
    var body: some View {
        GeometryReader { proxy in
            let guideHeight = min(proxy.size.height, proxy.size.width / aspectRatio)
            let guideWidth = guideHeight * aspectRatio
            ZStack {
                Rectangle().stroke(.white.opacity(0.68), lineWidth: 1)
                Path { path in
                    for fraction in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
                        let x = guideWidth * fraction
                        let y = guideHeight * fraction
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: guideHeight))
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: guideWidth, y: y))
                    }
                }
                .stroke(.white.opacity(0.34), lineWidth: 0.7)
            }
            .frame(width: guideWidth, height: guideHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct FocusConfirmationMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .stroke(DarkroomStyle.accent, lineWidth: 1.5)
            .frame(width: 66, height: 66)
            .overlay(alignment: .topTrailing) {
                Circle().fill(DarkroomStyle.accent)
                    .frame(width: 6, height: 6)
                    .offset(x: 3, y: -3)
            }
    }
}

private struct CameraPreviewSurface: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocusTap: (CGPoint, CGPoint) -> Void

    func makeUIView(context: Context) -> CameraPreviewHostView {
        let view = CameraPreviewHostView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocusTap = onFocusTap
        return view
    }

    func updateUIView(_ view: CameraPreviewHostView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        if let connection = view.previewLayer.connection,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        view.onFocusTap = onFocusTap
    }
}

private final class CameraPreviewHostView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    var onFocusTap: ((CGPoint, CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
        addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleFocusTap(_:)))
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }

    @objc private func handleFocusTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        onFocusTap?(devicePoint, point)
    }
}

private final class SpectraCaptureController: NSObject, ObservableObject,
                                               AVCapturePhotoCaptureDelegate {
    @Published private(set) var isConfigured = false
    @Published private(set) var isCapturing = false
    @Published private(set) var hasFlash = false
    @Published var flashEnabled = false
    @Published var exposureBias = 0.0
    @Published private(set) var permissionDenied = false
    @Published private(set) var errorMessage: String?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.twogou.spectraport.camera-session")
    private let photoOutput = AVCapturePhotoOutput()
    private var activeDevice: AVCaptureDevice?
    private var configured = false
    private var captureCompletion: ((Result<Data, Error>) -> Void)?

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStart()
                } else {
                    DispatchQueue.main.async { self.permissionDenied = true }
                }
            }
        case .denied, .restricted:
            permissionDenied = true
        @unknown default:
            permissionDenied = true
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func toggleFlash() {
        guard hasFlash else { return }
        flashEnabled.toggle()
    }

    func focus(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "无法设置对焦或测光：" + error.localizedDescription
                }
            }
        }
    }

    func setExposureBias(_ value: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            let bias = Float(value)
            let bounded = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.setExposureTargetBias(bounded, completionHandler: nil)
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "无法调整曝光：" + error.localizedDescription
                }
            }
        }
    }

    func capture(completion: @escaping (Result<Data, Error>) -> Void) {
        guard isConfigured, !isCapturing else { return }
        isCapturing = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = self.activeDevice, self.session.isRunning else {
                self.finishCapture(.failure(PortError.message("相机尚未准备好，请稍后重试")))
                return
            }
            let settings = AVCapturePhotoSettings()
            settings.flashMode = self.flashEnabled && device.hasFlash ? .on : .off
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            self.captureCompletion = completion
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func showError(_ message: String) { errorMessage = message }
    func clearError() { errorMessage = nil }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                var configurationStarted = false
                do {
                    self.session.beginConfiguration()
                    configurationStarted = true
                    self.session.sessionPreset = .photo
                    guard let device = AVCaptureDevice.default(
                        .builtInWideAngleCamera, for: .video, position: .back
                    ) else {
                        throw PortError.message("这台设备没有可用的后置相机")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else {
                        throw PortError.message("无法连接后置相机")
                    }
                    guard self.session.canAddOutput(self.photoOutput) else {
                        throw PortError.message("无法启动照片拍摄输出")
                    }
                    self.session.addInput(input)
                    self.session.addOutput(self.photoOutput)
                    self.photoOutput.isHighResolutionCaptureEnabled = true
                    self.activeDevice = device
                    self.session.commitConfiguration()
                    configurationStarted = false
                    self.configured = true
                    DispatchQueue.main.async {
                        self.hasFlash = device.hasFlash
                        self.isConfigured = true
                        self.exposureBias = 0
                    }
                } catch {
                    if configurationStarted { self.session.commitConfiguration() }
                    DispatchQueue.main.async {
                        self.errorMessage = "相机启动失败：" + error.localizedDescription
                    }
                    return
                }
            }
            self.session.startRunning()
        }
    }

    private func finishCapture(_ result: Result<Data, Error>) {
        let completion = captureCompletion
        captureCompletion = nil
        DispatchQueue.main.async {
            self.isCapturing = false
            completion?(result)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            finishCapture(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation(), !data.isEmpty else {
            finishCapture(.failure(PortError.message("照片数据为空，请重新拍摄")))
            return
        }
        finishCapture(.success(data))
    }
}
