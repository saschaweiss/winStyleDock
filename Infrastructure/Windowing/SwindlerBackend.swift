// Core/Windowing/SwindlerBackend.swift
import Foundation
import AppKit
import ApplicationServices
import Swindler

/// Backend-Implementierung mit Swindler
final class SwindlerBackend: WindowBackend {
    static let shared = SwindlerBackend()

    private let state: State

    private init() {
        // Swindler State initialisieren (wirft nicht, aber kann Rechte erfordern)
        self.state = State(withAccessibility: true)
        // Optional: Beobachter starten (nicht zwingend nötig für einfache Aktionen)
        try? self.state.start()
    }

    // MARK: - Mapping AXUIElement → Swindler.Window

    /// Swindler arbeitet intern auch mit AX; wir mappen per pid + AXUIElementRef.
    private func swindlerWindow(for axElement: AXUIElement) -> Swindler.Window? {
        var pid: pid_t = 0
        AXUIElementGetPid(axElement, &pid)

        guard let app = state.runningApplications.first(where: { $0.processIdentifier == pid }) else {
            return nil
        }
        // Heuristik: gleiches AX-Element über die Window-Liste suchen
        // Vergleich per AXUIElementRef (Unmanaged Pointer)
        let targetPtr = Unmanaged.passUnretained(axElement).toOpaque()

        for w in app.windows {
            if let swAX = w.axElement {
                let swPtr = Unmanaged.passUnretained(swAX).toOpaque()
                if swPtr == targetPtr {
                    return w
                }
            }
        }
        // Fallback: gleiche Titel + isMinimized + isMain – kann bei Tabs helfen
        if let title = try? axString(axElement, kAXTitleAttribute as CFString), !title.isEmpty {
            return app.windows.first(where: { (try? $0.title.get()) == title })
        }
        return nil
    }

    // MARK: - WindowBackend

    func minimize(axElement: AXUIElement) -> Bool {
        if let w = swindlerWindow(for: axElement) {
            do {
                try w.isMinimized.set(true)
                return true
            } catch { return false }
        }
        // Fallback auf AX
        return AXWindowBackend.shared.minimize(axElement: axElement)
    }

    func restore(axElement: AXUIElement) -> Bool {
        if let w = swindlerWindow(for: axElement) {
            do {
                try w.isMinimized.set(false)
                try w.isMain.set(true)
                try w.app.bringToFront()
                return true
            } catch { return false }
        }
        return AXWindowBackend.shared.restore(axElement: axElement)
    }

    func bringToFront(axElement: AXUIElement) -> Bool {
        if let w = swindlerWindow(for: axElement) {
            do {
                try w.isMinimized.set(false)
                try w.isMain.set(true)
                try w.app.bringToFront()
                return true
            } catch { return false }
        }
        return AXWindowBackend.shared.bringToFront(axElement: axElement)
    }

    func close(axElement: AXUIElement) -> Bool {
        if let w = swindlerWindow(for: axElement) {
            do {
                try w.close()
                return true
            } catch { return false }
        }
        return AXWindowBackend.shared.close(axElement: axElement)
    }
}

// MARK: - Kleine AX-Helper (lokal)
private func axString(_ el: AXUIElement, _ attr: CFString) -> String {
    var ref: CFTypeRef?
    let r = AXUIElementCopyAttributeValue(el, attr, &ref)
    return (r == .success) ? (ref as? String ?? "") : ""
}
