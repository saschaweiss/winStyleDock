import Foundation
import Cocoa
import ApplicationServices

/// Verantwortlich für die Verwaltung von macOS-Berechtigungen,
/// insbesondere Accessibility-Rechte, die für das Fenster-Handling nötig sind.
final class PermissionsManager {

    // MARK: - Singleton
    static let shared = PermissionsManager()
    private init() {}

    // MARK: - Accessibility

    /// Prüft, ob die App die benötigten Accessibility-Rechte hat
    var hasAccessibilityPermissions: Bool {
        return AXIsProcessTrusted()
    }

    /// Öffnet den macOS-Systemdialog, um Accessibility-Rechte anzufordern
    func requestAccessibilityPermissions() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true]
        AXIsProcessTrustedWithOptions(options)
    }

    /// Falls keine Rechte vorhanden sind → zeige Warnung
    func ensureAccessibilityPermissions() {
        guard !hasAccessibilityPermissions else { return }

        let alert = NSAlert()
        alert.messageText = "Zugriffsrechte erforderlich"
        alert.informativeText = """
        Diese App benötigt Zugriffsrechte für Bedienungshilfen (Accessibility),
        um Fenster verwalten zu können.

        Bitte aktiviere sie in den Systemeinstellungen → Sicherheit & Datenschutz → Bedienungshilfen.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Rechte anfordern")
        alert.addButton(withTitle: "Abbrechen")

        if alert.runModal() == .alertFirstButtonReturn {
            self.requestAccessibilityPermissions()
        }
    }
}
