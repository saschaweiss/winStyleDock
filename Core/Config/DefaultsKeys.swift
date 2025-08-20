import Defaults

// Alle Settings-Schlüssel an EINER Stelle, ASCII-only, keine Punkte/Prefix '@'.
extension Defaults.Keys {
    // Farben als Hex (#RRGGBBAA)
    static let activeColorHex      = Key<String>("activeColorHex",      default: "#3B82F6FF") // Blau
    static let inactiveColorHex    = Key<String>("inactiveColorHex",    default: "#9CA3AFFF") // Grau hell
    static let normalColorHex      = Key<String>("normalColorHex",      default: "#64748BFF") // Slate
    static let backgroundColorHex  = Key<String>("backgroundColorHex",  default: "#000000C0") // Schwarz 75%

    // Layout/Verhalten
    static let buttonMaxWidth      = Key<Double>("buttonMaxWidth",      default: 300)
    static let buttonPadding       = Key<Double>("buttonPadding",       default: 6)
    static let buttonSpacing       = Key<Double>("buttonSpacing",       default: 6)
    static let pollInterval        = Key<Double>("pollInterval",        default: 0.12)
    static let groupByApp          = Key<Bool>("groupByApp",            default: true)
    static let showIcons           = Key<Bool>("showIcons",             default: true)
}
