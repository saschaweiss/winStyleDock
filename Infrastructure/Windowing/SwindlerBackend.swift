// Core/Windowing/SwindlerBackend.swift
import Foundation
import AppKit
import ApplicationServices
import Swindler
import PromiseKit   // Swindler initialisiert sich über PromiseKit

/// Backend-Implementierung mit Swindler.
/// Läuft bewusst am MainActor, da AX + Swindler hier am stabilsten sind.
@MainActor
final class SwindlerBackend: WindowBackend {
    static let shared = SwindlerBackend()

    // Kollision mit SwiftUI.State vermeiden → voll qualifizieren
    private var swindlerState: Swindler.State?

    private init() {
        // Asynchrone Initialisierung (fordert ggf. Accessibility-Rechte an)
        firstly {
            Swindler.initialize()
        }.done { [weak self] st in
            self?.swindlerState = st
            NSLog("Swindler: initialized")
        }.catch { err in
            NSLog("Swindler: initialize() failed: \(String(describing: err))")
        }
    }

    // MARK: - Mapping: AXUIElement -> Swindler.Window

    /// Versucht, ein Swindler.Window zu einem AXUIElement zu finden:
    /// 1) match per PID, dann
    /// 2) Titelgleichheit, danach
    /// 3) Frame ~≈ gleich (Toleranz).
    private func swindlerWindow(for axElement: AXUIElement) -> Swindler.Window? {
        guard let st = swindlerState else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(axElement, &pid)

        // passender Swindler-Application-Wrapper
        guard let app = st.runningApplications.first(where: { $0.processIdentifier == pid }) else {
            return nil
        }

        let axTitle = axString(axElement, kAXTitleAttribute as CFString) ?? ""
        let axFrame = axFrameOf(axElement)

        // 1) Titel-Match (schnell & robust, v.a. bei Tab-Apps)
        if !axTitle.isEmpty, let hit = app.knownWindows.first(where: { $0.title.value == axTitle }) {
            return hit
        }

        // 2) Frame-Match (Toleranz)
        if let hit = app.knownWindows.first(where: {
            let f = $0.frame.value
            return approxEqual(f, axFrame, epsilon: 3.0)
        }) {
            return hit
        }

        return nil
    }

    // MARK: - WindowBackend

    func minimize(axElement: AXUIElement) -> Bool {
        if let w = swindlerWindow(for: axElement) {
            w.isMinimized.set(true).catch { err in
                NSLog("Swindler minimize failed: \(String(describing: err))")
            }
            return true
        }
        return AXWindowBackend.shared.minimize(axElement: axElement)
    }

    func restore(axElement: AXUIElement) -> Bool {
        if let w = swindlerWindow(for: axElement) {
            // Reihenfolge: ent-minimieren, App einblenden, dieses Fenster als Main setzen
            w.isMinimized.set(false).catch { _ in }
            w.application.isHidden.set(false).catch { _ in }
            w.application.mainWindow.set(w).catch { _ in }
            return true
        }
        return AXWindowBackend.shared.restore(axElement: axElement)
    }

    func bringToFront(axElement: AXUIElement) -> Bool {
        if let w = swindlerWindow(for: axElement) {
            w.isMinimized.set(false).catch { _ in }
            w.application.isHidden.set(false).catch { _ in }
            w.application.mainWindow.set(w).catch { _ in }
            return true
        }
        return AXWindowBackend.shared.bringToFront(axElement: axElement)
    }

    func close(axElement: AXUIElement) -> Bool {
        // Swindler hat (derzeit) keine öffentliche close()-API -> immer AX-Fallback nutzen
        return AXWindowBackend.shared.close(axElement: axElement)
    }
}

// MARK: - Kleine AX-Helper (lokal, MainActor)

@MainActor
private func axString(_ el: AXUIElement, _ attr: CFString) -> String? {
    var ref: CFTypeRef?
    let r = AXUIElementCopyAttributeValue(el, attr, &ref)
    return (r == .success) ? (ref as? String) : nil
}

@MainActor
private func axFrameOf(_ el: AXUIElement) -> CGRect {
    var rect = CGRect.zero
    var ref: CFTypeRef?
    AXUIElementCopyAttributeValue(el, "AXFrame" as CFString, &ref)
    if let r = ref, CFGetTypeID(r) == AXValueGetTypeID() {
        let v = unsafeBitCast(r, to: AXValue.self)
        AXValueGetValue(v, .cgRect, &rect)
    }
    return rect
}

@MainActor
private func approxEqual(_ a: CGRect, _ b: CGRect, epsilon: CGFloat) -> Bool {
    abs(a.origin.x - b.origin.x) <= epsilon &&
    abs(a.origin.y - b.origin.y) <= epsilon &&
    abs(a.size.width - b.size.width) <= epsilon &&
    abs(a.size.height - b.size.height) <= epsilon
}
