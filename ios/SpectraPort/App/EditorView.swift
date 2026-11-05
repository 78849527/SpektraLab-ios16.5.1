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
                isBusy = false
                applySettings()
            } catch {
                isBusy = false
                status = "照片读取失败：\(error.localizedDescription)"
            }
        }
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
        renderer.render(data: data, settings: settings) { [weak self] result in
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
        Exposure EV: \(model.exposureEV)
        Grain amount: \(model.grainAmount)
        Halation amount: \(model.halationAmount)
        Print exposure: \(model.printExposure)
        Magenta shift: \(model.magentaShift)
        Yellow shift: \(model.yellowShift)
        Engine render ms: \(model.lastElapsedMS.map { String(format: "%.1f", $0) } ?? "N/A")
        Pending edits: \(model.isDirty)
        Bundle identifier: \(Bundle.main.bundleIdentifier ?? "unknown")
        """
        UIPasteboard.general.string = report
        copiedStatus = true
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

                    if model.isBusy { ProgressView("原版引擎处理中…") }
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
                    .disabled(model.isBusy || model.filmID.isEmpty || model.paperID.isEmpty || model.processed == nil)

                    Text("胶片／相纸与参数均由原版引擎计算。调整后点击应用，预览最长边 1440px；尚未支持全分辨率导出。")
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
        }
    }
}
