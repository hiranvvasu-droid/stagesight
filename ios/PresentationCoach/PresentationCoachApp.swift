import SwiftUI

@main
struct PresentationCoachApp: App {
    var body: some Scene {
        WindowGroup {
            ContentUnavailableView("Presentation Coach", systemImage: "mic")
        }
    }
}
