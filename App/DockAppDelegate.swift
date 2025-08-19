import AppKit

/// Verwaltet App-Lebenszyklus & dein Dock-Setup
class DockAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hier später: Panels je Screen bauen, Scanner starten, Rechte prüfen, ...
        print("✅ DockAppDelegate gestartet")

        // Optional: Platzhalter-Fenster verstecken (falls du ein leeres WindowGroup nutzt)
        for w in NSApp.windows {
            if w.title == "Placeholder" { w.orderOut(nil) }
        }
    }
}
