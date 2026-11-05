import Metal
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class EditorModel: ObservableObject {
    @Published var original: UIImage?
    @Published var processed: UIImage?
    @Published var status = "选择一张照片，以原版光谱引擎进行胶片模拟。"
    @Published var isBusy = false
    @Published var compare = false

    private let renderer = SpectralRenderer()

    func importPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        isBusy = true
        status = "正在读取照片…"
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw PortError.message("照片读取失败")
                }
                status = "原版光谱引擎正在渲染…"
                renderer.render(data: data) { [weak self] response in
                    guard let self else { return }
                    self.isBusy = false
                    switch response {
                    case let .success(output):
                        self.original = output.original
                        self.processed = output.processed
                        self.status = "Kodak Portra 400 · 原版 SpektraLab 引擎 · 实际渲染"
                    case let .failure(error):
                        self.status = "引擎错误：\(error.localizedDescription)"
                    }
                }
            } catch {
                isBusy = false
                status = "读取失败：\(error.localizedDescription)"
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
        Bundle identifier: \(Bundle.main.bundleIdentifier ?? "unknown")
        """
        UIPasteboard.general.string = report
        copiedStatus = true
    }

    var body: some View {
        NavigationStack {
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
                        VStack(spacing: 18) {
                            Image(systemName: "camera.filters")
                                .font(.system(size: 56, weight: .ultraLight))
                            Text("原版光谱胶片模拟")
                                .font(.headline)
                            Text("81 波长 · C++20 · Metal")
                                .font(.footnote)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

                if model.isBusy {
                    ProgressView().controlSize(.large)
                }
                Text(model.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 38)

                HStack(spacing: 16) {
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
            }
            .padding()
            .navigationTitle("SpectraPort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        onBack()
                    } label: {
                        Label("返回诊断", systemImage: "chevron.left")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(copiedStatus ? "已复制" : "复制状态") {
                        copyStatus()
                    }
                }
            }
            .onChange(of: selectedPhoto) { newValue in
                model.importPhoto(newValue)
            }
        }
    }
}
