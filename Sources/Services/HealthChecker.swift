import Foundation

enum HealthLevel {
    case healthy, unhealthy, unknown
}

class HealthChecker {
    private let gatewayURL = "http://127.0.0.1:18789/health"

    func check() async -> HealthLevel {
        guard let url = URL(string: gatewayURL) else { return .unknown }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                // Parse the JSON response: {"ok":true,"status":"live"}
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ok = json["ok"] as? Bool, ok {
                    return .healthy
                }
            }
            return .unhealthy
        } catch {
            return .unhealthy
        }
    }
}
