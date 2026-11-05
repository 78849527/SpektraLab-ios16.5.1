import SwiftUI

/// Stored locally. Changing this does not interrupt the current edit;
/// the selection takes effect on the next cold start of SpectraPort.
struct StartupSettingsView: View {
    @AppStorage("spectraport.startup.destination") private var destination = "editor"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        destination = "camera"
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: "camera")
                                .font(.system(size: 19))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("启动进入拍摄").font(.system(size: 16, weight: .medium))
                                Text("使用完整 iOS 系统相机")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if destination == "camera" {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(DarkroomStyle.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .tint(.primary)

                    Button {
                        destination = "editor"
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 19))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("启动进入编辑").font(.system(size: 16, weight: .medium))
                                Text("测试版默认 · 直接进入编辑和调色")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if destination == "editor" {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(DarkroomStyle.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .tint(.primary)
                } header: {
                    Text("App 启动时进入")
                } footer: {
                    Text("选择会保存在本机，下次重新打开 App 时生效。不会重置胶片设置或已保存的预设。")
                }

                Section("关于") {
                    LabeledContent("应用", value: "SpectraPort")
                    LabeledContent("默认相机", value: "iOS 系统 JPEG 拍摄")
                    LabeledContent("照片处理", value: "本机 C++ / Metal 光谱引擎")
                }
            }
            .scrollContentBackground(.hidden)
            .background(DarkroomStyle.background.ignoresSafeArea())
            .navigationTitle("启动偏好设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(DarkroomStyle.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
