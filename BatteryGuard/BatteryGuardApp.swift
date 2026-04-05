import SwiftUI

@main
struct BatteryGuardApp: App {
    var body: some Scene {
        MenuBarExtra("BatteryGuard", systemImage: "battery.100.bolt") {
            Text("BatteryGuard")
                .font(.headline)
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
