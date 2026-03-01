// PushRegistrationService.swift
// APNs 推送注册服务 — 将 device token 上报 bark-server，持久化 device_key

import Foundation

/// APNs 推送注册服务
enum PushRegistrationService {

    private static let serverURL = "https://push.yan5xu.ai:5443"
    private static let deviceKeyKey = "push.device_key"

    /// 读取已持久化的 device_key
    static func deviceKey() -> String? {
        UserDefaults.standard.string(forKey: deviceKeyKey)
    }

    /// 将 APNs device token 上报到 bark-server，获取并持久化 device_key
    static func register(deviceToken: Data) {
        let hexToken = deviceToken.map { String(format: "%02x", $0) }.joined()

        var bodyDict: [String: String] = ["device_token": hexToken]
        if let existingKey = deviceKey() {
            bodyDict["key"] = existingKey
        }

        guard let url = URL(string: "\(serverURL)/register") else {
            print("[PushRegistrationService] URL 无效")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict)

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    print("[PushRegistrationService] 注册失败：HTTP \(code)")
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataDict = json["data"] as? [String: Any],
                      let newKey = dataDict["key"] as? String else {
                    print("[PushRegistrationService] 解析 device_key 失败")
                    return
                }

                UserDefaults.standard.set(newKey, forKey: deviceKeyKey)
                print("[PushRegistrationService] 注册成功，device_key: \(newKey)")
            } catch {
                print("[PushRegistrationService] 网络错误：\(error.localizedDescription)")
            }
        }
    }
}
