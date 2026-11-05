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

    private var sourceData: Data?
    private var photoID = UUID()
    private var debounceTask: Task<Void, Never>?
    private var previewInFlight = false
    private var requestVersion = 0

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
        markDirty()
        status = hasPhoto ? "已载入参数，点击「应用设置」渲染" : "预设已载入，选择照片后应用"
    }

    func restoreDefaults() {
        loadLook(FilmSettings(
            filmStock: "kodak_portra_400",
            printStock: "kodak_portra_endura",
            exposureEV: 0, grainAmount: 1, halationAmount: 1,
            printExposure: 1, magentaShift: 0, yellowShift: 0
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
                    self.original = photo.original
                    self.processed = photo.processed
                    self.lastElapsedMS = photo.elapsedMS
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
            magentaShift: magentaShift, yellowShift: yellowShift
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
                sourceData = data
                photoID = UUID()
                isBusy = false
                applySettings()
            } catch {
                isBusy = false
                status = "照片读取失败：\(error.localizedDescription)"
            }
        }
    }

    func exportOriginal(
        format: PreviewExporter.Format,
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
            data: data, settings: settings, format: format, limit: exportLimit,
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

struct EditorView: View {
    let onBack: () -> Void

    @StateObject private var model = EditorModel()
    @StateObject private var presetStore = PresetStore()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showSavePreset = false
    @State private var newPresetName = ""
    @State private var copiedStatus = false
    @State private var shareItem: ShareItem?
    @State private var mostRecentExport: ShareItem?
    @State private var mostRecentExportLabel = ""

    @State private var filmFilter: FilmBrowseFilter = .all
    @State private var cameraExpanded = true
    @State private var darkroomExpanded = false
    @State private var presetsExpanded = false
    @State private var exportExpanded = false
    @State private var selectedTab: EditorTab = .adjust
    @State private var adjustmentGroup: AdjustmentGroup = .camera

    private var filteredFilms: [FilmCatalog.Stock] {
        FilmCatalog.films.filter { filmFilter.accepts($0) }
    }

    private var canExport: Bool {
        !model.isBusy && !model.isRendering && !model.isDirty && model.processed != nil
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
        Film: \(model.filmID)
        Paper: \(model.paperID)
        Exposure EV: \(String(format: "%.2f", model.exposureEV))
        Grain amount: \(String(format: "%.2f", model.grainAmount))
        Halation amount: \(String(format: "%.2f", model.halationAmount))
        Print exposure: \(String(format: "%.2f", model.printExposure))
        Magenta shift: \(String(format: "%.2f", model.magentaShift))
        Yellow shift: \(String(format: "%.2f", model.yellowShift))
        Engine render ms: \(model.lastElapsedMS.map { String(format: "%.1f", $0) } ?? "N/A")
        Engine: persistent session, spk_reprint
        Pending edits: \(model.isDirty)
        High-res limit: \(model.exportLimit.rawValue)
        Last high-res export: \(model.lastExportInfo)
        Saved presets: \(presetStore.presets.count)
        Recent combinations: \(presetStore.recentPairs.count)
        UI: darkroom v0.8 top-tabs
        Live preview: (model.realtimeEnabled)
        Live rendering: (model.isRendering)
        Live debounce: 240 ms
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

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("THE DARKROOM")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2.8)
                    .foregroundStyle(DarkroomStyle.accent)
                Spacer()
                Text("SPECTRAL FILM / iOS")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(DarkroomStyle.secondary)
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black)

                Group {
                    if let image = model.compare ? model.original : model.processed {
                        GeometryReader { g in
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: g.size.width, height: g.size.height)
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "camera.aperture")
                                .font(.system(size: 48, weight: .ultraLight))
                                .foregroundStyle(DarkroomStyle.accent)
                            Text("让光线经过胶片")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(DarkroomStyle.primary)
                            Text("导入照片，使用原版光谱引擎冲印")
                                .font(.system(size: 11))
                                .foregroundStyle(DarkroomStyle.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(model.compare ? "ORIGINAL" : "FILM PREVIEW")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(DarkroomStyle.primary.opacity(0.9))
                    .padding(8)
                    .background(Color.black.opacity(0.65), in: Capsule())
                    .padding(12)
            }
            .frame(height: min(UIScreen.main.bounds.height * (selectedTab == .adjust ? 0.255 : 0.31), 275))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(DarkroomStyle.line))

            HStack(spacing: 10) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label(model.hasPhoto ? "更换照片" : "选择照片", systemImage: "photo.on.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(DarkroomStyle.accent)
                .disabled(model.isBusy || model.isRendering)

                Button {
                    model.compare.toggle()
                } label: {
                    Label(model.compare ? "显示效果" : "对比原图", systemImage: "square.on.square")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(DarkroomStyle.accent)
                .disabled(model.processed == nil || model.isBusy)
            }
        }
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
            VStack(alignment: .leading, spacing: 11) {
                DarkroomSectionTitle(number: "02", title: "相纸", subtitle: "下拉选择")
                Menu {
                    ForEach(FilmCatalog.papers) { stock in
                        Button {
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
                    HStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(DarkroomStyle.accent)
                        Text(activePaperName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DarkroomStyle.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(DarkroomStyle.accent)
                    }
                    .padding(13)
                    .background(DarkroomStyle.raised, in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(model.isBusy)
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
                            label: "光晕强度", value: $model.halationAmount,
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

    private var tabs: some View {
        HStack(spacing: 3) {
            ForEach(EditorTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 15, weight: .medium))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .medium))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(selectedTab == tab ? DarkroomStyle.accent : Color.clear)
                            .frame(height: 2)
                    }
                    .foregroundStyle(selectedTab == tab ? DarkroomStyle.accent : DarkroomStyle.secondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue + "菜单")
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 9)
        .padding(.bottom, 6)
        .background(DarkroomStyle.surface)
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
                            label: "光晕强度", value: $model.halationAmount,
                            range: 0...3, step: 0.1, suffix: "×",
                            disabled: model.isBusy
                        )
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

    private var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isRendering ? "渲染中" : (model.isDirty ? "待更新" : "光谱引擎"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.isDirty ? DarkroomStyle.accent : DarkroomStyle.primary)
                Text(model.lastElapsedMS.map { String(format: "%.0f ms", $0) } ?? "81 波长 · Metal")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DarkroomStyle.secondary)
            }
            .frame(minWidth: 94, alignment: .leading)

            Button {
                model.applySettings()
            } label: {
                HStack(spacing: 8) {
                    if model.isBusy {
                        ProgressView().tint(DarkroomStyle.background)
                    } else {
                        Image(systemName: model.isDirty ? "wand.and.stars" : "arrow.clockwise")
                    }
                    Text(model.isDirty ? "立即预览" : "重新渲染")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DarkroomStyle.background)
            .background(
                model.isBusy ? DarkroomStyle.secondary : DarkroomStyle.accent,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .disabled(model.isBusy || model.isRendering || !model.hasPhoto || model.filmID.isEmpty || model.paperID.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            DarkroomStyle.background
                .overlay(alignment: .top) { DarkroomStyle.line.frame(height: 1) }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabs

                previewSection
                    .padding(.horizontal, 15)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        activePanel
                        statusSection
                    }
                    .padding(.horizontal, 15)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                }
            }
            .background(DarkroomStyle.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .navigationTitle("SpectraPort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onBack) {
                        Label("返回诊断", systemImage: "chevron.left")
                    }
                    .foregroundStyle(DarkroomStyle.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(copiedStatus ? "已复制" : "复制状态") { copyStatus() }
                        .foregroundStyle(DarkroomStyle.accent)
                }
            }
            .toolbarBackground(DarkroomStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: selectedPhoto) { model.importPhoto($0) }
            .onChange(of: model.paperID) { _ in model.markDirty() }
            .onChange(of: model.exposureEV) { _ in model.markDirty() }
            .onChange(of: model.grainAmount) { _ in model.markDirty() }
            .onChange(of: model.halationAmount) { _ in model.markDirty() }
            .onChange(of: model.printExposure) { _ in model.markDirty() }
            .onChange(of: model.magentaShift) { _ in model.markDirty() }
            .onChange(of: model.yellowShift) { _ in model.markDirty() }
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
        }
        .preferredColorScheme(.dark)
    }
}
