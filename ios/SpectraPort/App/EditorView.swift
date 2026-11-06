import AVFoundation
import Metal
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
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
    @Published private(set) var rawOptions: RAWDecodeOptions?
    @Published private(set) var rawAsShot: RAWProbe?
    @Published var rawImportError: String?
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
    @Published var grade = Adjustments.default
    @Published var masks: [EditMask] = []
    @Published private(set) var photoGeometry = PhotoGeometry.identity
    @Published private(set) var cropEditingImage: UIImage?
    @Published private(set) var framedProcessed: UIImage?
    @Published private(set) var filmEdge = MobileFilmEdgeSettings()
    @Published private(set) var unframedProcessed: UIImage?
    private var unframedOriginal: UIImage?

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

    /// Independent film-edge output. Original film, curves, RAW and local
    /// mask coordinates are never modified when these controls change.
    private func refreshFilmEdgePreview() {
        guard filmEdge.needsComposite, let processed else {
            framedProcessed = nil
            return
        }
        do {
            framedProcessed = try MobileFilmEdgeRenderer.preview(
                processed, settings: filmEdge,
                filmName: FilmCatalog.filmName(filmID))
        } catch {
            framedProcessed = nil
            status = "片边预览无法生成：" + error.localizedDescription
        }
    }

    func setFilmEdge(_ value: MobileFilmEdgeSettings) {
        guard !isBusy && !isRendering else { return }
        let next = value.normalized()
        guard next != filmEdge else { return }
        filmEdge = next
        refreshFilmEdgePreview()
        previewSequence += 1
        if !isDirty {
            status = filmEdge.needsComposite
                ? "片边／日期／签名已应用到预览和高清导出"
                : "已关闭片边、日期和签名，保留原图"
        }
    }

    func updateDateBack(_ date: MobileDateBackSettings) {
        var value = filmEdge
        value.dateBack = date
        setFilmEdge(value)
    }

    func updateSignature(_ signature: MobileSignatureSettings) {
        var value = filmEdge
        value.signature = signature
        setFilmEdge(value)
    }

    /// RAW WB lives upstream of physical film simulation and is never stored
    /// inside reusable film/paper presets. Invalidate native photo cache.
    func changeRAWOptions(_ next: RAWDecodeOptions) {
        guard let previous = rawOptions, previous != next, !isBusy else { return }
        rawOptions = next
        photoID = UUID()
        markDirty()
    }

    func importRAWFile(_ url: URL) {
        guard !isBusy, !isRendering else { return }
        guard RawImageDeveloper.isRaw(filename: url.lastPathComponent) else {
            let message = "所选文件不是支持的 RAW。请选 RAF、DNG、NEF、ARW、CR2/CR3 等格式。"
            status = message
            rawImportError = message
            return
        }
        rawImportError = nil
        isBusy = true
        status = "读取相机 RAW 和 As Shot 白平衡…"
        let hint = UTType(filenameExtension: url.pathExtension)?.identifier
        Task {
            do {
                let payload = try await Task.detached(priority: .userInitiated) {
                    let data = try RawImageDeveloper.readFile(at: url)
                    let probe = try RawImageDeveloper.probe(data, hint: hint)
                    return (data, probe)
                }.value
                replaceSourceImage(payload.0, format: "相机 RAW · " + url.pathExtension.uppercased())
                rawAsShot = payload.1
                rawOptions = RAWDecodeOptions(
                    identifierHint: hint, useAsShot: true,
                    temperature: payload.1.temperature, tint: payload.1.tint,
                    lensCorrection: payload.1.lensCorrectionSupported)
                isBusy = false
                applySettings()
            } catch {
                isBusy = false
                let message = "RAW 文件无法显影：" + error.localizedDescription
                status = message
                rawImportError = message
            }
        }
    }

    /// Geometry is photo-specific, not part of a reusable film/paper preset.
    /// Re-render only the already-processed preview when moving crop handles.
    func setPhotoGeometry(_ next: PhotoGeometry) {
        guard next != photoGeometry else { return }
        let orientationChanged =
            next.quarterTurns != photoGeometry.quarterTurns ||
            next.straightenDegrees != photoGeometry.straightenDegrees ||
            next.flipHorizontal != photoGeometry.flipHorizontal ||
            next.flipVertical != photoGeometry.flipVertical
        photoGeometry = next
        if let full = unframedProcessed {
            if orientationChanged || cropEditingImage == nil {
                cropEditingImage = PhotoGeometryPreview.render(
                    full, geometry: next, onlyOrientation: true)
            }
            processed = PhotoGeometryPreview.render(full, geometry: next)
            refreshFilmEdgePreview()
        }
        if let original = unframedOriginal {
            self.original = PhotoGeometryPreview.render(original, geometry: next)
        }
        previousProcessed = nil
        previewSequence += 1
    }

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
        grade = settings.adjustments
        masks = settings.masks
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
        let capturedRAW = rawOptions
        let capturedPhotoID = photoID
        previewInFlight = true
        isRendering = true
        isDirty = false
        status = "光谱预览计算中…"

        renderer.render(
            data: data, photoID: capturedPhotoID, settings: captured,
            rawOptions: capturedRAW
        ) { [weak self] outcome in
            guard let self else { return }
            self.previewInFlight = false
            self.isRendering = false

            let upToDate = self.photoID == capturedPhotoID &&
                self.snapshot() == captured && self.rawOptions == capturedRAW
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
                    self.unframedOriginal = photo.original
                    self.unframedProcessed = photo.processed
                    self.cropEditingImage = PhotoGeometryPreview.render(
                        photo.processed, geometry: self.photoGeometry,
                        onlyOrientation: true)
                    self.original = PhotoGeometryPreview.render(
                        photo.original, geometry: self.photoGeometry)
                    self.processed = PhotoGeometryPreview.render(
                        photo.processed, geometry: self.photoGeometry)
                    self.refreshFilmEdgePreview()
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
            softness: softness,
            adjustments: grade,
            masks: masks
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
                let rawType = item.supportedContentTypes.first { $0.conforms(to: .rawImage) }
                if let rawType {
                    let probe = try await Task.detached(priority: .userInitiated) {
                        try RawImageDeveloper.probe(data, hint: rawType.identifier)
                    }.value
                    replaceSourceImage(data, format: "相册 RAW")
                    rawAsShot = probe
                    rawOptions = RAWDecodeOptions(
                        identifierHint: rawType.identifier, useAsShot: true,
                        temperature: probe.temperature, tint: probe.tint,
                        lensCorrection: probe.lensCorrectionSupported)
                } else {
                    replaceSourceImage(data, format: "照片图库")
                }
                isBusy = false
                applySettings()
            } catch {
                isBusy = false
                status = "照片读取失败：\(error.localizedDescription)"
            }
        }
    }

    private static func sourceImprintMetadata(
        _ data: Data
    ) -> (date: Date?, dataLine: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil) as? [String: Any] else {
            return (nil, "")
        }
        let exif = properties[kCGImagePropertyExifDictionary as String]
            as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String]
            as? [String: Any] ?? [:]
        let time = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String)
            ?? (tiff[kCGImagePropertyTIFFDateTime as String] as? String)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let captured = time.flatMap { formatter.date(from: $0) }
        var fields: [String] = []
        if let aperture = exif[kCGImagePropertyExifFNumber as String] as? NSNumber {
            fields.append(String(format: "f/%.1f", aperture.doubleValue))
        }
        if let exposure = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber {
            let seconds = exposure.doubleValue
            if seconds > 0 {
                fields.append(seconds < 1
                    ? "1/\(Int((1.0/seconds).rounded()))"
                    : String(format:"%.1fs",seconds))
            }
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String]
                      as? [NSNumber])?.first {
            fields.append("ISO\(iso.intValue)")
        }
        return (captured, fields.joined(separator: "  "))
    }

    /// Shared new-photo reset also resets the inline UIKit zoom surface.
    private func replaceSourceImage(_ data: Data, format: String) {
        debounceTask?.cancel()
        debounceTask = nil
        sourceData = data
        let metadata = Self.sourceImprintMetadata(data)
        var nextEdge = filmEdge
        nextEdge.dateBack.date = metadata.date ?? Date()
        nextEdge.dateBack.fromEXIF = metadata.date != nil
        nextEdge.dateBack.dataText = metadata.dataLine
        filmEdge = nextEdge
        photoID = UUID()
        photoSelectionVersion += 1
        capturedFormat = format
        rawOptions = nil
        rawAsShot = nil
        original = nil
        processed = nil
        unframedOriginal = nil
        unframedProcessed = nil
        cropEditingImage = nil
        framedProcessed = nil
        photoGeometry = .identity
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
        let geometry = photoGeometry
        let rawAtExport = rawOptions
        let edgeAtExport = filmEdge
        renderer.exportOriginal(
            data: data, settings: settings, format: format,
            geometry: geometry, rawOptions: rawAtExport,
            filmEdge: edgeAtExport,
            limit: limitOverride ?? exportLimit,
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
    case grade = "调色"
    case presets = "预设"
    case export = "更多"

    var symbol: String {
        switch self {
        case .film: return "film"
        case .paper: return "square.stack.3d.up"
        case .adjust: return "slider.horizontal.3"
        case .grade: return "circle.lefthalf.filled"
        case .presets: return "bookmark"
        case .export: return "ellipsis"
        }
    }
}

private enum GradeSubsection: String, CaseIterable {
    case basic = "基础"
    case curves = "曲线"
    case balance = "色彩平衡"
    case local = "局部"
}

private enum AdjustmentGroup: String, CaseIterable {
    case camera = "拍摄与胶片"
    case print = "暗房冲印"
    case geometry = "裁剪"
    case edge = "片边"
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
    let launchCameraOnFirstAppear: Bool

    init(onBack: @escaping () -> Void, launchCameraOnFirstAppear: Bool = false) {
        self.onBack = onBack
        self.launchCameraOnFirstAppear = launchCameraOnFirstAppear
    }

    @StateObject private var model = EditorModel()
    @StateObject private var presetStore = PresetStore()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var hasHandledStartup = false
    @State private var showingStartupSettings = false
    @State private var showingCamera = false
    @State private var showingRAWFileImporter = false
    @State private var showingDateBackEditor = false
    @State private var showingSignatureEditor = false
    @State private var zoomResetToken = 0
    @State private var showingQuickHelp = false
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
    @State private var selectedTab: EditorTab = .film
    @State private var showingPendingWorkflowFeature = false
    @State private var pendingWorkflowFeatureTitle = ""
    @State private var pendingWorkflowFeatureDescription = ""
    @State private var activeSliderReadout: String?
    @State private var adjustmentGroup: AdjustmentGroup = .camera
    @State private var gradeSubsection: GradeSubsection = .basic
    @State private var selectedMaskID: UUID?

    /// The UIKit photo loupe and SwiftUI handles share one exact aspect-fit
    /// coordinate system while local geometry is being manipulated.
    private var editingCropOnPhoto: Bool {
        selectedTab == .adjust && adjustmentGroup == .geometry &&
        model.cropEditingImage != nil && !model.compare && !showPreviousFilm
    }

    private var photoGeometryBinding: Binding<PhotoGeometry> {
        Binding(get: { model.photoGeometry },
                set: { model.setPhotoGeometry($0) })
    }

    private var filmEdgeBinding: Binding<MobileFilmEdgeSettings> {
        Binding(get: { model.filmEdge },
                set: { model.setFilmEdge($0) })
    }

    private var dateBackBinding: Binding<MobileDateBackSettings> {
        Binding(get: { model.filmEdge.dateBack },
                set: { model.updateDateBack($0) })
    }

    private var signatureBinding: Binding<MobileSignatureSettings> {
        Binding(get: { model.filmEdge.signature },
                set: { model.updateSignature($0) })
    }

    private var editingMaskOnPhoto: Bool {
        selectedTab == .grade && gradeSubsection == .local &&
        model.processed != nil && !model.compare && !showPreviousFilm
    }

    private func enterMaskEditingIfNeeded() {
        guard selectedTab == .grade && gradeSubsection == .local else { return }
        // Never show a stale high-resolution frame after the sliders change.
        clearInlineHighResolution()
        fitWholePhoto()
    }

    private var filteredFilms: [FilmCatalog.Stock] {
        FilmCatalog.films.filter { filmFilter.accepts($0) }
    }

    private var filteredPapers: [FilmCatalog.Stock] {
        FilmCatalog.papers.filter { paperFilter.accepts($0) }
    }

    // Overlay visibility never changes the controls panel's height or offset.
    private var needsManualApply: Bool {
        model.hasPhoto && (!model.realtimeEnabled || model.isDirty)
    }

    /// macOS desktop uses +EV for a brighter print; the engine's enlarger
    /// wire field is inverse exposure: print_exposure = 2^(-EV).
    /// Leave persisted wire values intact so pre-v0.14 presets still decode.
    private var printBrightnessStops: Binding<Double> {
        Binding(
            get: {
                -log2(max(0.05, min(20, model.printExposure)))
            },
            set: { stops in
                model.printExposure = pow(2, -stops)
            }
        )
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
        Startup mode: \(UserDefaults.standard.string(forKey: "spectraport.startup.destination") ?? "camera")
        Image sharing: UIActivityViewController (installed share extensions)
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
        Print brightness EV (Mac): \(String(format: "%+.2f", -log2(max(0.05, model.printExposure))))
        Magenta shift: \(String(format: "%.2f", model.magentaShift))
        Yellow shift: \(String(format: "%.2f", model.yellowShift))
        Mac Layer2 global grade: \(model.grade.isNeutral ? "neutral" : "active")
        Mac Layer2 curves: \(model.grade.curves.isIdentity ? "identity" : "custom")
        Mac Layer2 local masks: \(model.masks.count)
        Mac Layer2 GPU kernel: original macOS Shaders.metal::layer2
        Parity beta: v0.14.0 beta.1 · Build 20 · separate bundle
        Layer2 export safety: 6MP only, 12.5MP gated until device memory validation
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
        guard let image = (model.framedProcessed ?? model.processed),
              canExport else {
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

    /// Export a true full-resolution spectral JPEG, then open the ordinary
    /// iOS share sheet so supported installed apps (including WeChat, when
    /// it exposes a compatible share extension) can receive the image.
    private func shareFullResolutionToApps() {
        guard canExport else {
            model.status = "请先完成当前参数渲染再分享"
            return
        }
        model.exportOriginal(format: .jpeg) { result in
            switch result {
            case let .success(output):
                let item = ShareItem(url: output.url)
                mostRecentExport = item
                mostRecentExportLabel = output.summary
                shareItem = item
            case let .failure(error):
                model.status = "生成分享照片失败：" + error.localizedDescription
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
                : (showPreviousFilm ? model.previousProcessed
                    : (editingCropOnPhoto ? model.cropEditingImage
                        : (editingMaskOnPhoto ? model.processed :
                           (model.framedProcessed ?? model.processed)))) {
                GeometryReader { frame in
                    if editingCropOnPhoto {
                        PhotoCropCanvas(
                            image: image, geometry: photoGeometryBinding
                        )
                        .frame(width: frame.size.width, height: frame.size.height)
                    } else if editingMaskOnPhoto {
                        // Local masks use a dedicated, fixed aspect-fit canvas:
                        // no UIScrollView, zoom restoration, or changing image
                        // intrinsic size may change the photo/handle transform.
                        LocalMaskCanvas(
                            image: image,
                            sourceImage: model.unframedProcessed ?? image,
                            geometry: model.photoGeometry,
                            masks: $model.masks,
                            selectedID: $selectedMaskID
                        )
                        .frame(width: frame.size.width, height: frame.size.height)
                    } else {
                        // Keep the existing loupe for ordinary inspection.
                        InlineZoomPreview(
                            preview: image,
                            highResolutionURL: inlineHighResolutionURL,
                            resetToken: zoomResetToken,
                            zoomCommand: zoomCommand,
                            zoomDirection: zoomDirection,
                            maskEditing: false,
                            onNeedsHighResolution: { inspectFullResolution() }
                        )
                        .frame(width: frame.size.width, height: frame.size.height)
                        .id("source-\(model.photoSelectionVersion)-fit-\(zoomResetToken)")
                    }
                }
            } else {
                VStack(spacing: 13) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 49, weight: .ultraLight))
                        .foregroundStyle(DarkroomStyle.accent)
                    Text("让光线经过胶片")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(DarkroomStyle.primary)
                    Text("下方工具栏选择「图库」或「拍摄」")
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

                // Fixed overlay inside the photo surface. Changing exposure,
                // softness or halation must not insert/remove any row from
                // the lower editor ScrollView and shift its sliders.
                HStack {
                    Spacer()
                    Button {
                        model.applySettings()
                    } label: {
                        Label("应用调整", systemImage: "wand.and.stars")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DarkroomStyle.background)
                            .padding(.horizontal, 13)
                            .frame(height: 38)
                            .background(
                                DarkroomStyle.accent,
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy || model.isRendering || !model.hasPhoto)
                    .opacity(needsManualApply ? 1 : 0)
                    .allowsHitTesting(needsManualApply)
                    .accessibilityHidden(!needsManualApply)
                }
                .padding(.top, 8)

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
                    .disabled(!canExport || inlineHighResolutionURL != nil ||
                              editingMaskOnPhoto)
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
                    .disabled(model.processed == nil || editingMaskOnPhoto)
                    .opacity(editingMaskOnPhoto ? 0.30 : 1)
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

    /// The screenshot-inspired home selector shows all three choices in one
    /// vertical scroll, with small orange-marked swipeable cards.
    private var filmSection: some View {
        DarkroomPanel {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 7) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("胶片")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DarkroomStyle.primary)
                        Text(activeFilmName)
                            .font(.system(size: 11))
                            .foregroundStyle(DarkroomStyle.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Menu {
                        ForEach(FilmBrowseFilter.allCases, id: \.self) { option in
                            Button {
                                filmFilter = option
                            } label: {
                                if filmFilter == option {
                                    Label(option.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(option.rawValue)
                                }
                            }
                        }
                        Divider()
                        ForEach(FilmCatalog.films) { stock in
                            Button(stock.name) { model.selectFilm(stock.id) }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 15))
                            .frame(width: 30, height: 38)
                    }
                    .accessibilityLabel("胶片筛选与列表")
                    .disabled(model.isBusy || model.isRendering)
                    workflowTuneButton("胶片细调", group: .camera)
                }

                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 6) {
                            ForEach(filteredFilms) { stock in
                                WorkflowStockCard(
                                    stockName: stock.name,
                                    selected: model.filmID == stock.id,
                                    isPaper: false
                                ) {
                                    guard !model.isBusy && !model.isRendering else { return }
                                    model.selectFilm(stock.id)
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        reader.scrollTo(stock.id, anchor: .center)
                                    }
                                }
                                .id(stock.id)
                                .disabled(model.isBusy || model.isRendering)
                            }
                        }
                        .padding(.top, 5)
                        .padding(.bottom, 2)
                    }
                    .onAppear {
                        reader.scrollTo(model.filmID, anchor: .center)
                    }
                    .onChange(of: model.filmID) { id in
                        if filteredFilms.contains(where: { $0.id == id }) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                reader.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: filmFilter) { _ in
                        if filteredFilms.contains(where: { $0.id == model.filmID }) {
                            reader.scrollTo(model.filmID, anchor: .center)
                        }
                    }
                }
            }
        }
        .id("workflow-film")
    }

    private var paperSection: some View {
        DarkroomPanel {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 7) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("相纸")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DarkroomStyle.primary)
                        Text(activePaperName)
                            .font(.system(size: 11))
                            .foregroundStyle(DarkroomStyle.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Menu {
                        ForEach(PaperBrowseFilter.allCases, id: \.self) { option in
                            Button {
                                paperFilter = option
                            } label: {
                                if paperFilter == option {
                                    Label(option.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(option.rawValue)
                                }
                            }
                        }
                        Divider()
                        ForEach(FilmCatalog.papers) { stock in
                            Button(stock.name) {
                                guard !model.isBusy && !model.isRendering else { return }
                                model.paperID = stock.id
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 15))
                            .frame(width: 30, height: 38)
                    }
                    .accessibilityLabel("相纸筛选与列表")
                    .disabled(model.isBusy || model.isRendering)
                    workflowTuneButton("相纸细调", group: .print)
                }

                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 6) {
                            ForEach(filteredPapers) { stock in
                                WorkflowStockCard(
                                    stockName: stock.name,
                                    selected: model.paperID == stock.id,
                                    isPaper: true
                                ) {
                                    guard !model.isBusy && !model.isRendering,
                                          stock.id != model.paperID else { return }
                                    model.paperID = stock.id
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        reader.scrollTo(stock.id, anchor: .center)
                                    }
                                }
                                .id(stock.id)
                                .disabled(model.isBusy || model.isRendering)
                            }
                        }
                        .padding(.top, 5)
                        .padding(.bottom, 2)
                    }
                    .onAppear {
                        reader.scrollTo(model.paperID, anchor: .center)
                    }
                    .onChange(of: model.paperID) { id in
                        if filteredPapers.contains(where: { $0.id == id }) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                reader.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: paperFilter) { _ in
                        if filteredPapers.contains(where: { $0.id == model.paperID }) {
                            reader.scrollTo(model.paperID, anchor: .center)
                        }
                    }
                }
            }
        }
        .id("workflow-paper")
    }

    private func workflowTuneButton(_ label: String,
                                    group: AdjustmentGroup) -> some View {
        Button {
            adjustmentGroup = group
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = .adjust
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DarkroomStyle.accent)
                .frame(width: 34, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var filmEdgeChoiceSection: some View {
        DarkroomPanel {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("片边 · 日期")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DarkroomStyle.primary)
                        Text(filmEdgeWorkflowSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(DarkroomStyle.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 1)
                    workflowTuneButton("片边细调", group: .edge)
                    Button {
                        showingDateBackEditor = true
                    } label: {
                        Image(systemName: "calendar")
                            .font(.system(size: 15))
                            .foregroundStyle(model.filmEdge.dateBack.enabled
                                ? DarkroomStyle.accent : DarkroomStyle.secondary)
                            .frame(width: 29, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("日期后背设置")
                    Button {
                        showingSignatureEditor = true
                    } label: {
                        Image(systemName: "signature")
                            .font(.system(size: 17))
                            .foregroundStyle(model.filmEdge.signature.enabled
                                ? DarkroomStyle.accent : DarkroomStyle.secondary)
                            .frame(width: 29, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("签名设置")
                }
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 6) {
                            ForEach(WorkflowFilmEdgeChoice.allCases) { option in
                                WorkflowFilmEdgeCard(
                                    option: option,
                                    selected: WorkflowFilmEdgeChoice.current(model.filmEdge) == option
                                ) {
                                    guard !model.isBusy && !model.isRendering else { return }
                                    if option == .more {
                                        adjustmentGroup = .edge
                                        selectedTab = .adjust
                                    } else {
                                        model.setFilmEdge(option.applying(to: model.filmEdge))
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            reader.scrollTo(option.id, anchor: .center)
                                        }
                                    }
                                }
                                .id(option.id)
                                .disabled(model.isBusy || model.isRendering)
                            }
                        }
                        .padding(.top, 5)
                        .padding(.bottom, 2)
                    }
                    .onAppear {
                        reader.scrollTo(
                            WorkflowFilmEdgeChoice.current(model.filmEdge).id,
                            anchor: .center
                        )
                    }
                    .onChange(of: model.filmEdge) { next in
                        let option = WorkflowFilmEdgeChoice.current(next)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            reader.scrollTo(option.id, anchor: .center)
                        }
                    }
                }
            }
        }
        .id("workflow-edge")
    }

    private var filmEdgeWorkflowSummary: String {
        let edge = model.filmEdge.enabled
            ? (model.filmEdge.view == .filed ? "归档页" :
               model.filmEdge.format.label)
            : "无片边"
        let dateStatus = model.filmEdge.dateBack.enabled ? "日期开启" : "日期关闭"
        let signStatus = model.filmEdge.signature.enabled &&
                         model.filmEdge.signature.hasInk ? "签名开启" : "签名关闭"
        return edge + " · " + dateStatus + " · " + signStatus
    }

    private func showUnportedWorkflowFeature(_ title: String,
                                            description: String) {
        pendingWorkflowFeatureTitle = title
        pendingWorkflowFeatureDescription = description
        showingPendingWorkflowFeature = true
    }

    private var workflowSelectionPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            filmSection
            paperSection
            filmEdgeChoiceSection
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
                            label: "数码柔化", value: $model.softness,
                            range: 0...1, step: 0.05, suffix: "",
                            disabled: model.isBusy
                        )
                        DarkroomControlRow(
                            label: "光晕面积", value: $model.halationAmount,
                            range: 0...3, step: 0.1, suffix: "×",
                            disabled: model.isBusy
                        )
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
                            label: "冲印亮度", value: printBrightnessStops,
                            range: -3...3, step: 0.1, suffix: " EV",
                            disabled: model.isBusy
                        )
                        DarkroomControlRow(
                            label: "M 滤色", value: $model.magentaShift,
                            range: -0.5...0.5, step: 0.05, suffix: "",
                            disabled: model.isBusy
                        )
                        DarkroomControlRow(
                            label: "Y 滤色", value: $model.yellowShift,
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        showingStartupSettings = true
                    } label: {
                        Label("启动设置", systemImage: "gearshape")
                    }
                    Spacer(minLength: 6)
                    Button { copyStatus() } label: {
                        Label("复制诊断", systemImage: "doc.on.doc")
                    }
                }
                .font(.system(size: 11))
                .buttonStyle(.bordered)
                .tint(DarkroomStyle.accent)
                Button {
                    showingRAWFileImporter = true
                } label: {
                    Label("导入 RAW 相机文件（RAF / DNG / NEF 等）",
                          systemImage: "doc.badge.plus")
                }
                .font(.system(size: 12))
                .buttonStyle(.bordered)
                .tint(DarkroomStyle.accent)
                .disabled(model.isBusy || model.isRendering)
                DisclosureGroup(isExpanded: $exportExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        shareFullResolutionToApps()
                    } label: {
                        Label("分享到微信 / 其他 App", systemImage: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DarkroomStyle.accent)
                    .disabled(!canExport)

                    Text("打开 iOS 系统分享面板；微信等目标以设备实际可用的分享扩展为准。")
                        .font(.system(size: 10))
                        .foregroundStyle(DarkroomStyle.secondary)

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

    /// One always-visible editor row. All nine controls share the available
    /// width: two photo sources, six tool sections and direct system sharing.
    /// The touch height remains 48pt; labels/icons are only visually smaller.
    private func compactNavLabel(_ title: String, icon: String,
                                 active: Bool = false) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
            Text(title)
                .font(.system(size: 9, weight: active ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(active ? DarkroomStyle.background : DarkroomStyle.primary)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(active ? DarkroomStyle.accent : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private var editorSections: some View {
        HStack(spacing: 1) {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                compactNavLabel("图库", icon: "photo.on.rectangle")
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.isRendering)
            .accessibilityLabel("图库导入照片")

            Button {
                openCamera()
            } label: {
                compactNavLabel("拍摄", icon: "camera")
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.isRendering)
            .accessibilityLabel("打开相机")

            ForEach([EditorTab.film, .paper, .adjust, .grade, .presets, .export],
                    id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    compactNavLabel(tab.rawValue, icon: tab.symbol,
                                    active: selectedTab == tab)
                }
                .buttonStyle(.plain)
            }

            Button {
                shareFullResolutionToApps()
            } label: {
                compactNavLabel("分享", icon: "square.and.arrow.up")
                    .opacity(canExport ? 1 : 0.35)
            }
            .buttonStyle(.plain)
            .disabled(!canExport)
            .accessibilityLabel("分享到其他 App")
        }
        .padding(3)
        .background(DarkroomStyle.surface, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
    }

    private var rawDevelopControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let options = model.rawOptions, let asShot = model.rawAsShot {
                HStack(spacing: 6) {
                    Text("相机 RAW 显影")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DarkroomStyle.primary)
                    Spacer()
                    Text(model.capturedFormat)
                        .font(.system(size: 10))
                        .foregroundStyle(DarkroomStyle.secondary)
                }
                Toggle("As Shot · 相机原始白平衡", isOn: Binding(
                    get: { model.rawOptions?.useAsShot ?? true },
                    set: { v in
                        guard var p = model.rawOptions else { return }
                        p.useAsShot = v
                        model.changeRAWOptions(p)
                    }
                ))
                .font(.system(size: 11))
                .tint(DarkroomStyle.accent)
                .disabled(model.isBusy)
                HStack {
                    Text(String(format: "相机：%.0f K · 色调 %+.0f",
                                asShot.temperature, asShot.tint))
                        .font(.system(size: 10))
                        .foregroundStyle(DarkroomStyle.secondary)
                    Spacer()
                    Button("恢复相机值") {
                        var p = options
                        p.useAsShot = true
                        p.temperature = asShot.temperature
                        p.tint = asShot.tint
                        model.changeRAWOptions(p)
                    }
                    .font(.system(size: 10))
                    .disabled(model.isBusy)
                }
                if !options.useAsShot {
                    DarkroomControlRow(
                        label: "RAW 色温",
                        value: Binding(
                            get: { model.rawOptions?.temperature ?? 5500 },
                            set: { newValue in
                                guard var p = model.rawOptions else { return }
                                p.temperature = newValue
                                model.changeRAWOptions(p)
                            }),
                        range: 2000...12000, step: 100, suffix: " K",
                        disabled: model.isBusy
                    )
                    DarkroomControlRow(
                        label: "RAW 色调",
                        value: Binding(
                            get: { model.rawOptions?.tint ?? 0 },
                            set: { newValue in
                                guard var p = model.rawOptions else { return }
                                p.tint = newValue
                                model.changeRAWOptions(p)
                            }),
                        range: -150...150, step: 1, suffix: "",
                        disabled: model.isBusy
                    )
                }
                Toggle("RAW 镜头修正", isOn: Binding(
                    get: { model.rawOptions?.lensCorrection ?? false },
                    set: { enabled in
                        guard var p = model.rawOptions else { return }
                        p.lensCorrection = enabled
                        model.changeRAWOptions(p)
                    }
                ))
                .font(.system(size: 11))
                .tint(DarkroomStyle.accent)
                .disabled(model.isBusy || !asShot.lensCorrectionSupported)
                Text("白平衡在胶片模拟之前完成；色温/色调修改需重新解码 RAW。")
                    .font(.system(size: 10))
                    .foregroundStyle(DarkroomStyle.secondary)
            } else {
                Button {
                    showingRAWFileImporter = true
                } label: {
                    Label("导入相机 RAW 文件", systemImage: "doc.badge.plus")
                }
                .font(.system(size: 11))
                .buttonStyle(.bordered)
                .tint(DarkroomStyle.accent)
                .disabled(model.isBusy || model.isRendering)
                Text("RAF / DNG / NEF / ARW / CR3 等；以 iOS 系统支持的相机型号为准。")
                    .font(.system(size: 10))
                    .foregroundStyle(DarkroomStyle.secondary)
            }
        }
    }

    private var quickAdjustmentPanel: some View {
        DarkroomPanel {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("实时光谱调节")
                        .font(.system(size: 13, weight: .semibold))
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

                VStack(spacing: 0) {
                    if adjustmentGroup == .edge {
                        MobileFilmEdgeEditor(
                            settings: filmEdgeBinding,
                            disabled: model.isBusy || model.isRendering
                        )
                    } else if adjustmentGroup == .geometry {
                        PhotoGeometryControls(
                            geometry: photoGeometryBinding,
                            imageSize: model.cropEditingImage?.size ?? CGSize(width: 3, height: 2),
                            disabled: model.isBusy || model.isRendering
                        )
                    } else if adjustmentGroup == .camera {
                        rawDevelopControls
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
                    } else if adjustmentGroup == .print {
                        DarkroomControlRow(
                            label: "冲印亮度", value: printBrightnessStops,
                            range: -3...3, step: 0.1, suffix: " EV",
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
                if adjustmentGroup != .geometry && adjustmentGroup != .edge {
                DisclosureGroup(isExpanded: $showingQuickHelp) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("数码柔化：0 为原始锐度；1 为减弱边缘反差，不恢复 JPEG 丢失细节。")
                        Text("光晕面积：0 关闭；1 为胶片默认，夜间点光源更明显。")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(DarkroomStyle.secondary)
                } label: {
                    Label("参数说明", systemImage: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(DarkroomStyle.secondary)
                }
                .tint(DarkroomStyle.secondary)

                if model.realtimeEnabled {
                    Text("移动滑块后约 0.24 秒合并更新，复用原版负片缓存。")
                        .font(.system(size: 10))
                        .foregroundStyle(DarkroomStyle.secondary)
                } else {
                    Text("实时预览已关闭。使用预览区「应用调整」应用参数。")
                        .font(.system(size: 10))
                        .foregroundStyle(DarkroomStyle.secondary)
                }
                }
            }
        }
    }

    /// The actual macOS Layer 2 adjustment model and GPU kernel. These
    /// are post-print controls, not substitutes for film exposure/grain.
    private var desktopGradePanel: some View {
        DarkroomPanel {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("桌面同源 · 调色")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DarkroomStyle.primary)
                    Spacer()
                    Button("全部复位") {
                        model.grade = .default
                        model.masks = []
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DarkroomStyle.accent)
                }

                Picker("调色分组", selection: $gradeSubsection) {
                    ForEach(GradeSubsection.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                if gradeSubsection == .basic {
                DarkroomControlRow(
                    label: "扫描后曝光", value: $model.grade.exposure,
                    range: -3...3, step: 0.1, suffix: " EV",
                    disabled: model.isBusy
                )
                DarkroomControlRow(
                    label: "扫描色温", value: $model.grade.temperature,
                    range: -100...100, step: 1, suffix: "",
                    disabled: model.isBusy
                )
                DarkroomControlRow(
                    label: "扫描色调", value: $model.grade.tint,
                    range: -100...100, step: 1, suffix: "",
                    disabled: model.isBusy
                )
                DarkroomControlRow(
                    label: "对比度", value: $model.grade.contrast,
                    range: -50...50, step: 1, suffix: "",
                    disabled: model.isBusy
                )
                DarkroomControlRow(
                    label: "亮度", value: $model.grade.brightness,
                    range: -50...50, step: 1, suffix: "",
                    disabled: model.isBusy
                )
                DarkroomControlRow(
                    label: "饱和度", value: $model.grade.saturation,
                    range: -100...100, step: 1, suffix: "",
                    disabled: model.isBusy
                )
                DarkroomControlRow(
                    label: "高光", value: $model.grade.highlights,
                    range: -100...100, step: 1, suffix: "",
                    disabled: model.isBusy
                )
                DarkroomControlRow(
                    label: "阴影", value: $model.grade.shadows,
                    range: -100...100, step: 1, suffix: "",
                    disabled: model.isBusy
                )
                DarkroomControlRow(
                    label: "黑场", value: $model.grade.blackPoint,
                    range: 0...50, step: 1, suffix: "",
                    disabled: model.isBusy
                )
                DarkroomControlRow(
                    label: "白场", value: $model.grade.whitePoint,
                    range: 0...50, step: 1, suffix: "",
                    disabled: model.isBusy
                )
                DarkroomControlRow(
                    label: "暗角", value: $model.grade.vignette.amount,
                    range: -100...100, step: 1, suffix: "",
                    disabled: model.isBusy
                )
                DarkroomControlRow(
                    label: "暗角范围", value: $model.grade.vignette.midpoint,
                    range: 0...100, step: 1, suffix: "",
                    disabled: model.isBusy
                )
                } else if gradeSubsection == .curves {
                    MobileCurveEditor(curves: $model.grade.curves)
                } else if gradeSubsection == .balance {
                    MobileColorBalanceEditor(colorBalance: $model.grade.colorBalance)
                } else {
                    MobileLocalMaskEditor(
                        masks: $model.masks,
                        selectedID: $selectedMaskID
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var activePanel: some View {
        switch selectedTab {
        case .film, .paper: workflowSelectionPanel
        case .adjust: quickAdjustmentPanel
        case .grade: desktopGradePanel
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
                        .frame(height: (selectedTab == .film || selectedTab == .paper)
                            ? max(150, min(242, geometry.size.height * 0.30))
                            : max(220, geometry.size.height * 0.51))
                        .overlay(alignment: .top) {
                            if let activeSliderReadout {
                                Text(activeSliderReadout)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(DarkroomStyle.primary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(.black.opacity(0.78), in: Capsule())
                                    .padding(.top, 16)
                                    .allowsHitTesting(false)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .padding(.bottom, 2)

                    editorSections
                        .alert("RAW 导入失败", isPresented: Binding(
                            get: { model.rawImportError != nil },
                            set: { if !$0 { model.rawImportError = nil } }
                        )) {
                            Button("好", role: .cancel) { model.rawImportError = nil }
                        } message: {
                            Text(model.rawImportError ?? "请检查所选文件后重试。")
                        }

                    ScrollViewReader { chooser in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 10) {
                                activePanel
                                if selectedTab != .film && selectedTab != .paper {
                                    statusSection
                                }
                            }
                            .padding(.horizontal, 13)
                            .padding(.bottom, 18)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DarkroomStyle.background)
                        .onChange(of: selectedTab) { tab in
                            if (tab == .film || tab == .paper),
                               geometry.size.height < 640 {
                                // Only scroll a short viewport. On standard
                                // iPhones all three groups remain visible.
                                let destination = tab == .paper
                                    ? "workflow-paper" : "workflow-film"
                                DispatchQueue.main.async {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        chooser.scrollTo(destination, anchor: .top)
                                    }
                                }
                            }
                        }
                        .onPreferenceChange(CompactSliderReadoutKey.self) { readout in
                            activeSliderReadout = readout
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(DarkroomStyle.background.ignoresSafeArea())
            // Keep iOS status bar; remove the entire empty navigation bar.
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: selectedPhoto) {
                clearInlineHighResolution()
                photoSaveFeedback = ""
                model.importPhoto($0)
                selectedTab = .film
            }
            .onChange(of: model.photoSelectionVersion) { _ in
                clearInlineHighResolution()
                fitWholePhoto()
                selectedMaskID = nil
                photoSaveFeedback = ""
            }
            .onChange(of: model.previewSequence) { _ in
                showPreviousFilm = false
                clearInlineHighResolution()
                // LocalMaskCanvas does not own or restore a zoom state.
                // Keep its gesture/viewport identity stable across renders.
                if !editingMaskOnPhoto { fitWholePhoto() }
            }
            .onChange(of: selectedTab) { _ in
                enterMaskEditingIfNeeded()
                if editingCropOnPhoto { clearInlineHighResolution(); fitWholePhoto() }
            }
            .onChange(of: adjustmentGroup) { _ in
                if editingCropOnPhoto { clearInlineHighResolution(); fitWholePhoto() }
            }
            .onChange(of: gradeSubsection) { _ in
                enterMaskEditingIfNeeded()
            }
            .onChange(of: model.compare) { isComparing in
                if !isComparing { enterMaskEditingIfNeeded() }
            }
            .onChange(of: showPreviousFilm) { showingPrevious in
                if !showingPrevious { enterMaskEditingIfNeeded() }
            }
            .onChange(of: model.paperID) { _ in model.markDirty() }
            .onChange(of: model.exposureEV) { _ in model.markDirty() }
            .onChange(of: model.grainAmount) { _ in model.markDirty() }
            .onChange(of: model.halationAmount) { _ in model.markDirty() }
            .onChange(of: model.printExposure) { _ in model.markDirty() }
            .onChange(of: model.magentaShift) { _ in model.markDirty() }
            .onChange(of: model.yellowShift) { _ in model.markDirty() }
            .onChange(of: model.softness) { _ in model.markDirty() }
            .onChange(of: model.grade) { _ in model.markDirty() }
            .onChange(of: model.masks) { _ in model.markDirty() }
            .onAppear {
                model.onSuccessfulRender = { [weak presetStore] settings in
                    presetStore?.recordUse(settings)
                }
                guard !hasHandledStartup else { return }
                hasHandledStartup = true
                if launchCameraOnFirstAppear {
                    // Schedule after the first SwiftUI hierarchy pass so the
                    // native UIKit camera is presented from a mounted view.
                    DispatchQueue.main.async {
                        openCamera()
                    }
                }
            }
            .alert(pendingWorkflowFeatureTitle,
                   isPresented: $showingPendingWorkflowFeature) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(pendingWorkflowFeatureDescription)
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
            .sheet(isPresented: $showingStartupSettings) {
                StartupSettingsView()
            }
            .sheet(isPresented: $showingDateBackEditor) {
                NavigationStack {
                    MobileDateBackEditor(
                        settings: dateBackBinding,
                        panoramic: model.filmEdge.enabled &&
                            (model.filmEdge.format == .xpan ||
                             model.filmEdge.format == .f6x12 ||
                             model.filmEdge.format == .f6x17))
                    .navigationTitle("日期后背")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingDateBackEditor = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingSignatureEditor) {
                NavigationStack {
                    MobileSignatureEditor(settings: signatureBinding)
                        .navigationTitle("签名")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showingSignatureEditor = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .fileImporter(
                isPresented: $showingRAWFileImporter,
                allowedContentTypes: [.item]
            ) { selected in
                switch selected {
                case let .success(url):
                    clearInlineHighResolution()
                    model.importRAWFile(url)
                    selectedTab = .film
                    adjustmentGroup = .camera
                case let .failure(error):
                    let nsError = error as NSError
                    guard nsError.domain != NSCocoaErrorDomain ||
                            nsError.code != NSUserCancelledError else { return }
                    let message = "文件选择失败：" + error.localizedDescription
                    model.status = message
                    model.rawImportError = message
                }
            }
            .fullScreenCover(isPresented: $showingCamera, onDismiss: {
                if let capture = pendingCapture {
                    pendingCapture = nil
                    model.importCameraCapture(capture)
                    selectedTab = .film
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
