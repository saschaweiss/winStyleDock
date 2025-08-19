# winStyleDock — Projektstruktur<br>
<br>
> Ziel: Windows-ähnliche Taskbar für macOS (>= 15.x) mit stabiler Reihenfolge,<br>
> minimalem Flackern, Multi-Monitor-Support und konfigurierbarem Theme.<br>
<br>
App/<br>
├─ MainApp.swift # @main; setzt App-Delegate & startet die App<br>
├─ DockAppDelegate.swift # Lebenszyklus; startet DockWindowManager<br>
└─ ContentView.swift # (optional) Platzhalter/Debug-Fenster<br>
<br>
Core/<br>
├─ Config/<br>
│ └─ AppTheme.swift # @MainActor Singleton: Farben, Abstände, Zeiten<br>
└─ Models/<br>
├─ AppSettings.swift # UserDefaults-basierte Settings (optional)<br>
└─ WindowInfo.swift # WindowID + WindowInfo Datenmodell<br>
<br>
Infrastructure/<br>
└─ Windowing/<br>
└─ DockWindowManager.swift # @MainActor; erstellt/managed NSPanels je Screen<br>
<br>
Managers/<br>
└─ PermissionsManager.swift # Accessibility-Rechte prüfen/erzwingen<br>
<br>
Services/<br>
└─ WindowScanner.swift # Fenster-Scan (AX + CG); liefert WindowInfo-Liste<br>
<br>
UI/
├─ Settings/<br>
│ └─ SettingsView.swift # Einstellungsfenster (Farben/Abstände/Zeiten)<br>
└─ Taskbar/<br>
└─ WindowsDockView.swift # SwiftUI-Taskbar für EINEN Screen<br>
<br>
Utils/<br>
├─ Color+Hex.swift # kleine Farb-Helper<br>
└─ EmptyCommands.swift # leere .commands{}-Deklaration (Xcode-Fehler vermeiden)<br>
<br>
Assets.xcassets/ # AppIcon, Farben<br>
winstyledock.entitlements # Accessibility, Screen Recording etc. (falls nötig)<br>
Docs/<br>
└─ PROJECT_STRUCTURE.md # Diese Datei<br>
<br>
## Datenfluss (High Level)<br>
<br>
- **DockWindowManager** (MainActor) erstellt pro **NSScreen** ein **NSPanel** mit einer **WindowsDockView(scanner:screen:)**.<br>
- **WindowScanner** scannt (Hintergrund) via AX+CG, baut eine geordnete `[WindowInfo]`, die **WindowsDockView** rendert.<br>
- **AppTheme.shared** (MainActor) liefert Farben/Abstände/Zeiten (in UI & Manager benutzt).<br>
<br>
## Wichtige Prinzipien<br>
<br>
- **MainActor**: Alles, was UI/NSPanel/Theme betrifft → MainActor.<br>
- **Scanner im Hintergrund**, UI-Update auf Main.<br>
- **Stabile Reihenfolge** über `WindowID` (PID + CGWindowNumber).<br>
- **PendingStates** puffern UI nach Toggle (kein „Springen“).<br>
