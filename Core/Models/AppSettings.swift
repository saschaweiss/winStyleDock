import SwiftUI
import AppKit
import Defaults
import Combine

/// Zentrale Settings-Quelle für die UI.
/// Speichert/liest über `Defaults` (definierte Keys in Core/Config/DefaultsKeys.swift).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Published Properties (von der UI genutzt)
    @Published var activeColor: Color
    @Published var inactiveColor: Color
    @Published var normalColor: Color
    @Published var backgroundColor: Color

    @Published var buttonMaxWidth: CGFloat
    @Published var buttonPadding: CGFloat
    @Published var buttonSpacing: CGFloat
    @Published var pollInterval: TimeInterval
    @Published var groupByApp: Bool
    @Published var showIcons: Bool

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init
    init() {
        // 1) Einmalige Migration alter Keys (mit Punkten) → neue `Defaults`-Keys
        Self.migrateLegacyKeysOnce()

        // 2) Initial aus `Defaults` laden
        activeColor     = Self.color(fromHex: Defaults[.activeColorHex])     ?? Color(NSColor.systemBlue)
        inactiveColor   = Self.color(fromHex: Defaults[.inactiveColorHex])   ?? Color(NSColor.systemGray)
        normalColor     = Self.color(fromHex: Defaults[.normalColorHex])     ?? Color(NSColor.controlAccentColor)
        backgroundColor = Self.color(fromHex: Defaults[.backgroundColorHex]) ?? Color.black.opacity(0.75)

        buttonMaxWidth  = CGFloat(Defaults[.buttonMaxWidth])
        buttonPadding   = CGFloat(Defaults[.buttonPadding])
        buttonSpacing   = CGFloat(Defaults[.buttonSpacing])
        pollInterval    = TimeInterval(Defaults[.pollInterval])
        groupByApp      = Defaults[.groupByApp]
        showIcons       = Defaults[.showIcons]

        // 3) Änderungen automatisch in `Defaults` spiegeln
        setUpBindings()
    }

    // MARK: - Bindings → schreiben nach Defaults
    private func setUpBindings() {
        // Farben als Hex speichern
        $activeColor
            .compactMap { AppSettings.hex(from: $0) }
            .sink { Defaults[.activeColorHex] = $0 }
            .store(in: &cancellables)

        $inactiveColor
            .compactMap { AppSettings.hex(from: $0) }
            .sink { Defaults[.inactiveColorHex] = $0 }
            .store(in: &cancellables)

        $normalColor
            .compactMap { AppSettings.hex(from: $0) }
            .sink { Defaults[.normalColorHex] = $0 }
            .store(in: &cancellables)

        $backgroundColor
            .compactMap { AppSettings.hex(from: $0) }
            .sink { Defaults[.backgroundColorHex] = $0 }
            .store(in: &cancellables)

        // Layout/Verhalten
        $buttonMaxWidth .sink { Defaults[.buttonMaxWidth] = Double($0) }.store(in: &cancellables)
        $buttonPadding  .sink { Defaults[.buttonPadding]  = Double($0) }.store(in: &cancellables)
        $buttonSpacing  .sink { Defaults[.buttonSpacing]  = Double($0) }.store(in: &cancellables)
        $pollInterval   .sink { Defaults[.pollInterval]   = Double($0) }.store(in: &cancellables)
        $groupByApp     .sink { Defaults[.groupByApp]     = $0 }.store(in: &cancellables)
        $showIcons      .sink { Defaults[.showIcons]      = $0 }.store(in: &cancellables)
    }

    // MARK: - Einmalige Migration alter Key-Namen (mit Punkten) → neue ASCII-Keys
    private static func migrateLegacyKeysOnce() {
        let ud = UserDefaults.standard
        let didFlagKey = "settings_migrated_to_ascii_keys_v1"
        if ud.bool(forKey: didFlagKey) { return } // schon erledigt

        // Alten Key lesen → wenn vorhanden, in neue Defaults schreiben, danach alten löschen
        func migrateHex(oldKey: String, to newKey: Defaults.Key<String>) {
            if let hex = ud.string(forKey: oldKey), !hex.isEmpty {
                Defaults[newKey] = hex
                ud.removeObject(forKey: oldKey)
            }
        }
        func migrateDouble(oldKey: String, to newKey: Defaults.Key<Double>) {
            if let n = ud.object(forKey: oldKey) as? Double {
                Defaults[newKey] = n
                ud.removeObject(forKey: oldKey)
            }
        }
        func migrateBool(oldKey: String, to newKey: Defaults.Key<Bool>) {
            if let b = ud.object(forKey: oldKey) as? Bool {
                Defaults[newKey] = b
                ud.removeObject(forKey: oldKey)
            }
        }

        // Farben
        migrateHex(oldKey: "settings.activeColor",     to: .activeColorHex)
        migrateHex(oldKey: "settings.inactiveColor",   to: .inactiveColorHex)
        migrateHex(oldKey: "settings.normalColor",     to: .normalColorHex)
        migrateHex(oldKey: "settings.backgroundColor", to: .backgroundColorHex)

        // Layout/Verhalten
        migrateDouble(oldKey: "settings.buttonMaxWidth", to: .buttonMaxWidth)
        migrateDouble(oldKey: "settings.buttonPadding",  to: .buttonPadding)
        migrateDouble(oldKey: "settings.buttonSpacing",  to: .buttonSpacing)
        migrateDouble(oldKey: "settings.pollInterval",   to: .pollInterval)
        migrateBool(oldKey:   "settings.groupByApp",     to: .groupByApp)
        migrateBool(oldKey:   "settings.showIcons",      to: .showIcons)

        ud.set(true, forKey: didFlagKey)
    }

    // MARK: - Color <-> Hex Helpers
    /// Hex (#RRGGBBAA oder #RRGGBB) → Color
    private static func color(fromHex hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 8 || s.count == 6 else { return nil }

        var rgba: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&rgba) else { return nil }

        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((rgba & 0xFF00_0000) >> 24) / 255
            g = CGFloat((rgba & 0x00FF_0000) >> 16) / 255
            b = CGFloat((rgba & 0x0000_FF00) >> 8)  / 255
            a = CGFloat( rgba & 0x0000_00FF)        / 255
        } else { // 6-stellig
            r = CGFloat((rgba & 0xFF00_00) >> 16) / 255
            g = CGFloat((rgba & 0x00FF_00) >> 8)  / 255
            b = CGFloat( rgba & 0x0000_FF)        / 255
            a = 1.0
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Color → Hex (#RRGGBBAA)
    private static func hex(from color: Color) -> String? {
        #if canImport(AppKit)
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.systemBlue
        let r = UInt8((ns.redComponent   * 255.0).rounded())
        let g = UInt8((ns.greenComponent * 255.0).rounded())
        let b = UInt8((ns.blueComponent  * 255.0).rounded())
        let a = UInt8((ns.alphaComponent * 255.0).rounded())
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        #else
        return nil
        #endif
    }
}
