# winStyleDock — Projektstruktur

> Ziel: Windows-ähnliche Taskbar für macOS (>= 15.x) mit stabiler Reihenfolge,
> minimalem Flackern, Multi-Monitor-Support und konfigurierbarem Theme.
>
> App/
├─ MainApp.swift # @main; setzt App-Delegate & startet die App
├─ DockAppDelegate.swift # Lebenszyklus; startet DockWindowManager
└─ ContentView.swift # (optional) Platzhalter/Debug-Fenster

Core/
├─ Config/
│ └─ AppTheme.swift # @MainActor Singleton: Farben, Abstände, Zeiten
└─ Models/
├─ AppSettings.swift # UserDefaults-basierte Settings (optional)
└─ WindowInfo.swift # WindowID + WindowInfo Datenmodell

Infrastructure/
└─ Windowing/
└─ DockWindowManager.swift # @MainActor; erstellt/managed NSPanels je Screen

Managers/
└─ PermissionsManager.swift # Accessibility-Rechte prüfen/erzwingen

Services/
└─ WindowScanner.swift # Fenster-Scan (AX + CG); liefert WindowInfo-Liste

UI/
├─ Settings/
│ └─ SettingsView.swift # Einstellungsfenster (Farben/Abstände/Zeiten)
└─ Taskbar/
└─ WindowsDockView.swift # SwiftUI-Taskbar für EINEN Screen

Utils/
├─ Color+Hex.swift # kleine Farb-Helper
└─ EmptyCommands.swift # leere .commands{}-Deklaration (Xcode-Fehler vermeiden)

Assets.xcassets/ # AppIcon, Farben
winstyledock.entitlements # Accessibility, Screen Recording etc. (falls nötig)
Docs/
└─ PROJECT_STRUCTURE.md # Diese Datei
