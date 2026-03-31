import Foundation

/// Reads Feishu credentials from OpenClaw's openclaw.json config file.
/// Falls back to env vars or embedded defaults if not found.
struct FeishuCredentials {
    let appId: String
    let appSecret: String
    let userOpenId: String

    init() {
        let configPath = NSHomeDirectory() + "/.openclaw/openclaw.json"
        var appId = ""
        var appSecret = ""
        var userOpenId = ""

        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let channels = json["channels"] as? [String: Any],
           let feishu = channels["feishu"] as? [String: Any] {
            appId = (feishu["appId"] as? String) ?? ""
            appSecret = (feishu["appSecret"] as? String) ?? ""
            userOpenId = (feishu["userOpenId"] as? String) ?? ""
        }

        // Fallback: try env vars
        if appId.isEmpty { appId = ProcessInfo.processInfo.environment["FEISHU_APP_ID"] ?? "" }
        if appSecret.isEmpty { appSecret = ProcessInfo.processInfo.environment["FEISHU_APP_SECRET"] ?? "" }
        if userOpenId.isEmpty { userOpenId = ProcessInfo.processInfo.environment["FEISHU_USER_OPEN_ID"] ?? "" }

        self.appId = appId
        self.appSecret = appSecret
        self.userOpenId = userOpenId
    }

    var isConfigured: Bool {
        !appId.isEmpty && !appSecret.isEmpty && !userOpenId.isEmpty
    }
}

class FeishuNotifier {
    private let creds: FeishuCredentials
    private let feishuAPI = "https://open.feishu.cn"
    private var cachedToken: (token: String, expiresAt: Date)?

    init() {
        self.creds = FeishuCredentials()
    }

    func notify(title: String, body: String) {
        guard creds.isConfigured else {
            print("[Feishu] Not configured: missing appId or appSecret")
            return
        }
        guard let token = getTenantAccessToken() else {
            print("[Feishu] Failed to get access token")
            return
        }
        sendMessage(token: token, title: title, body: body)
    }

    private func getTenantAccessToken() -> String? {
        if let cached = cachedToken, cached.expiresAt > Date() {
            return cached.token
        }

        guard let url = URL(string: "\(feishuAPI)/open-apis/auth/v3/tenant_access_token/internal") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["app_id": creds.appId, "app_secret": creds.appSecret]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var result: String?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["tenant_access_token"] as? String,
                  let expire = json["expire"] as? Int else { return }
            let safeExpire = max(expire - 60, 0)
            self.cachedToken = (token, Date(timeIntervalSinceNow: TimeInterval(safeExpire)))
            result = token
        }
        task.resume()
        semaphore.wait()
        return result
    }

    private func sendMessage(token: String, title: String, body: String) {
        guard let url = URL(string: "\(feishuAPI)/open-apis/im/v1/messages?receive_id_type=open_id") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let messageContent: [String: Any] = [
            "receive_id": creds.userOpenId,
            "msg_type": "text",
            "content": ["text": "【Guardian 告警】\n\(title)\n\n\(body)"]
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: messageContent)

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("[Feishu] Send failed: \(error.localizedDescription)")
                return
            }
            if let httpResponse = response as? HTTPURLResponse {
                print("[Feishu] Send result: \(httpResponse.statusCode)")
            }
        }
        task.resume()
    }
}
