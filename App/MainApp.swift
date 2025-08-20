// App/MainApp.swift
import SwiftUI
import AppKit

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(DockAppDelegate.self) var appDelegate

    init() {
        // 1) Rechte prüfen (wie gehabt)
        PermissionsManager.shared.ensureAccessibilityPermissions()

        // 2) Swindler als Backend aktivieren (kannst du zentral umschalten)
        WindowSystem.backend = SwindlerBackend.shared
        // Fallback wäre: WindowSystem.backend = AXWindowBackend.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands { EmptyCommands() }
        // SettingsScene bleibt wie von dir eingebaut
    }
}
