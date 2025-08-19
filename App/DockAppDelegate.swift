// App/DockAppDelegate.swift
import AppKit

/// Verwaltet App-Lebenszyklus & dein Dock-Setup
final class DockAppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Rechte sicherstellen (optional, falls schon woanders aufgerufen)
        PermissionsManager.shared.ensureAccessibilityPermissions()

        // Taskbar-Panels für alle Screens anzeigen
        DockWindowManager.shared.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Panels sauber einklappen
        DockWindowManager.shared.hide()
    }
}
