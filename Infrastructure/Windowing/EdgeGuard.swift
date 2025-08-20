import AppKit
import Foundation
import ApplicationServices
import Combine

/// EdgeGuard "simuliert" einen unteren Bildschirmrand (deine Taskbar),
/// indem es fremde App-Fenster, die in die Leiste hineinragen, sanft nach oben schiebt.
/// - Keine Private APIs
/// - Nur Standard-TopLevel-Fenster (AXWindow/AXStandardWindow/AXDocumentWindow)
/// - Greift nur ein, wenn ein Fenster stabil "im Weg" ist (Debounce), damit Drags nicht "kämpfen"
@MainActor
final class EdgeGuard {
    static let shared = EdgeGuard()

    private var cancellable: AnyCancellable?
    private weak var scanner: WindowScanner?

    // Debounce / Anti-Flattern
    private var lastFrames: [WindowID: (frame: CGRect, ts: Date)] = [:]
    private var lastAdjust: [WindowID: Date] = [:]

    // Konfig
    private var barHeight: CGFloat = 60
    private var minStability: TimeInterval = 0.18   // Fenster muss min. so lange „an gleicher Stelle“ hängen
    private var minAdjustGap: TimeInterval = 0.25   // nicht zu oft nachjustieren

    func start(using scanner: WindowScanner, barHeight: CGFloat) {
        self.scanner = scanner
        self.barHeight = barHeight

        // Throttle auf ~8 Hz – genügt völlig, flackert nicht
        cancellable = scanner.$windows
            .removeDuplicates(by: { lhs, rhs in
                // Grober Vergleich: Anzahl & IDs (Statusänderungen sind ok)
                guard lhs.count == rhs.count else { return false }
                for i in lhs.indices {
                    if lhs[i].windowID != rhs[i].windowID { return false }
                }
                return true
            })
            .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.tick()
                }
            }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        lastFrames.removeAll()
        lastAdjust.removeAll()
    }

    /// Ein Tick: prüft alle **sichtbaren, nicht minimierten** Fenster
    /// und schiebt sie ggf. oberhalb der Taskbar-Kante (pro zugehörigem Screen).
    private func tick() {
        guard let scanner else { return }

        let barH = barHeight

        for win in scanner.windows {
            // Minimierte und Nicht-TopLevel-Fenster ignorieren
            if win.minimized { continue }
            if !isTopLevelNormalWindow(win.axElement) { continue }

            // Den Screen bekommen wir direkt aus dem WindowInfo
            let screen = win.screen

            let frame = frameOf(win.axElement)
            guard frame.width > 0, frame.height > 0 else { continue }

            // Bar-Rect am unteren Rand des Displays
            let barRect = CGRect(
                x: screen.frame.minX,
                y: screen.frame.minY,
                width: screen.frame.width,
                height: barH
            )

            // Wenn Fenster gar nicht in die Bar ragt → nix tun
            guard frame.intersects(barRect) || frame.minY < (screen.frame.minY + barH) else {
                // Frame merken (für Stabilitätscheck)
                lastFrames[win.windowID] = (frame, Date())
                continue
            }

            // Stabilitäts-Check (Fenster nicht gerade am Draggen/Resizing?)
            if let old = lastFrames[win.windowID] {
                // Position grob unverändert?
                let same = approxEqual(old.frame, frame, epsilon: 1.5)
                let stableFor = Date().timeIntervalSince(old.ts)
                if !same {
                    // Position hat sich geändert: Timer neu starten
                    lastFrames[win.windowID] = (frame, Date())
                    continue
                } else if stableFor < minStability {
                    // noch nicht lange genug stabil
                    continue
                }
            } else {
                // Erster Kontakt
                lastFrames[win.windowID] = (frame, Date())
                continue
            }

            // Rate-Limit: nicht zu häufig schieben
            if let last = lastAdjust[win.windowID], Date().timeIntervalSince(last) < minAdjustGap {
                continue
            }

            // Zielposition: Unterkante direkt auf Bar-Oberkante setzen
            // (Coordinate system: Cocoa bottom-left origin for window frames)
            let targetY = screen.frame.minY + barH
            let delta = targetY - frame.minY
            if delta > 0.5 { // nur wenn wirklich reinragt
                var newOrigin = frame.origin
                newOrigin.y += delta

                if setWindowPosition(win.axElement, to: newOrigin) {
                    lastAdjust[win.windowID] = Date()
                }
            }
        }
    }

    // MARK: - AX Helpers (defensiv)

    private func isTopLevelNormalWindow(_ el: AXUIElement) -> Bool {
        let role = axString(el, kAXRoleAttribute as CFString)
        guard role == (kAXWindowRole as String) else { return false }
        let sub = axString(el, kAXSubroleAttribute as CFString)
        if sub.isEmpty { return true }
        return ["AXStandardWindow", "AXDocumentWindow"].contains(sub)
    }

    private func frameOf(_ el: AXUIElement) -> CGRect {
        var rect = CGRect.zero
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, "AXFrame" as CFString, &ref)
        if let r = ref, CFGetTypeID(r) == AXValueGetTypeID() {
            let v = unsafeBitCast(r, to: AXValue.self)
            AXValueGetValue(v, .cgRect, &rect)
        }
        return rect
    }

    @discardableResult
    private func setWindowPosition(_ el: AXUIElement, to origin: CGPoint) -> Bool {
        var posValue = origin
        guard let axVal = AXValueCreate(.cgPoint, &posValue) else { return false }
        let err = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, axVal)
        return err == .success
    }

    private func axString(_ el: AXUIElement, _ attr: CFString) -> String {
        var ref: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(el, attr, &ref)
        return (r == .success) ? (ref as? String ?? "") : ""
    }

    private func approxEqual(_ a: CGRect, _ b: CGRect, epsilon: CGFloat) -> Bool {
        abs(a.origin.x - b.origin.x) <= epsilon &&
        abs(a.origin.y - b.origin.y) <= epsilon &&
        abs(a.size.width - b.size.width) <= epsilon &&
        abs(a.size.height - b.size.height) <= epsilon
    }

    // Lass’ diese Helper gern drin, aktuell nicht genutzt – kann später nützlich sein.
    private func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
        return CGDirectDisplayID(num.uint32Value)
    }
}
