import Foundation
import Defaults

// Zentrale Schlüssel für Settings
extension Defaults.Keys {
    // Farben (als Hex mit Alpha)
    static let activeColorHex     = Key<String>("settings.activeColorHex", default: "#2680FFFF") // blau
    static let inactiveColorHex   = Key<String>("settings.inactiveColorHex", default: "#80808099") // grau 60%
    static let normalColorHex     = Key<String>("settings.normalColorHex", default: "#8080808C")   // grau 55%
    static let backgroundColorHex = Key<String>("settings.backgroundColorHex", default: "#000000C7") // schwarz ~78%

    // Layout
    static let buttonMaxWidth     = Key<Double>("settings.buttonMaxWidth", default: 300)
    static let buttonPadding      = Key<Double>("settings.buttonPadding", default: 6)
    static let buttonSpacing      = Key<Double>("settings.buttonSpacing", default: 6)

    // Verhalten
    static let pollInterval       = Key<Double>("settings.pollInterval", default: 0.12)
    static let groupByApp         = Key<Bool>("settings.groupByApp", default: true)
    static let showIcons          = Key<Bool>("settings.showIcons", default: true)
}
