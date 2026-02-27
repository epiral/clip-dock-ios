// ClipListView.swift
// Clip 列表视图 — 展示所有 Clip，支持点击进入、长按编辑、右滑删除、右上角添加

import SwiftUI

struct ClipListView: View {
    @EnvironmentObject private var store: ClipsStore
    @Binding var deepLinkFullscreen: Bool
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
        .navigationDestination(for: ClipConfig.self) { clip in
            ClipView(config: clip, initialFullscreen: deepLinkFullscreen)
                .onAppear { deepLinkFullscreen = false }
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
