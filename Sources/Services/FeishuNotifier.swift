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
            // Fallback: extract open_id from allowFrom array (openclaw.json stores user open_id there)
            if userOpenId.isEmpty,
               let allowFrom = feishu["allowFrom"] as? [String],
               let first = allowFrom.first {
                userOpenId = first
            }
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

    // MARK: - Public API

    /// Sends a rich interactive card notification.
    /// - Parameters:
    ///   - title: Card header title
    ///   - text: Markdown body content
    ///   - template: "red" for errors/warnings, "green" for success, "blue" for info
    func notify(title: String, body: String, template: String = "red") {
        guard creds.isConfigured else {
            print("[Feishu] Not configured: missing appId or appSecret")
            return
        }
        guard let token = getTenantAccessToken() else {
            print("[Feishu] Failed to get access token")
            return
        }
        sendInteractiveCard(token: token, title: title, body: body, template: template)
    }

    /// Convenience: sends a success card (green header).
    func notifySuccess(title: String, body: String) {
        notify(title: title, body: body, template: "green")
    }

    /// Convenience: sends an error card (red header).
    func notifyError(title: String, body: String) {
        notify(title: title, body: body, template: "red")
    }

    /// Convenience: sends an info card (blue header).
    func notifyInfo(title: String, body: String) {
        notify(title: title, body: body, template: "blue")
    }

    // MARK: - Token

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

    // MARK: - Card Sending

    private func sendInteractiveCard(token: String, title: String, body: String, template: String) {
        guard let url = URL(string: "\(feishuAPI)/open-apis/im/v1/messages?receive_id_type=open_id") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let card: [String: Any] = [
            "config": ["wide_screen_mode": true],
            "header": [
                "title": ["tag": "plain_text", "content": title],
                "template": template
            ],
            "elements": [
                ["tag": "markdown", "content": body]
            ]
        ]

        guard let cardJSON = try? JSONSerialization.data(withJSONObject: card),
              let cardString = String(data: cardJSON, encoding: .utf8) else {
            return
        }

        let messageContent: [String: Any] = [
            "receive_id": creds.userOpenId,
            "msg_type": "interactive",
            "content": cardString
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: messageContent)

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("[Feishu] Card send failed: \(error.localizedDescription)")
                return
            }
            if let httpResponse = response as? HTTPURLResponse {
                print("[Feishu] Card send result: \(httpResponse.statusCode)")
            }
        }
        task.resume()
    }
}
