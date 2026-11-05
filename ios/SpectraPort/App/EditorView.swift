import AVFoundation
import Metal
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class EditorModel: ObservableObject {
    @Published var original: UIImage?
    @Published var processed: UIImage?
    @Published var status = "请选择照片，然后调整真实的胶片／相纸参数。"
    @Published var isBusy = false     // photo transfer or full-resolution export only
    @Published var isRendering = false
    @Published var realtimeEnabled = true
    @Published var compare = false
    @Published var isDirty = false
    @Published var previousProcessed: UIImage?
    @Published var pixelChangePercent: Double?
    @Published var lastParametersVerified = false
    @Published var previewSequence = 0
    @Published var photoSelectionVersion = 0
    @Published var capturedFormat = "照片图库"
    @Published var lastElapsedMS: Double?
    @Published var exportLimit: ExportLimit = .safe
    @Published var exportPhase = ""
    @Published var lastExportInfo = "尚未进行高清导出"

    @Published var filmID = FilmCatalog.films.contains(where: { $0.id == "kodak_portra_400" })
        ? "kodak_portra_400" : (FilmCatalog.films.first?.id ?? "")
    @Published var paperID = FilmCatalog.papers.contains(where: { $0.id == "kodak_portra_endura" })
        ? "kodak_portra_endura" : (FilmCatalog.papers.first?.id ?? "")
    @Published var exposureEV = 0.0
    @Published var grainAmount = 1.0
    @Published var halationAmount = 1.0
    @Published var printExposure = 1.0
    @Published var magentaShift = 0.0
    @Published var yellowShift = 0.0
    @Published var softness = 0.0

    private var sourceData: Data?
    private var photoID = UUID()
    private var debounceTask: Task<Void, Never>?
    private var previewInFlight = false
    private var requestVersion = 0
    private var lastSuccessfulPhotoID: UUID?
    private var lastSuccessfulSettings: FilmSettings?

    var hasPhoto: Bool { sourceData != nil }
    private let renderer = SpectralRenderer()
    var onSuccessfulRender: ((FilmSettings) -> Void)?

    var currentSettings: FilmSettings { snapshot() }

    func loadLook(_ settings: FilmSettings) {
        guard !isBusy else { return }
        // Restore both stocks exactly; preserve the saved paper choice.
        filmID = settings.filmStock
        paperID = settings.printStock
        exposureEV = settings.exposureEV
        grainAmount = settings.grainAmount
        halationAmount = settings.halationAmount
        printExposure = settings.printExposure
        magentaShift = settings.magentaShift
        yellowShift = settings.yellowShift
        softness = settings.softness
        markDirty()
        status = hasPhoto ? "已载入参数，点击「应用设置」渲染" : "预设已载入，选择照片后应用"
    }

    func restoreDefaults() {
        loadLook(FilmSettings(
            filmStock: "kodak_portra_400",
            printStock: "kodak_portra_endura",
            exposureEV: 0, grainAmount: 1, halationAmount: 1,
            printExposure: 1, magentaShift: 0, yellowShift: 0,
            softness: 0
        ))
    }

    func selectPair(film: String, paper: String) {
        guard !isBusy else { return }
        filmID = film
        paperID = paper
        markDirty()
    }

    /// UI changes coalesce for 240 ms; a running Metal render is never
    /// cancelled mid-kernel or duplicated. The newest settings win.
    func markDirty() {
        guard sourceData != nil else { return }
        requestVersion += 1
        isDirty = true
        if !isBusy && realtimeEnabled {
            scheduleLivePreview()
        } else if !isBusy {
            status = "调整已修改，点击「立即预览」应用"
        }
    }

    func setRealtime(_ enabled: Bool) {
        realtimeEnabled = enabled
        if enabled && isDirty && !isBusy {
            scheduleLivePreview()
        } else if !enabled {
            debounceTask?.cancel()
            debounceTask = nil
            if isDirty { status = "实时预览已关闭，点击「立即预览」应用" }
        }
    }

    private func scheduleLivePreview() {
        debounceTask?.cancel()
        guard !isBusy, realtimeEnabled, hasPhoto else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 240_000_000)
            guard !Task.isCancelled else { return }
            self?.startPreview()
        }
    }

    private func startPreview() {
        guard !isBusy, !previewInFlight, let data = sourceData else { return }
        guard !FilmCatalog.films.isEmpty, !FilmCatalog.papers.isEmpty else {
            status = "胶片或相纸资源未加载"
            return
        }
        debounceTask?.cancel()
        debounceTask = nil
        let captured = snapshot()
        let capturedPhotoID = photoID
        previewInFlight = true
        isRendering = true
        isDirty = false
        status = "光谱预览计算中…"

        renderer.render(data: data, photoID: capturedPhotoID, settings: captured) { [weak self] outcome in
            guard let self else { return }
            self.previewInFlight = false
            self.isRendering = false

            let upToDate = self.photoID == capturedPhotoID && self.snapshot() == captured
            switch outcome {
            case let .success(photo):
                if upToDate {
                    if self.lastSuccessfulPhotoID == capturedPhotoID,
                       self.lastSuccessfulSettings != captured,
                       let before = self.processed {
                        self.previousProcessed = before
                        self.pixelChangePercent = PreviewDifference.averageRGBChangePercent(
                            from: before, to: photo.processed
                        )
                    } else if self.lastSuccessfulPhotoID != capturedPhotoID {
                        self.previousProcessed = nil
                        self.pixelChangePercent = nil
                    }
                    self.lastSuccessfulPhotoID = capturedPhotoID
                    self.lastSuccessfulSettings = captured
                    self.original = photo.original
                    self.processed = photo.processed
                    self.lastElapsedMS = photo.elapsedMS
                    self.lastParametersVerified = photo.parametersVerified
                    self.previewSequence += 1
                    self.status = "\(FilmCatalog.filmName(captured.filmStock)) · 已实时预览"
                    self.isDirty = false
                    self.onSuccessfulRender?(captured)
                }
            case let .failure(error):
                if upToDate {
                    self.status = "光谱渲染失败：\(error.localizedDescription)"
                    self.isDirty = true
                    // Do not retry an invalid stock/parameter forever.
                }
            }
            // An outdated result must not overwrite the newer slider values.
            // Schedule one fresh render after the latest gesture pauses.
            if !upToDate && self.realtimeEnabled && !self.isBusy {
                self.isDirty = true
                self.scheduleLivePreview()
            } else if !upToDate {
                self.isDirty = true
            }
        }
    }

    func selectFilm(_ id: String) {
        guard id != filmID else { return }
        filmID = id
        // Respect each measured negative's preferred paper when present.
        if let target = FilmCatalog.films.first(where: { $0.id == id })?.targetPrint,
           FilmCatalog.papers.contains(where: { $0.id == target }) {
            paperID = target
        }
        markDirty()
    }

    private func snapshot() -> FilmSettings {
        FilmSettings(
            filmStock: filmID, printStock: paperID,
            exposureEV: exposureEV, grainAmount: grainAmount,
            halationAmount: halationAmount, printExposure: printExposure,
            magentaShift: magentaShift, yellowShift: yellowShift,
            softness: softness
        )
    }

    func importPhoto(_ item: PhotosPickerItem?) {
        guard let item, !isBusy, !isRendering else { return }
        isBusy = true
        status = "读取照片中…"
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw PortError.message("照片读取失败")
                }
                replaceSourceImage(data, format: "照片图库")
                isBusy = false
                applySettings()
            } catch {
                isBusy = false
                status = "照片读取失败：\(error.localizedDescription)"
            }
        }
    }

    /// Shared new-photo reset also resets the inline UIKit zoom surface.
    private func replaceSourceImage(_ data: Data, format: String) {
        debounceTask?.cancel()
        debounceTask = nil
        sourceData = data
        photoID = UUID()
        photoSelectionVersion += 1
        capturedFormat = format
        original = nil
        processed = nil
        previousProcessed = nil
        compare = false
        pixelChangePercent = nil
        lastSuccessfulPhotoID = nil
        lastSuccessfulSettings = nil
        lastParametersVerified = false
        isDirty = false
    }

    func prepareCamera(_ completion: @escaping () -> Void) {
        guard !isBusy, !isRendering else { return }
        isBusy = true
        status = "正在释放暗房 GPU 缓存，准备拍照…"
        renderer.suspendForCamera { [weak self] in
            guard let self else { return }
            self.isBusy = false
            self.status = "相机已准备就绪"
            completion()
        }
    }

    func importCameraCapture(_ capture: CapturedCameraPhoto) {
        guard !isBusy, !isRendering else {
            status = "正在处理上一张照片，请稍后重试"
            return
        }
        replaceSourceImage(capture.processedData, format: capture.modeLabel)
        status = "系统相机照片已导入，正在进行光谱渲染…"
        applySettings()
    }

    func exportOriginal(
        format: PreviewExporter.Format,
        limitOverride: ExportLimit? = nil,
        completion: @escaping (Result<HighResExportResult, Error>) -> Void
    ) {
        guard let data = sourceData, processed != nil, !isBusy, !isRendering else {
            status = "请先选择照片并完成预览"
            return
        }
        guard !isDirty else {
            status = "请先应用未渲染的参数"
            return
        }
        debounceTask?.cancel()
        debounceTask = nil
        isBusy = true
        exportPhase = "准备高清导出…"
        status = "高清导出执行中，预览已临时释放 GPU 缓存"
        let settings = snapshot()
        renderer.exportOriginal(
            data: data, settings: settings, format: format, limit: limitOverride ?? exportLimit,
            progress: { [weak self] stage in
                self?.exportPhase = stage
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.isBusy = false
                self.exportPhase = ""
                switch result {
                case let .success(info):
                    self.lastExportInfo = info.summary
                    self.status = "已生成高清文件：" + info.summary
                case let .failure(error):
                    self.lastExportInfo = "导出失败：" + error.localizedDescription
                    self.status = self.lastExportInfo
                }
                completion(result)
            }
        )
    }

    func applySettings() {
        // Explicit refresh bypasses debounce and retains the same serialized
        // original 81-wavelength engine/session path.
        guard !isBusy else { return }
        debounceTask?.cancel()
        debounceTask = nil
        if previewInFlight {
            isDirty = true
            // The current render completion will schedule the latest values.
            return
        }
        startPreview()
    }
}

private enum FilmBrowseFilter: String, CaseIterable {
    case all = "全部"
    case kodak = "Kodak"
    case fuji = "Fujifilm"
    case cinema = "电影负片"

    func accepts(_ stock: FilmCatalog.Stock) -> Bool {
        let name = stock.name.lowercased()
        switch self {
        case .all: return true
        case .kodak: return name.contains("kodak")
        case .fuji: return name.contains("fujifilm")
        case .cinema:
            return name.contains("vision3") || name.contains("verita") ||
                   name.contains("cine") || name.contains("500t")
        }
    }
}

private enum EditorTab: String, CaseIterable {
    case film = "胶片"
    case paper = "相纸"
    case adjust = "调节"
    case presets = "预设"
    case export = "导出"

    var symbol: String {
        switch self {
        case .film: return "film"
        case .paper: return "square.stack.3d.up"
        case .adjust: return "slider.horizontal.3"
        case .presets: return "bookmark"
        case .export: return "square.and.arrow.up"
        }
    }
}

private enum AdjustmentGroup: String, CaseIterable {
    case camera = "拍摄与胶片"
    case print = "暗房冲印"
}

private enum PaperBrowseFilter: String, CaseIterable {
    case all = "全部"
    case kodak = "Kodak"
    case fuji = "Fujifilm"

    func accepts(_ stock: FilmCatalog.Stock) -> Bool {
        let name = stock.name.lowercased()
        switch self {
        case .all: return true
        case .kodak: return name.contains("kodak")
        case .fuji: return name.contains("fujifilm")
        }
    }
}

struct EditorView: View {
    let onBack: () -> Void

    @StateObject private var model = EditorModel()
    @StateObject private var presetStore = PresetStore()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var zoomResetToken = 0
    @State private var zoomCommand = 0
    @State private var zoomDirection = 0
    @State private var pendingCapture: CapturedCameraPhoto?
    @State private var showSavePreset = false
    @State private var newPresetName = ""
    @State private var copiedStatus = false
    @State private var shareItem: ShareItem?
    @State private var mostRecentExport: ShareItem?
    @State private var mostRecentExportLabel = ""
    @State private var showPreviousFilm = false
    @State private var inlineFullResolution: HighResExportResult?
    @State private var inlineResolutionVersion = -1
    @State private var savingToPhotos = false
    @State private var photoSaveFeedback = ""

    @State private var filmFilter: FilmBrowseFilter = .all
    @State private var paperFilter: PaperBrowseFilter = .all
    @State private var cameraExpanded = true
    @State private var darkroomExpanded = false
    @State private var presetsExpanded = false
    @State private var exportExpanded = false
    @State private var selectedTab: EditorTab = .adjust
    @State private var adjustmentGroup: AdjustmentGroup = .camera

    private var filteredFilms: [FilmCatalog.Stock] {
        FilmCatalog.films.filter { filmFilter.accepts($0) }
    }

    private var filteredPapers: [FilmCatalog.Stock] {
        FilmCatalog.papers.filter { paperFilter.accepts($0) }
    }

    private var canExport: Bool {
        !model.isBusy && !model.isRendering && !model.isDirty &&
        !savingToPhotos && model.processed != nil
    }

    private var inlineHighResolutionURL: URL? {
        guard inlineResolutionVersion == model.previewSequence,
              !model.isDirty, !model.compare, !showPreviousFilm,
              let result = inlineFullResolution,
              FileManager.default.fileExists(atPath: result.url.path) else {
            return nil
        }
        return result.url
    }

    private func clearInlineHighResolution() {
        // The full-resolution image is a temporary JPEG. Old files need not
        // accumulate as the user works through many live preview changes.
        if let old = inlineFullResolution {
            try? FileManager.default.removeItem(at: old.url)
        }
        inlineFullResolution = nil
        inlineResolutionVersion = -1
    }

    private func openCamera() {
        guard !showingCamera else { return }
        clearInlineHighResolution()
        model.prepareCamera {
            showingCamera = true
        }
    }

    private func fitWholePhoto() {
        zoomCommand = 0
        zoomDirection = 0
        zoomResetToken += 1
    }

    private func adjustZoom(_ direction: Int) {
        zoomDirection = direction
        zoomCommand += 1
    }


    private var activeFilmName: String { FilmCatalog.filmName(model.filmID) }
    private var activePaperName: String { FilmCatalog.paperName(model.paperID) }

    private func copyStatus() {
        let metalName = MTLCreateSystemDefaultDevice()?.name ?? "Metal unavailable"
        let dimensions: String
        if let rendered = model.processed {
            dimensions = "\(Int(rendered.size.width)) x \(Int(rendered.size.height))"
        } else {
            dimensions = "No rendered frame"
        }
        let report = """
        SpectraPort native iOS port
        Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
        iOS: \(UIDevice.current.systemVersion)
        Device model: \(UIDevice.current.model)
        Metal: \(metalName)
        Screen: photo editor
        Render status: \(model.status)
        Rendered image: \(model.processed == nil ? "No" : "Yes")
        Rendered dimensions: \(dimensions)
        Photo source: \(model.capturedFormat)
        Camera capture: native UIImagePickerController (system controls)
        Camera privacy key present: \(!(Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String ?? "").isEmpty)
        Camera authorization code: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)
        Preview reset fit: available
        Photo source version: \(model.photoSelectionVersion)
        Film: \(model.filmID)
        Paper: \(model.paperID)
        Exposure EV: \(String(format: "%.2f", model.exposureEV))
        Grain amount: \(String(format: "%.2f", model.grainAmount))
        Halation amount: \(String(format: "%.2f", model.halationAmount))
        Print exposure: \(String(format: "%.2f", model.printExposure))
        Magenta shift: \(String(format: "%.2f", model.magentaShift))
        Yellow shift: \(String(format: "%.2f", model.yellowShift))
        Input digital softness: \(String(format: "%.2f", model.softness))
        Softness stage: Core Image pre-film (independent of original C++ engine)
        Engine render ms: \(model.lastElapsedMS.map { String(format: "%.1f", $0) } ?? "N/A")
        Engine: persistent session, spk_reprint
        Pending edits: \(model.isDirty)
        High-res limit: \(model.exportLimit.rawValue)
        Last high-res export: \(model.lastExportInfo)
        Saved presets: \(presetStore.presets.count)
        Recent combinations: \(presetStore.recentPairs.count)
        UI: darkroom v0.8.1 effect verification
        Product exposure defaults: true
        Filter shift scale: 40 CC per unit
        C++ params readback verified: \(model.lastParametersVerified)
        Preview change (% mean sRGB RGB): \(model.pixelChangePercent.map { String(format: "%.3f", $0) } ?? "N/A")
        Live preview: \(model.realtimeEnabled)
        Live rendering: \(model.isRendering)
        Live debounce: 240 ms
        Halation amount means: back-reflection area; zero disables whole halation node
        Inline pinch-to-zoom: full-tier 12.5MP on demand, no separate screen
        Direct photo library save: PhotoKit add-only JPEG and PNG
        Print paper selector: horizontal swipe + dropdown
        Controls: 44-point tap targets and integer step indexes
        Bundle identifier: \(Bundle.main.bundleIdentifier ?? "unknown")
        """
        UIPasteboard.general.string = report
        copiedStatus = true
    }

    private func exportPreview(_ format: PreviewExporter.Format) {
        guard let image = model.processed, canExport else {
            model.status = "请先应用全部设置，然后再导出"
            return
        }
        do {
            let saved = ShareItem(url: try PreviewExporter.write(image, format: format))
            mostRecentExport = saved
            let attributes = try FileManager.default.attributesOfItem(atPath: saved.url.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            mostRecentExportLabel = "\(format == .jpeg ? "JPEG" : "PNG") · \(Int(image.size.width)) × \(Int(image.size.height)) · \(size) · 预览"
            shareItem = saved
        } catch {
            model.status = "导出预览失败：\(error.localizedDescription)"
        }
    }

    /// Load the original full-tier spectral render into the *same* preview.
    /// First pinch/double tap requests it. It is not an enlarged thumbnail.
    private func inspectFullResolution() {
        guard canExport, inlineHighResolutionURL == nil else { return }
        let version = model.previewSequence
        model.exportOriginal(format: .jpeg, limitOverride: .high) { result in
            if case let .success(info) = result {
                guard version == model.previewSequence, !model.isDirty else {
                    try? FileManager.default.removeItem(at: info.url)
                    return
                }
                clearInlineHighResolution()
                inlineFullResolution = info
                inlineResolutionVersion = version
                model.status = "已在预览区载入高清细节：" + info.summary
            }
        }
    }

    private func saveToPhotoLibrary(_ format: PreviewExporter.Format) {
        guard canExport else {
            photoSaveFeedback = "请先完成预览，再保存照片"
            return
        }
        savingToPhotos = true
        photoSaveFeedback = "检查相册写入权限…"
        PhotoLibrarySaver.requestAddPermission { permission in
            switch permission {
            case let .failure(error):
                savingToPhotos = false
                photoSaveFeedback = error.localizedDescription
                model.status = photoSaveFeedback
            case .success:
                photoSaveFeedback = "正在生成高清照片…"
                model.exportOriginal(format: format) { result in
                    switch result {
                    case let .failure(error):
                        savingToPhotos = false
                        photoSaveFeedback = "高清生成失败：" + error.localizedDescription
                        model.status = photoSaveFeedback
                    case let .success(info):
                        mostRecentExport = ShareItem(url: info.url)
                        mostRecentExportLabel = info.summary
                        photoSaveFeedback = "正在写入 iPhone 相册…"
                        PhotoLibrarySaver.saveGeneratedFile(info.url) { saved in
                            savingToPhotos = false
                            switch saved {
                            case .success:
                                photoSaveFeedback = "已保存到相册 · " + info.fileFormat +
                                    " · \(info.width) × \(info.height)"
                                model.status = photoSaveFeedback
                            case let .failure(error):
                                photoSaveFeedback = "保存相册失败：" + error.localizedDescription
                                model.status = photoSaveFeedback
                            }
                        }
                    }
                }
            }
        }
    }

    private func exportOriginal(_ format: PreviewExporter.Format) {
        model.exportOriginal(format: format) { result in
            if case let .success(output) = result {
                let saved = ShareItem(url: output.url)
                mostRecentExport = saved
                mostRecentExportLabel = output.summary
                shareItem = saved
            }
        }
    }

    /// Large fixed photo surface, independent of the scrolling controls.
    private var previewSection: some View {
        ZStack {
            Color.black

            if let image = model.compare
                ? model.original
                : (showPreviousFilm ? model.previousProcessed : model.processed) {
                GeometryReader { frame in
                    InlineZoomPreview(
                        preview: image,
                        highResolutionURL: inlineHighResolutionURL,
                        resetToken: zoomResetToken,
                        zoomCommand: zoomCommand,
                        zoomDirection: zoomDirection,
                        onNeedsHighResolution: { inspectFullResolution() }
                    )
                    .frame(width: frame.size.width, height: frame.size.height)
                    // Rebuild the native UIScrollView on reset. This remains
                    // reliable even when its zoom/inset state is inconsistent
                    // after live Core Image/Metal parameter updates.
                    .id("source-\(model.photoSelectionVersion)-fit-\(zoomResetToken)")
                }
            } else {
                VStack(spacing: 13) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 49, weight: .ultraLight))
                        .foregroundStyle(DarkroomStyle.accent)
                    Text("让光线经过胶片")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(DarkroomStyle.primary)
                    Text("下方「图库」选择照片，或打开「拍摄」")
                        .font(.system(size: 12))
                        .foregroundStyle(DarkroomStyle.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("预览 1440p")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.69), in: Capsule())
                    Text(inlineHighResolutionURL == nil ? "高清 · 按需载入" : "高清 · 12.5MP")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(DarkroomStyle.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.69), in: Capsule())
                    Spacer()
                    Button {
                        fitWholePhoto()
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.67), in: RoundedRectangle(cornerRadius: 11))
                    }
                    .accessibilityLabel("整张照片，适应屏幕")
                    .disabled(model.processed == nil)
                }

                Spacer()

                HStack(alignment: .bottom, spacing: 8) {
                    Button {
                        model.compare.toggle()
                        showPreviousFilm = false
                    } label: {
                        Label(model.compare ? "效果" : "原图", systemImage: "square.on.square")
                    }
                    .disabled(model.processed == nil)
                    if model.previousProcessed != nil {
                        Button {
                            model.compare = false
                            showPreviousFilm.toggle()
                        } label: {
                            Label(showPreviousFilm ? "当前" : "上次", systemImage: "rectangle.on.rectangle")
                        }
                    }
                    Spacer()
                    Button {
                        inspectFullResolution()
                    } label: {
                        Image(systemName: "sparkle.magnifyingglass")
                    }
                    .disabled(!canExport || inlineHighResolutionURL != nil)
                    .accessibilityLabel("载入高清细节")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .padding(9)
                .background(.black.opacity(0.54), in: RoundedRectangle(cornerRadius: 11))
            }
            .padding(10)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 7) {
                        Button {
                            adjustZoom(1)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("放大预览")
                        Text("缩放")
                            .font(.system(size: 9, weight: .medium))
                        Button {
                            adjustZoom(-1)
                        } label: {
                            Image(systemName: "minus")
                        }
                        .accessibilityLabel("缩小预览")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .buttonStyle(.plain)
                    .frame(width: 40)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.70), in: Capsule())
                    .disabled(model.processed == nil)
                }
                Spacer()
                    .frame(height: 49)
            }
            .padding(.trailing, 13)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15)
            .stroke(DarkroomStyle.line, lineWidth: 1))
    }

    private var filmSection: some View {
        DarkroomPanel {
            VStack(alignment: .leading, spacing: 13) {
                DarkroomSectionTitle(number: "01", title: "胶片", subtitle: "左右滑动选择")

                HStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .foregroundStyle(DarkroomStyle.accent)
                    Text(activeFilmName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DarkroomStyle.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    Menu {
                        ForEach(FilmCatalog.films) { stock in
                            Button(stock.name) { model.selectFilm(stock.id) }
                        }
                    } label: {
                        Label("列表", systemImage: "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DarkroomStyle.accent)
                    }
                    .disabled(model.isBusy)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(FilmBrowseFilter.allCases, id: \.self) { filter in
                            DarkroomChip(
                                title: filter.rawValue, selected: filmFilter == filter
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    filmFilter = filter
                                }
                            }
                        }
                    }
                }

                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(filteredFilms) { stock in
                                FilmStockCard(
                                    name: stock.name,
                                    selected: stock.id == model.filmID
                                ) {
                                    guard !model.isBusy else { return }
                                    model.selectFilm(stock.id)
                                    withAnimation(.easeInOut(duration: 0.22)) {
                                        reader.scrollTo(stock.id, anchor: .center)
                                    }
                                }
                                .id(stock.id)
                                .disabled(model.isBusy)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onAppear {
                        reader.scrollTo(model.filmID, anchor: .center)
                    }
                    .onChange(of: model.filmID) { newValue in
                        if filteredFilms.contains(where: { $0.id == newValue }) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                reader.scrollTo(newValue, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: filmFilter) { _ in
                        if filteredFilms.contains(where: { $0.id == model.filmID }) {
                            reader.scrollTo(model.filmID, anchor: .center)
                        }
                    }
                }
                Text("选中胶片后，将自动匹配原版配置推荐的相纸；可在下方手动更换。")
                    .font(.system(size: 10))
                    .foregroundStyle(DarkroomStyle.secondary)
            }
        }
    }

    private var paperSection: some View {
        DarkroomPanel {
            VStack(alignment: .leading, spacing: 13) {
                DarkroomSectionTitle(number: "02", title: "相纸", subtitle: "左右滑动选择")

                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(DarkroomStyle.accent)
                    Text(activePaperName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DarkroomStyle.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    Menu {
                        ForEach(FilmCatalog.papers) { stock in
                            Button {
                                guard !model.isBusy else { return }
                                model.paperID = stock.id
                            } label: {
                                if stock.id == model.paperID {
                                    Label(stock.name, systemImage: "checkmark")
                                } else {
                                    Text(stock.name)
                                }
                            }
                        }
                    } label: {
                        Label("列表", systemImage: "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DarkroomStyle.accent)
                    }
                    .disabled(model.isBusy)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(PaperBrowseFilter.allCases, id: \.self) { filter in
                            DarkroomChip(title: filter.rawValue,
                                         selected: paperFilter == filter) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    paperFilter = filter
                                }
                            }
                        }
                    }
                }

                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(filteredPapers) { stock in
                                FilmStockCard(
                                    name: stock.name,
                                    selected: stock.id == model.paperID,
                                    kind: "PHOTO PAPER"
                                ) {
                                    guard !model.isBusy, stock.id != model.paperID else { return }
                                    model.paperID = stock.id
                                    withAnimation(.easeInOut(duration: 0.22)) {
                                        reader.scrollTo(stock.id, anchor: .center)
                                    }
                                }
                                .id(stock.id)
                                .disabled(model.isBusy)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onAppear {
                        reader.scrollTo(model.paperID, anchor: .center)
                    }
                    .onChange(of: model.paperID) { newValue in
                        if filteredPapers.contains(where: { $0.id == newValue }) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                reader.scrollTo(newValue, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: paperFilter) { _ in
                        if filteredPapers.contains(where: { $0.id == model.paperID }) {
                            reader.scrollTo(model.paperID, anchor: .center)
                        }
                    }
                }

                Text("使用原版测量相纸配置；选中后自动实时冲印。也可点击右上角「列表」选择。")
                    .font(.system(size: 10))
                    .foregroundStyle(DarkroomStyle.secondary)
            }
        }
    }

    private var controlsSection: some View {
        VStack(spacing: 12) {
            DarkroomPanel {
                DisclosureGroup(isExpanded: $cameraExpanded) {
                    VStack(spacing: 18) {
                        DarkroomControlRow(
                            label: "曝光补偿", value: $model.exposureEV,
                            range: -3...3, step: 0.1, suffix: " EV",
                            disabled: model.isBusy
                        )
                        DarkroomControlRow(
                            label: "胶片颗粒", value: $model.grainAmount,
                            range: 0...2, step: 0.1, suffix: "×",
                            disabled: model.isBusy
                        )
                        DarkroomControlRow(
                            label: "降低数码锐利感", value: $model.softness,
                            range: 0...1, step: 0.05, suffix: "",
                            disabled: model.isBusy
                        )
                        Text("0 = 保留拍摄原始锐利度；1 = 适度减弱数码边缘反差。不能还原 JPEG 已丢失的细节，胶片颗粒在此之后生成。")
                            .font(.system(size: 10))
                            .foregroundStyle(DarkroomStyle.secondary)
                        DarkroomControlRow(
                            label: "反射光晕面积", value: $model.halationAmount,
                            range: 0...3, step: 0.1, suffix: "×",
                            disabled: model.isBusy
                        )
                        Text("0 = 完全关闭光晕处理；1 = 胶片默认反射面积。普通画面效果较弱，夜间点光源边缘更明显。")
                            .font(.system(size: 10))
                            .foregroundStyle(DarkroomStyle.secondary)
                    }
                    .padding(.top, 16)
                } label: {
                    DarkroomSectionTitle(number: "03", title: "拍摄与胶片", subtitle: "3 项参数")
                }
                .tint(DarkroomStyle.accent)
            }
            DarkroomPanel {
                DisclosureGroup(isExpanded: $darkroomExpanded) {
                    VStack(spacing: 18) {
                        DarkroomControlRow(
                            label: "相纸曝光", value: $model.printExposure,
                            range: 0.2...3, step: 0.05, suffix: "×",
                            disabled: model.isBusy
                        )
                        DarkroomControlRow(
                            label: "放大机 M 滤色", value: $model.magentaShift,
                            range: -0.5...0.5, step: 0.05, suffix: "",
                            disabled: model.isBusy
                        )
                        DarkroomControlRow(
                            label: "放大机 Y 滤色", value: $model.yellowShift,
                            range: -0.5...0.5, step: 0.05, suffix: "",
                            disabled: model.isBusy
                        )
                    }
                    .padding(.top, 16)
                } label: {
                    DarkroomSectionTitle(number: "04", title: "暗房冲印", subtitle: "3 项参数")
                }
                .tint(DarkroomStyle.accent)
            }
        }
    }

    private var presetsSection: some View {
        DarkroomPanel {
            DisclosureGroup(isExpanded: $presetsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Button {
                            newPresetName = activeFilmName + " · 自定义"
                            showSavePreset = true
                        } label: {
                            Label("保存参数", systemImage: "bookmark")
                        }
                        .disabled(model.isBusy || model.filmID.isEmpty || model.paperID.isEmpty)

                        Menu {
                            ForEach(presetStore.presets) { preset in
                                Button(preset.name) { model.loadLook(preset.settings) }
                            }
                        } label: {
                            Label("载入预设", systemImage: "square.stack")
                        }
                        .disabled(model.isBusy || presetStore.presets.isEmpty)
                    }
                    .buttonStyle(.bordered)
                    .tint(DarkroomStyle.accent)

                    HStack {
                        Button("恢复默认参数") { model.restoreDefaults() }
                        Spacer()
                        if !presetStore.presets.isEmpty {
                            Menu {
                                ForEach(presetStore.presets) { preset in
                                    Button(role: .destructive) {
                                        presetStore.remove(id: preset.id)
                                    } label: {
                                        Text("删除「\(preset.name)」")
                                    }
                                }
                            } label: {
                                Label("删除预设", systemImage: "trash")
                            }
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(DarkroomStyle.secondary)
                    .disabled(model.isBusy)

                    if !presetStore.recentPairs.isEmpty {
                        Menu {
                            ForEach(presetStore.recentPairs) { item in
                                Button(
                                    "\(FilmCatalog.filmName(item.filmID)) / \(FilmCatalog.paperName(item.paperID))"
                                ) {
                                    model.selectPair(film: item.filmID, paper: item.paperID)
                                }
                            }
                        } label: {
                            Label("最近使用的胶片与相纸", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 12))
                                .foregroundStyle(DarkroomStyle.accent)
                        }
                        .disabled(model.isBusy)
                    }

                    Text("最多 30 组本地预设。载入后点击底部「应用调整」。")
                        .font(.system(size: 10))
                        .foregroundStyle(DarkroomStyle.secondary)
                }
                .padding(.top, 14)
            } label: {
                DarkroomSectionTitle(
                    number: "05", title: "我的预设",
                    subtitle: "\(presetStore.presets.count) 组已保存"
                )
            }
            .tint(DarkroomStyle.accent)
        }
    }

    private var exportSection: some View {
        DarkroomPanel {
            DisclosureGroup(isExpanded: $exportExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Menu {
                        Button("JPEG · sRGB") { exportPreview(.jpeg) }
                        Button("PNG · sRGB") { exportPreview(.png) }
                    } label: {
                        Label("分享 1440px 预览图", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!canExport)


                    Text("高清导出 · 使用原版 full 光谱渲染")
                        .font(.system(size: 12))
                        .foregroundStyle(DarkroomStyle.secondary)

                    Picker("导出分辨率", selection: $model.exportLimit) {
                        ForEach(ExportLimit.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isBusy)

                    HStack(spacing: 10) {
                        Button("导出 JPEG") { exportOriginal(.jpeg) }
                            .frame(maxWidth: .infinity)
                        Button("导出 PNG") { exportOriginal(.png) }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DarkroomStyle.accent)
                    .disabled(!canExport)

                    Menu {
                        Button("保存 JPEG 到相册") { saveToPhotoLibrary(.jpeg) }
                        Button("保存 PNG 到相册") { saveToPhotoLibrary(.png) }
                    } label: {
                        Label(savingToPhotos ? "保存到相册中…" : "直接保存到 iPhone 相册",
                              systemImage: "square.and.arrow.down")
                    }
                    .disabled(!canExport)

                    if let last = mostRecentExport {
                        Text(mostRecentExportLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(DarkroomStyle.secondary)
                        Button {
                            if FileManager.default.fileExists(atPath: last.url.path) {
                                shareItem = ShareItem(url: last.url)
                            } else {
                                model.status = "文件已被系统清理，请重新导出"
                                mostRecentExport = nil
                            }
                        } label: {
                            Label("再次分享最近导出文件", systemImage: "arrowshape.turn.up.right")
                        }
                        .disabled(model.isBusy)
                    }
                    Text("超过所选像素上限会降采样；预览与高清导出使用不同渲染层级。")
                        .font(.system(size: 10))
                        .foregroundStyle(DarkroomStyle.secondary)
                }
                .padding(.top, 15)
                .font(.system(size: 13))
            } label: {
                DarkroomSectionTitle(number: "06", title: "导出与分享", subtitle: "JPEG / PNG")
            }
            .tint(DarkroomStyle.accent)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isDirty ? DarkroomStyle.accent : Color.green.opacity(0.8))
                    .frame(width: 6, height: 6)
                Text(model.isDirty ? "尚有未应用的修改" : "当前状态")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DarkroomStyle.secondary)
            }
            if let delta = model.pixelChangePercent {
                Text("前后效果采样差异：\(String(format: "%.2f", delta))% · C++ 参数已核对")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DarkroomStyle.accent)
                Text("点预览区下方「上次／当前」切换；这是 80×80 sRGB 像素均值差异，不是人眼感知评分。")
                    .font(.system(size: 10))
                    .foregroundStyle(DarkroomStyle.secondary)
            }
            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(DarkroomStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.isBusy || model.isRendering {
                ProgressView(model.exportPhase.isEmpty ? "光谱引擎处理中…" : model.exportPhase)
                    .tint(DarkroomStyle.accent)
            }
            if FilmCatalog.films.isEmpty || FilmCatalog.papers.isEmpty {
                Text("原版胶片或相纸资源加载失败，请复制诊断。")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 4)
    }

    private var editorSections: some View {
        HStack(spacing: 4) {
            ForEach([EditorTab.film, .paper, .adjust, .presets], id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 16, weight: .medium))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .medium))
                    }
                    .foregroundStyle(selectedTab == tab
                                     ? DarkroomStyle.background : DarkroomStyle.primary)
                    .frame(maxWidth: .infinity, minHeight: 49)
                    .background(
                        selectedTab == tab ? DarkroomStyle.accent : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(DarkroomStyle.surface, in: RoundedRectangle(cornerRadius: 15))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var bottomNavigation: some View {
        HStack(spacing: 0) {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                navigationIcon("图库", symbol: "photo")
            }
            .disabled(model.isBusy || model.isRendering)

            Button {
                openCamera()
            } label: {
                navigationIcon("拍摄", symbol: "camera")
            }
            .disabled(model.isBusy || model.isRendering)

            Button {
                selectedTab = .adjust
            } label: {
                navigationIcon("编辑", symbol: "slider.horizontal.3", selected:
                    selectedTab == .adjust || selectedTab == .film || selectedTab == .paper)
            }

            Button {
                selectedTab = .presets
            } label: {
                navigationIcon("预设", symbol: "square.stack",
                               selected: selectedTab == .presets)
            }

            Button {
                selectedTab = .export
            } label: {
                navigationIcon("更多", symbol: "ellipsis",
                               selected: selectedTab == .export)
            }
        }
        .buttonStyle(.plain)
        .frame(height: 60)
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .background(
            DarkroomStyle.background
                .overlay(alignment: .top) { DarkroomStyle.line.frame(height: 1) }
        )
    }

    private func navigationIcon(_ name: String, symbol: String,
                                selected: Bool = false) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
            Text(name)
                .font(.system(size: 10, weight: selected ? .semibold : .medium))
        }
        .foregroundStyle(selected ? DarkroomStyle.accent : DarkroomStyle.secondary)
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
    }

    private var quickAdjustmentPanel: some View {
        DarkroomPanel {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("实时光谱调节")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DarkroomStyle.primary)
                    Spacer()
                    Toggle(
                        "实时",
                        isOn: Binding(
                            get: { model.realtimeEnabled },
                            set: { model.setRealtime($0) }
                        )
                    )
                    .font(.system(size: 12))
                    .tint(DarkroomStyle.accent)
                    .fixedSize()
                }

                Picker("参数分组", selection: $adjustmentGroup) {
                    ForEach(AdjustmentGroup.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                VStack(spacing: 8) {
                    if adjustmentGroup == .camera {
                        DarkroomControlRow(
                            label: "曝光补偿", value: $model.exposureEV,
                            range: -3...3, step: 0.1, suffix: " EV",
                            disabled: model.isBusy
                        )
                        DarkroomControlRow(
                            label: "胶片颗粒", value: $model.grainAmount,
                            range: 0...2, step: 0.1, suffix: "×",
                            disabled: model.isBusy
                        )
                        DarkroomControlRow(
                            label: "降低数码锐利感", value: $model.softness,
                            range: 0...1, step: 0.05, suffix: "",
                            disabled: model.isBusy
                        )
                        Text("0 = 保留拍摄原始锐利度；1 = 适度减弱数码边缘反差。不能还原 JPEG 已丢失的细节，胶片颗粒在此之后生成。")
                            .font(.system(size: 10))
                            .foregroundStyle(DarkroomStyle.secondary)
                        DarkroomControlRow(
                            label: "反射光晕面积", value: $model.halationAmount,
                            range: 0...3, step: 0.1, suffix: "×",
                            disabled: model.isBusy
                        )
                        Text("0 = 完全关闭光晕处理；1 = 胶片默认反射面积。普通画面效果较弱，夜间点光源边缘更明显。")
                            .font(.system(size: 10))
                            .foregroundStyle(DarkroomStyle.secondary)
                    } else {
                        DarkroomControlRow(
                            label: "相纸曝光", value: $model.printExposure,
                            range: 0.2...3, step: 0.05, suffix: "×",
                            disabled: model.isBusy
                        )
                        DarkroomControlRow(
                            label: "放大机 M 滤色", value: $model.magentaShift,
                            range: -0.5...0.5, step: 0.05, suffix: "",
                            disabled: model.isBusy
                        )
                        DarkroomControlRow(
                            label: "放大机 Y 滤色", value: $model.yellowShift,
                            range: -0.5...0.5, step: 0.05, suffix: "",
                            disabled: model.isBusy
                        )
                    }
                }
                if model.realtimeEnabled {
                    Text("移动滑块后约 0.24 秒合并更新，复用原版负片缓存。")
                        .font(.system(size: 10))
                        .foregroundStyle(DarkroomStyle.secondary)
                } else {
                    Text("实时预览已关闭。使用底部「立即预览」应用参数。")
                        .font(.system(size: 10))
                        .foregroundStyle(DarkroomStyle.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var activePanel: some View {
        switch selectedTab {
        case .film: filmSection
        case .paper: paperSection
        case .adjust: quickAdjustmentPanel
        case .presets:
            presetsSection
                .onAppear { presetsExpanded = true }
        case .export:
            exportSection
                .onAppear { exportExpanded = true }
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    previewSection
                        .frame(height: max(220, geometry.size.height * 0.615))
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .padding(.bottom, 2)

                    editorSections

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            if !model.realtimeEnabled || model.isDirty {
                                Button {
                                    model.applySettings()
                                } label: {
                                    Label("应用调整", systemImage: "wand.and.stars")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(DarkroomStyle.accent)
                                .disabled(model.isBusy || model.isRendering || !model.hasPhoto)
                            }
                            activePanel
                            statusSection
                        }
                        .padding(.horizontal, 13)
                        .padding(.bottom, 18)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DarkroomStyle.background)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(DarkroomStyle.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomNavigation }
            .navigationTitle("SpectraPort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: "film.stack")
                    }
                    .accessibilityLabel("返回诊断")
                    .foregroundStyle(DarkroomStyle.accent)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        copyStatus()
                    } label: {
                        Image(systemName: copiedStatus ? "checkmark.circle" : "info.circle")
                    }
                    .accessibilityLabel("复制诊断状态")

                    Button {
                        selectedTab = .export
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DarkroomStyle.accent)
                }
            }
            .toolbarBackground(DarkroomStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: selectedPhoto) {
                clearInlineHighResolution()
                photoSaveFeedback = ""
                model.importPhoto($0)
                selectedTab = .adjust
            }
            .onChange(of: model.photoSelectionVersion) { _ in
                clearInlineHighResolution()
                fitWholePhoto()
                photoSaveFeedback = ""
            }
            .onChange(of: model.previewSequence) { _ in
                showPreviousFilm = false
                clearInlineHighResolution()
                fitWholePhoto()
            }
            .onChange(of: model.paperID) { _ in model.markDirty() }
            .onChange(of: model.exposureEV) { _ in model.markDirty() }
            .onChange(of: model.grainAmount) { _ in model.markDirty() }
            .onChange(of: model.halationAmount) { _ in model.markDirty() }
            .onChange(of: model.printExposure) { _ in model.markDirty() }
            .onChange(of: model.magentaShift) { _ in model.markDirty() }
            .onChange(of: model.yellowShift) { _ in model.markDirty() }
            .onChange(of: model.softness) { _ in model.markDirty() }
            .onAppear {
                model.onSuccessfulRender = { [weak presetStore] settings in
                    presetStore?.recordUse(settings)
                }
            }
            .alert("保存自定义预设", isPresented: $showSavePreset) {
                TextField("预设名称", text: $newPresetName)
                Button("保存") {
                    if presetStore.save(name: newPresetName, settings: model.currentSettings) {
                        model.status = "已在本机保存预设"
                    } else {
                        model.status = "预设名称不能为空，且参数必须有效"
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("同名预设将更新，最多保存 30 组。")
            }
            .sheet(item: $shareItem) { item in
                PreviewShareSheet(url: item.url)
            }
            .fullScreenCover(isPresented: $showingCamera, onDismiss: {
                if let capture = pendingCapture {
                    pendingCapture = nil
                    model.importCameraCapture(capture)
                    selectedTab = .adjust
                }
            }) {
                StableSpectraCameraView(
                    onCapture: { capture in
                        pendingCapture = capture
                        showingCamera = false
                    },
                    onCancel: {
                        showingCamera = false
                    }
                )
            }

        }
        .preferredColorScheme(.dark)
    }
}
