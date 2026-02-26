// ClipListView.swift
// Clip 列表视图 — 展示所有 Clip，支持点击进入、长按编辑、右滑删除、右上角添加

import SwiftUI

struct ClipListView: View {
    @EnvironmentObject private var store: ClipsStore
    @State private var editingClip: ClipConfig?
    @State private var showAddSheet = false

    var body: some View {
        List {
            ForEach(store.clips) { clip in
                NavigationLink(value: clip) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(clip.alias)
                            .font(.headline)
                        Text("\(clip.host):\(clip.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .contextMenu {
                    Button("编辑") { editingClip = clip }
                }
            }
            .onDelete { indexSet in
                for idx in indexSet {
                    store.deleteClip(store.clips[idx])
                }
            }
        }
        .navigationTitle("Clips")
        .navigationDestination(for: ClipConfig.self) { clip in
            ClipView(config: clip)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ClipFormView(mode: .add)
        }
        .sheet(item: $editingClip) { clip in
            ClipFormView(mode: .edit(clip))
        }
    }
}
