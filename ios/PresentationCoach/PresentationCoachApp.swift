import SwiftUI

@main
struct PresentationCoachApp: App {
    var body: some Scene {
        WindowGroup {
            BackendStatusView()
        }
    }
}

private struct BackendStatusView: View {
    @StateObject private var check = BackendCheck()

    var body: some View {
        ContentUnavailableView {
            Label("Presentation Coach", systemImage: "mic")
        } description: {
            Text(check.status.isEmpty ? "Check the connection to your backend." : check.status)
        } actions: {
            Button(check.isChecking ? "Checking…" : "Check Server") {
                Task { await check.run() }
            }
            .disabled(check.isChecking)
        }
    }
}

@MainActor
private final class BackendCheck: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var isChecking = false

    func run() async {
        guard !isChecking else { return }
        guard let address = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String,
              let baseURL = URL(string: address),
              baseURL.host != nil else {
            status = "Set the backend URL in Xcode."
            return
        }

        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: baseURL.appending(path: "health"))
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            let health = try JSONDecoder().decode(Health.self, from: data)
            let isHealthy = (response as? HTTPURLResponse)?.statusCode == 200 && health.status == "ok"
            status = isHealthy ? "Backend connected." : "The backend returned an unexpected response."
        } catch {
            status = "Couldn’t reach the backend."
        }
    }

    private struct Health: Decodable {
        let status: String
    }
}
