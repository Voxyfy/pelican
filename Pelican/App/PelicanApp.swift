import SwiftUI

@main
struct PelicanApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserWindow()
                .frame(minWidth: 820, minHeight: 520)
                .tint(.pelican)
        }
        .windowToolbarStyle(.unified)
    }
}

extension Color {
    /// The orange of the pelican's beak in the app icon.
    static let pelican = Color(red: 1.0, green: 0.55, blue: 0.12)
}
