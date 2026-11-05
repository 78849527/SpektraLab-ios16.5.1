import Metal
import SwiftUI
import UIKit

/// A lightweight, visible launch checkpoint for older iPhones.
/// If this screen is visible, app launch and SwiftUI scene creation worked.
struct DiagnosticHomeView: View {
    @State private var showEditor = false
    @State private var metalStatus = "未检测"
    @State private var copied = false

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    private var diagnosticText: String {
        """
        SpectraPort native iOS port
        Build: \(build)
        iOS: \(UIDevice.current.systemVersion)
        Device model: \(UIDevice.current.model)
        Metal: \(metalStatus)
        Startup checkpoint: diagnostic home loaded
        Bundle identifier: \(Bundle.main.bundleIdentifier ?? "unknown")
        """
    }

    var body: some View {
        if showEditor {
            EditorView(onBack: { showEditor = false })
        } else {
            VStack(alignment: .leading, spacing: 20) {
                Text("SpectraPort")
                    .font(.system(size: 32, weight: .semibold))
                Text("iOS 16 启动诊断")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("如果你能看到这一页，说明 App 已经启动。原版光谱引擎还没有初始化。")
                    .font(.body)
                VStack(alignment: .leading, spacing: 8) {
                    Text("构建版本：\(build)")
                    Text("系统：iOS \(UIDevice.current.systemVersion)")
                    Text("Metal：\(metalStatus)")
                }
                .font(.footnote.monospaced())
                .textSelection(.enabled)

                Button("第一步：检查 Metal") {
                    if let device = MTLCreateSystemDefaultDevice() {
                        metalStatus = "可用 — \(device.name)"
                    } else {
                        metalStatus = "不可用"
                    }
                }
                .buttonStyle(.bordered)

                Button("第二步：进入照片编辑器") {
                    showEditor = true
                }
                .buttonStyle(.borderedProminent)

                Button(copied ? "已复制诊断" : "复制诊断信息") {
                    UIPasteboard.general.string = diagnosticText
                    copied = true
                }
                .buttonStyle(.bordered)
                Spacer()
                Text("独立 iOS 移植测试版 · 基于原版 SpektraLab 开源引擎")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}
