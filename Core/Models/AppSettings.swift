import SwiftUI
import AppKit
import Defaults

/// Zentrale Settings-Quelle für die UI.
/// Speichert/liest intern über `Defaults` (statt eigenem UserDefaults-Code).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Published Properties (wie gehabt in deiner UI)
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

    // MARK: - Init (lädt aus Defaults)
    init() {
        // Farben aus Hex
        activeColor     = AppSettings.color(fromHex: Defaults[.activeColorHex])     ?? Color(nsColor: .systemBlue)
        inactiveColor   = AppSettings.color(fromHex: Defaults[.inactiveColorHex])   ?? Color(nsColor: .systemGray)
        normalColor     = AppSettings.color(fromHex: Defaults[.normalColorHex])     ?? Color(nsColor: .systemGray)
        backgroundColor = AppSettings.color(fromHex: Defaults[.backgroundColorHex]) ?? Color.black.opacity(0.78)

        // Layout / Verhalten
        buttonMaxWidth  = CGFloat(Defaults[.buttonMaxWidth])
        buttonPadding   = CGFloat(Defaults[.buttonPadding])
        buttonSpacing   = CGFloat(Defaults[.buttonSpacing])
        pollInterval    = TimeInterval(Defaults[.pollInterval])
        groupByApp      = Defaults[.groupByApp]
        showIcons       = Defaults[.showIcons]

        // Änderungen automatisch in Defaults spiegeln
        setUpBindings()
    }

    // MARK: - Bindings (schreiben nach Defaults)
    private func setUpBindings() {
        // Farben → Hex in Defaults
        _ = $activeColor.sink { [weak self] newValue in
            guard let self, let hex = AppSettings.hex(from: newValue) else { return }
            Defaults[.activeColorHex] = hex
        }
        _ = $inactiveColor.sink { [weak self] newValue in
            guard let self, let hex = AppSettings.hex(from: newValue) else { return }
            Defaults[.inactiveColorHex] = hex
        }
        _ = $normalColor.sink { [weak self] newValue in
            guard let self, let hex = AppSettings.hex(from: newValue) else { return }
            Defaults[.normalColorHex] = hex
        }
        _ = $backgroundColor.sink { [weak self] newValue in
            guard let self, let hex = AppSettings.hex(from: newValue) else { return }
            Defaults[.backgroundColorHex] = hex
        }

        // Layout / Verhalten
        _ = $buttonMaxWidth.sink { Defaults[.buttonMaxWidth] = Double($0) }
        _ = $buttonPadding.sink { Defaults[.buttonPadding]   = Double($0) }
        _ = $buttonSpacing.sink { Defaults[.buttonSpacing]   = Double($0) }
        _ = $pollInterval.sink   { Defaults[.pollInterval]   = Double($0) }
        _ = $groupByApp.sink     { Defaults[.groupByApp]     = $0 }
        _ = $showIcons.sink      { Defaults[.showIcons]      = $0 }
    }

    // MARK: - Color <-> Hex Helpers
    /// Hex (#RRGGBBAA) → Color
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
        } else {
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
        let ns = NSColor(color)
            .usingColorSpace(.sRGB) ?? color.nsColor // fallback
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

private extension Color {
    #if canImport(AppKit)
    var nsColor: NSColor { NSColor(self) }
    #endif
}
