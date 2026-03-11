// ClipListView.swift
// Bookmark 列表视图 — 展示所有 Bookmark，支持点击进入、长按编辑、右滑删除、右上角添加

import SwiftUI

struct ClipListView: View {
    @EnvironmentObject private var store: ClipsStore
    @State private var editingClip: Bookmark?
    @State private var showAddSheet = false
    @State private var showImportSheet = false
    @State private var importJSON = ""
    @State private var importAlert: ImportAlertItem?
    @State private var showEdgeSettings = false
    @Environment(\.edgeModule) private var edgeModule

    var body: some View {
        List {
            ForEach(store.clips) { clip in
                NavigationLink(value: ClipDestination(bookmark: clip, fullscreen: false)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(clip.name)
                            .font(.headline)
                        Text(displayURL(clip.server_url))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        store.deleteClip(clip)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        editingClip = clip
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle("Clips")
        .navigationDestination(for: ClipDestination.self) { dest in
            ClipView(bookmark: dest.bookmark, initialFullscreen: dest.fullscreen)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button {
                        importFromClipboard()
                    } label: {
                        Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        showImportSheet = true
                    } label: {
                        Label("粘贴 JSON 导入", systemImage: "doc.text")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        showEdgeSettings = true
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ClipFormView(mode: .add)
        }
        .sheet(item: $editingClip) { clip in
            ClipFormView(mode: .edit(clip))
        }
        .sheet(isPresented: $showImportSheet) {
            ImportJSONView(jsonText: $importJSON) { text in
                doImport(text)
            }
        }
        .sheet(isPresented: $showEdgeSettings) {
            EdgeSettingsView(edgeModule: edgeModule)
        }
        .alert(item: $importAlert) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
        }
    }

    private func displayURL(_ urlString: String) -> String {
        if let url = URL(string: urlString) {
            return url.host ?? urlString
        }
        return urlString
    }

    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            importAlert = ImportAlertItem(title: "导入失败", message: "剪贴板为空")
            return
        }
        doImport(text)
    }

    private func doImport(_ jsonText: String) {
        do {
            let count = try store.importFromJSON(jsonText)
            if count > 0 {
                importAlert = ImportAlertItem(title: "导入成功", message: "已导入 \(count) 个 Bookmark")
            } else {
                importAlert = ImportAlertItem(title: "导入完成", message: "没有新的 Bookmark（可能已存在）")
            }
        } catch {
            importAlert = ImportAlertItem(title: "导入失败", message: error.localizedDescription)
        }
    }
}

// MARK: - Import Alert

private struct ImportAlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - JSON 文本输入视图

private struct ImportJSONView: View {
    @Binding var jsonText: String
    let onImport: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                Text("粘贴 Bookmark JSON")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top)
                TextEditor(text: $jsonText)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal)
            }
            .navigationTitle("导入 JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        onImport(jsonText)
                        jsonText = ""
                        dismiss()
                    }
                    .disabled(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
