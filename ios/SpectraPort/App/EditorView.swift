import Metal
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class EditorModel: ObservableObject {
    @Published var original: UIImage?
    @Published var processed: UIImage?
    @Published var status = "请选择照片，然后调整真实的胶片／相纸参数。"
    @Published var isBusy = false
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

    var hasPhoto: Bool { sourceData != nil }
    private let renderer = SpectralRenderer()

    func markDirty() {
        guard sourceData != nil else { return }
        isDirty = true
        if !isBusy { status = "参数已修改，点击「应用设置」重新渲染" }
    }

    func selectFilm(_ id: String) {
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
        guard let item, !isBusy else { return }
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
        guard let data = sourceData, processed != nil, !isBusy else {
            status = "请先选择照片并完成预览"
            return
        }
        guard !isDirty else {
            status = "请先应用未渲染的参数"
            return
        }
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
        guard let data = sourceData, !isBusy else { return }
        guard !FilmCatalog.films.isEmpty, !FilmCatalog.papers.isEmpty else {
            status = "找不到原版胶片或相纸资源，无法执行模拟"
            return
        }
        let settings = snapshot()
        isDirty = false
        isBusy = true
        status = "正在使用原版光谱引擎渲染…"
        renderer.render(data: data, photoID: photoID, settings: settings) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            switch result {
            case let .success(photo):
                self.original = photo.original
                self.processed = photo.processed
                self.lastElapsedMS = photo.elapsedMS
                self.status = "\(FilmCatalog.filmName(settings.filmStock)) · \(FilmCatalog.paperName(settings.printStock)) · 已渲染"
            case let .failure(error):
                self.lastElapsedMS = nil
                self.isDirty = true
                self.status = "引擎错误：\(error.localizedDescription)"
            }
        }
    }
}

struct EditorView: View {
    let onBack: () -> Void

    @StateObject private var model = EditorModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var copiedStatus = false
    @State private var shareItem: ShareItem?

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
        Bundle identifier: \(Bundle.main.bundleIdentifier ?? "unknown")
        """
        UIPasteboard.general.string = report
        copiedStatus = true
    }

    private func exportPreview(_ format: PreviewExporter.Format) {
        guard let image = model.processed, !model.isBusy, !model.isDirty else {
            model.status = "请先应用全部设置，然后再导出"
            return
        }
        do {
            shareItem = ShareItem(url: try PreviewExporter.write(image, format: format))
        } catch {
            model.status = "导出预览失败：\(error.localizedDescription)"
        }
    }

    private func exportOriginal(_ format: PreviewExporter.Format) {
        model.exportOriginal(format: format) { result in
            if case let .success(output) = result {
                shareItem = ShareItem(url: output.url)
            }
        }
    }

    private func sliderRow(_ name: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double,
                           suffix: String = "") -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(name).font(.subheadline)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue) + suffix)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .disabled(model.isBusy)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Group {
                        if let image = model.compare ? model.original : model.processed {
                            GeometryReader { geometry in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                            }
                        } else {
                            VStack(spacing: 14) {
                                Image(systemName: "camera.filters")
                                    .font(.system(size: 48, weight: .ultraLight))
                                Text("原版光谱胶片模拟")
                                    .font(.headline)
                                Text("C++20 · Metal · iOS 16")
                                    .font(.footnote)
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(height: min(UIScreen.main.bounds.height * 0.43, 400))
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

                    HStack(spacing: 12) {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("选择照片", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)

                        Button(model.compare ? "查看模拟" : "查看原图") {
                            model.compare.toggle()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.processed == nil || model.isBusy)
                    }

                    Menu {
                        Button("导出 JPEG（sRGB）") { exportPreview(.jpeg) }
                        Button("导出 PNG（sRGB）") { exportPreview(.png) }
                    } label: {
                        Label("分享／保存当前预览（最长边 1440px）", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.isBusy || model.isDirty || model.processed == nil)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("高清导出").font(.headline)
                        Picker("分辨率与内存保护", selection: $model.exportLimit) {
                            ForEach(ExportLimit.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.isBusy)
                        HStack(spacing: 12) {
                            Button("高清 JPEG") { exportOriginal(.jpeg) }
                            Button("高清 PNG") { exportOriginal(.png) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.isDirty || model.processed == nil)
                        Text("超出像素上限会降采样；此导出独立运行原版 full 层级，不会拉伸预览图。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if model.isBusy {
                        ProgressView(model.exportPhase.isEmpty ? "原版引擎处理中…" : model.exportPhase)
                    }
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 30)
                    if FilmCatalog.films.isEmpty || FilmCatalog.papers.isEmpty {
                        Text("原版胶片或相纸配置加载失败，请复制状态反馈。")
                            .font(.footnote).foregroundStyle(.red)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("原版胶片与相纸").font(.headline)
                        Picker("胶片", selection: $model.filmID) {
                            ForEach(FilmCatalog.films) { stock in
                                Text(stock.name).tag(stock.id)
                            }
                        }
                        .disabled(model.isBusy || FilmCatalog.films.isEmpty)
                        Picker("相纸", selection: $model.paperID) {
                            ForEach(FilmCatalog.papers) { stock in
                                Text(stock.name).tag(stock.id)
                            }
                        }
                        .disabled(model.isBusy || FilmCatalog.papers.isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 12) {
                        sliderRow("相机曝光补偿", value: $model.exposureEV, range: -3...3, step: 0.1, suffix: " EV")
                        sliderRow("胶片颗粒", value: $model.grainAmount, range: 0...2, step: 0.1, suffix: "×")
                        sliderRow("光晕强度", value: $model.halationAmount, range: 0...3, step: 0.1, suffix: "×")
                        sliderRow("相纸曝光", value: $model.printExposure, range: 0.2...3, step: 0.05, suffix: "×")
                        sliderRow("放大机 M 滤色偏移", value: $model.magentaShift, range: -0.5...0.5, step: 0.05)
                        sliderRow("放大机 Y 滤色偏移", value: $model.yellowShift, range: -0.5...0.5, step: 0.05)
                    }
                    Button {
                        model.applySettings()
                    } label: {
                        Label(model.isDirty ? "应用设置（有未渲染修改）" : "重新渲染", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.filmID.isEmpty || model.paperID.isEmpty || !model.hasPhoto)

                    Text("胶片／相纸与参数均由原版引擎计算。调整后点击应用；可导出 1440px 的 JPEG/PNG 预览。高清导出支持最高 12.5MP，超出会降采样以保护内存。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("SpectraPort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onBack) {
                        Label("返回诊断", systemImage: "chevron.left")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(copiedStatus ? "已复制" : "复制状态") { copyStatus() }
                }
            }
            .onChange(of: selectedPhoto) { newValue in model.importPhoto(newValue) }
            .onChange(of: model.filmID) { model.selectFilm($0) }
            .onChange(of: model.paperID) { _ in model.markDirty() }
            .onChange(of: model.exposureEV) { _ in model.markDirty() }
            .onChange(of: model.grainAmount) { _ in model.markDirty() }
            .onChange(of: model.halationAmount) { _ in model.markDirty() }
            .onChange(of: model.printExposure) { _ in model.markDirty() }
            .onChange(of: model.magentaShift) { _ in model.markDirty() }
            .onChange(of: model.yellowShift) { _ in model.markDirty() }
            .sheet(item: $shareItem) { item in
                PreviewShareSheet(url: item.url)
            }
        }
    }
}
