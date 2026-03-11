import SwiftUI
import HealthKit
import Contacts
import EventKit

struct EdgeSettingsView: View {
    var edgeModule: EdgeModule
    @State private var config = EdgeConfig.load()
    @State private var showLogs = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // Status section
                Section {
                    HStack {
                        Text("状态")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                            Text(edgeModule.status.rawValue)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !edgeModule.clipID.isEmpty {
                        HStack {
                            Text("Clip ID")
                            Spacer()
                            Text(edgeModule.clipID.prefix(8) + "...")
                                .foregroundStyle(.secondary)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }

                Section {
                    Toggle("启用 Edge", isOn: $config.enabled)
                } footer: {
                    Text("开启后，iPhone 的能力（定位、健康、通讯录、日历等）会暴露到 Pinix Server，可被其他 Clip 和 Agent 调用。")
                }

                Section("Pinix Server") {
                    TextField("Server URL", text: $config.serverURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    SecureField("Super Token", text: $config.superToken)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                if config.enabled && !config.serverURL.isEmpty {
                    Section("注册的命令 (\(EdgeCommandRouter.commandDefs.count))") {
                        ForEach(EdgeCommandRouter.commandDefs, id: \.name) { cmd in
                            HStack {
                                Text(cmd.name)
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Text(cmd.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("权限") {
                    Button {
                        Task { await requestHealthPermission() }
                    } label: {
                        Label("授权健康数据", systemImage: "heart.fill")
                    }
                    Button {
                        Task { await requestContactsPermission() }
                    } label: {
                        Label("授权通讯录", systemImage: "person.crop.circle")
                    }
                    Button {
                        Task { await requestCalendarPermission() }
                    } label: {
                        Label("授权日历", systemImage: "calendar")
                    }
                }

                Section {
                    Button {
                        showLogs = true
                    } label: {
                        HStack {
                            Label("查看日志", systemImage: "doc.text")
                            Spacer()
                            Text("\(edgeModule.logs.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Edge 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        config.save()
                        edgeModule.restart()
                        dismiss()
                    }
                    .bold()
                }
            }
            .sheet(isPresented: $showLogs) {
                EdgeLogView(edgeModule: edgeModule)
            }
        }
    }

    private func requestHealthPermission() async {
        let store = HKHealthStore()
        let types: Set<HKSampleType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.oxygenSaturation),
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.bodyMass),
            HKQuantityType(.bodyFatPercentage),
            HKQuantityType(.bloodPressureSystolic),
            HKQuantityType(.bloodPressureDiastolic),
            HKCategoryType(.sleepAnalysis),
        ]
        try? await store.requestAuthorization(toShare: [], read: types)
    }

    private func requestContactsPermission() async {
        let store = CNContactStore()
        try? await store.requestAccess(for: .contacts)
    }

    private func requestCalendarPermission() async {
        let store = EKEventStore()
        try? await store.requestFullAccessToEvents()
    }

    private var statusColor: Color {
        switch edgeModule.status {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .error: return .red
        case .idle, .disabled: return .gray
        }
    }
}

// MARK: - Log View

struct EdgeLogView: View {
    var edgeModule: EdgeModule
    @Environment(\.dismiss) private var dismiss

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        NavigationStack {
            List(edgeModule.logs.reversed()) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(Self.timeFormatter.string(from: entry.time))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .listStyle(.plain)
            .navigationTitle("Edge 日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("清除") {
                        edgeModule.logs.removeAll()
                    }
                }
            }
        }
    }
}
