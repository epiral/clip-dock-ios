// ClipFormView.swift
// Bookmark 添加/编辑表单 — name、server_url、token 三个字段

import SwiftUI

struct ClipFormView: View {
    enum Mode: Identifiable {
        case add
        case edit(Bookmark)

        var id: String {
            switch self {
            case .add: return "__add__"
            case .edit(let b): return b.id
            }
        }
    }

    let mode: Mode

    @EnvironmentObject private var store: ClipsStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var serverURL = ""
    @State private var token = ""

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var title: String {
        isEditing ? "编辑 Bookmark" : "添加 Bookmark"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name)
                        .autocorrectionDisabled()
                    TextField("Server URL", text: $serverURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    SecureField("Token", text: $token)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.isEmpty || serverURL.isEmpty)
                }
            }
            .onAppear {
                if case .edit(let bookmark) = mode {
                    name = bookmark.name
                    serverURL = bookmark.server_url
                    token = bookmark.token
                }
            }
        }
    }

    private func save() {
        let bookmark = Bookmark(name: name, server_url: serverURL, token: token)
        if isEditing {
            store.updateClip(bookmark)
        } else {
            store.addClip(bookmark)
        }
        dismiss()
    }
}
