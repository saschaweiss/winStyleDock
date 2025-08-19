import SwiftUI
import AppKit

@main
struct MainApp: App {
    // App-Delegate, der die Dock-Fenster pro Screen erzeugt
    @NSApplicationDelegateAdaptor(DockAppDelegate.self) var appDelegate
    
    init() {
        // Direkt zu Beginn prüfen, ob Accessibility-Rechte vorhanden sind
        PermissionsManager.shared.ensureAccessibilityPermissions()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // Falls du keine Custom-Commands brauchst, kannst du das leer lassen
            EmptyCommands()
        }
    }
}
