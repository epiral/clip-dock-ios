// ClipFormView.swift
// Clip 添加/编辑表单 — alias、host、port、token 四个字段

import SwiftUI

struct ClipFormView: View {
    enum Mode: Identifiable {
        case add
        case edit(ClipConfig)

        var id: String {
            switch self {
            case .add: return "__add__"
            case .edit(let c): return c.id
            }
        }
    }

    let mode: Mode

    @EnvironmentObject private var store: ClipsStore
    @Environment(\.dismiss) private var dismiss

    @State private var alias = ""
    @State private var host = ""
    @State private var portString = ""
    @State private var token = ""

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var title: String {
        isEditing ? "编辑 Clip" : "添加 Clip"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $alias)
                        .autocorrectionDisabled()
                    TextField("主机", text: $host)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    TextField("端口", text: $portString)
                        .keyboardType(.numberPad)
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
                        .disabled(alias.isEmpty || host.isEmpty || portString.isEmpty)
                }
            }
            .onAppear {
                if case .edit(let clip) = mode {
                    alias = clip.alias
                    host = clip.host
                    portString = String(clip.port)
                    token = clip.token
                }
            }
        }
    }

    private func save() {
        let port = Int(portString) ?? 0
        let clip = ClipConfig(alias: alias, host: host, port: port, token: token)
        if isEditing {
            store.updateClip(clip)
        } else {
            store.addClip(clip)
        }
        dismiss()
    }
}
