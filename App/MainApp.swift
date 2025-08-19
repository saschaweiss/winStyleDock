// App/MainApp.swift
import SwiftUI
import AppKit

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(DockAppDelegate.self) var appDelegate

    init() {
        PermissionsManager.shared.ensureAccessibilityPermissions()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            EmptyCommands()
            // (Optional) Menüeintrag "Einstellungen…"
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text("Einstellungen…")
                }
            }
        }

        // ✅ Offizielle Settings-Scene
        Settings {
            SettingsView()
        }
    }
}
