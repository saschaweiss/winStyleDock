import Foundation
import Cocoa
import ApplicationServices

/// Scannt regelmäßig alle Top-Level-Fenster, hält stabile Reihenfolge je Fenster (WindowID),
/// liefert minimierte Fenster weiterhin aus, gruppiert NICHT (UI erledigt das),
/// und puffert UI-Zustände kurz (pendingStates), um Flackern zu verhindern.
final class WindowScanner: ObservableObject {
    @Published var windows: [WindowInfo] = []

    private var timer: Timer?
    /// Stabile Reihenfolge der Buttons (per WindowID)
    private var stableOrder: [WindowID] = []
    /// Nach Toggle: erwarteter Zustand für kurze Zeit (unterdrückt “Springen”).
    var pendingStates: [AXUIElement: (minimized: Bool, isMain: Bool, timestamp: Date)] = [:]

    // MARK: - Start/Stop
    func startAutoScan(interval: TimeInterval = 0.12) {
        stopAutoScan()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.scanTick()
        }
        timer.tolerance = interval * 0.3
        self.timer = timer
        // Erste Ausführung sofort:
        scanTick()
    }

    func stopAutoScan() {
        timer?.invalidate()
        timer = nil
    }
    
    private func scanTick() {
        // Schweres AX/CG-Scanning NICHT auf dem Main-Thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // Der eigentliche Scan baut vollständige Liste
            let result = self.performScan()

            // UI-Update zurück auf den Main-Thread
            DispatchQueue.main.async {
                // Pending-States kurz respektieren (aktuelles Verhalten beibehalten)
                let now = Date()
                var updated = result
                for i in updated.indices {
                    if let pend = self.pendingStates[updated[i].axElement],
                       now.timeIntervalSince(pend.timestamp) < 0.35 {
                        updated[i].minimized = pend.minimized
                        updated[i].isMain = pend.isMain
                    }
                }
                self.windows = updated
            }
        }
    }
    
    /// Führt den kompletten Fenster-Scan durch und gibt die geordnete Liste zurück.
    /// ACHTUNG: Nicht auf dem Main-Thread ausführen.
    private func performScan() -> [WindowInfo] {
        let prev = self.windows  // nur gelesen, ok, da Kopie
        var windowList: [WindowInfo] = []

        for app in NSWorkspace.shared.runningApplications {
            guard let appName = app.localizedName else { continue }
            // eigene/Systemsachen filtern
            if ["Dock", "loginwindow", "Window Server", "WindowsDock"].contains(appName) { continue }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var cfWindows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &cfWindows) == .success,
                  let axWindows = cfWindows as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                // Nur „echte“ App-Fenster
                guard self.isTopLevelNormalWindow(axWindow) else { continue }

                let title = self.axString(axWindow, kAXTitleAttribute as CFString)
                let isMin = self.isMinimized(axWindow)
                let isMain = self.isMain(axWindow)
                let frame = self.getFrame(axWindow)

                // Sichtbarkeit: Nicht-minimierte nur, wenn auf einem Screen
                let intersects = NSScreen.screens.contains { $0.frame.intersects(frame) }
                if !isMin && !intersects { continue }

                // Screen-Bestimmung (Intersects -> vorherige -> main)
                let screen: NSScreen = {
                    if let s = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) { return s }
                    if let old = prev.first(where: { $0.axElement == axWindow }) { return old.screen }
                    return NSScreen.main ?? NSScreen.screens.first!
                }()

                let finalTitle = title.isEmpty ? appName : title

                // Stabile WindowID
                guard let winID = self.windowID(for: axWindow) else { continue }
                // UI-stabile UUID wiederverwenden
                let stableUUID = prev.first(where: { $0.windowID == winID })?.id ?? UUID()

                let info = WindowInfo(
                    id: stableUUID,
                    windowID: winID,
                    appName: appName,
                    title: finalTitle,
                    screen: screen,
                    axElement: axWindow,
                    minimized: isMin,
                    isMain: isMain
                )

                if !windowList.contains(where: { $0.windowID == winID }) {
                    windowList.append(info)
                }
            }
        }

        // Reihenfolge stabil halten (stableOrder enthält WindowID)
        var updated: [WindowInfo] = []

        // 1) alte Reihenfolge beibehalten
        for id in self.stableOrder {
            if let w = windowList.first(where: { $0.windowID == id }) {
                updated.append(w)
            }
        }
        // 2) neue ans Ende + in stableOrder aufnehmen
        for w in windowList {
            if !self.stableOrder.contains(w.windowID) {
                updated.append(w)
                self.stableOrder.append(w.windowID)
            }
        }
        // 3) geschlossene aus stableOrder entfernen
        self.stableOrder.removeAll { id in
            !windowList.contains(where: { $0.windowID == id })
        }

        return updated
    }


    // MARK: - Toggle (Minimieren / Wiederherstellen / Vordergrund)
    @MainActor
    func toggleWindow(_ window: WindowInfo) {
        // Theme sicher auf dem MainActor lesen
        let theme = AppTheme.shared

        let axWindow = window.axElement

        // Aktuellen Zustand lesen
        var minRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minRef)
        let isMin = (minRef as? Bool) ?? false

        var mainRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXMainAttribute as CFString, &mainRef)
        let isMain = (mainRef as? Bool) ?? false

        var pid: pid_t = 0
        AXUIElementGetPid(axWindow, &pid)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }

        // Optimistisch sofort im UI spiegeln (verhindert visuelles „Springen“)
        if let idx = windows.firstIndex(where: { $0.windowID == window.windowID }) {
            windows[idx].minimized = !isMin
            windows[idx].isMain = !isMain
        }

        if isMin {
            // Wiederherstellen + nach vorn
            _ = AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            _ = AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            app.activate(options: [.activateAllWindows])
        } else {
            // Minimieren – robust mit Fallbacks
            var didMinimize = false

            // 1) Direktes Setzen des Minimized-Attributes
            if AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
                didMinimize = true
            } else {
                // 2) Minimize-Button drücken (falls vorhanden)
                var btnRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXMinimizeButtonAttribute as CFString, &btnRef) == .success,
                   let raw = btnRef {
                    let btn = unsafeBitCast(raw, to: AXUIElement.self)
                    if AXUIElementPerformAction(btn, kAXPressAction as CFString) == .success {
                        didMinimize = true
                    }
                }
            }

            // 3) AppleScript-Fallback (nur wenn 1+2 scheitern)
            if !didMinimize {
                _ = minimizeViaAppleScript(pid: pid)
            }
        }

        // Pending-State kurz puffern (Scan respektiert das eine Weile)
        pendingStates[axWindow] = (!isMin, !isMain, Date())

        // Nach kurzer Gnadenfrist die App-Fenster frisch einlesen (stabilisiert Status)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(theme.taskbar.pendingGrace * 1_000_000_000))
            self.refreshApp(pid: pid, grace: theme.taskbar.pendingGrace)
        }
    }
    
    /*
    // MARK: - Scan
    private func scanWindows() {
        let theme = AppTheme.shared
        let prev = windows  // Snapshot für UUID-Reuse / Screen-Fallback
        var next: [WindowInfo] = []

        for app in NSWorkspace.shared.runningApplications {
            guard let appName = app.localizedName else { continue }
            // eigene / System-Apps ausblenden
            if ["Dock", "loginwindow", "Window Server", "WindowsDock"].contains(appName) { continue }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var cfWindows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &cfWindows) == .success,
                  let axWindows = cfWindows as? [AXUIElement] else { continue }

            for w in axWindows {
                guard isTopLevelNormalWindow(w) else { continue }

                let title = axString(w, kAXTitleAttribute as CFString)
                let isMin = isMinimized(w)
                let isMain = isMainWindow(w)
                let frame = getFrame(w)

                // Minimierte: behalten wir immer; nicht minimierte nur wenn sichtbar auf einem Screen
                let intersects = NSScreen.screens.contains { $0.frame.intersects(frame) }
                if !isMin && !intersects { continue }

                let screen: NSScreen = {
                    if let s = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) { return s }
                    if let old = prev.first(where: { $0.axElement == w }) { return old.screen }
                    return NSScreen.main ?? NSScreen.screens.first!
                }()

                let winTitle = title.isEmpty ? appName : title

                guard let winID = windowID(for: w) else { continue }
                let stableUUID = prev.first(where: { $0.windowID == winID })?.id ?? UUID()

                let info = WindowInfo(
                    id: stableUUID,
                    windowID: winID,
                    appName: appName,
                    title: winTitle,
                    screen: screen,
                    axElement: w,
                    minimized: isMin,
                    isMain: isMain
                )

                if !next.contains(where: { $0.windowID == winID }) {
                    next.append(info)
                }
            }
        }

        // Reihenfolge stabil halten + Pending berücksichtigen
        var updated: [WindowInfo] = []
        for id in stableOrder {
            if let w = next.first(where: { $0.windowID == id }) {
                updated.append(w)
            }
        }
        for w in next where !stableOrder.contains(w.windowID) {
            updated.append(w)
            stableOrder.append(w.windowID)
        }
        stableOrder.removeAll { id in
            !next.contains(where: { $0.windowID == id })
        }

        // Pending-State (frisch) dominieren lassen
        let now = Date()
        for (i, w) in updated.enumerated() {
            if let pend = pendingStates[w.axElement], now.timeIntervalSince(pend.timestamp) < theme.taskbar.pendingGrace {
                updated[i].minimized = pend.minimized
                updated[i].isMain = pend.isMain
            }
        }

        // Keine Animationen → kein “Zucken”
        windows = updated
    }
     */

    // MARK: - Mini-Refresh nach Toggle (App-weit)
    @MainActor
    private func refreshApp(pid: pid_t, grace: TimeInterval) {
        let now = Date()
        for i in windows.indices {
            var p: pid_t = 0
            AXUIElementGetPid(windows[i].axElement, &p)
            guard p == pid else { continue }

            let w = windows[i].axElement

            var minRef: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minRef)
            let isMin = (minRef as? Bool) ?? false

            var mainRef: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXMainAttribute as CFString, &mainRef)
            let isMain = (mainRef as? Bool) ?? false

            if let pend = pendingStates[w], now.timeIntervalSince(pend.timestamp) < grace {
                // noch in Grace → pending behalten
                continue
            } else {
                windows[i].minimized = isMin
                windows[i].isMain = isMain
                pendingStates[w] = nil
            }
        }
    }

    // MARK: - Helpers (AX / CG)
    private func axString(_ el: AXUIElement, _ attr: CFString) -> String {
        var ref: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(el, attr, &ref)
        return (r == .success) ? (ref as? String ?? "") : ""
    }

    private func getFrame(_ el: AXUIElement) -> CGRect {
        var frame = CGRect.zero
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, "AXFrame" as CFString, &ref)
        if let r = ref, CFGetTypeID(r) == AXValueGetTypeID() {
            let axVal = unsafeBitCast(r, to: AXValue.self)
            AXValueGetValue(axVal, .cgRect, &frame)
        }
        return frame
    }

    private func isMinimized(_ el: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXMinimizedAttribute as CFString, &ref)
        return (ref as? Bool) ?? false
    }

    private func isMainWindow(_ el: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXMainAttribute as CFString, &ref)
        return (ref as? Bool) ?? false
    }
    
    // Back-Compat: alias, damit Aufrufer `isMain(...)` nutzen können
    @inline(__always)
    private func isMain(_ el: AXUIElement) -> Bool {
        // direkt den vorhandenen Helper verwenden
        return isMainWindow(el)
    }

    /// Nur echte App-Hauptfenster (keine Tabs/Sheets/Popover/Transient)
    private func isTopLevelNormalWindow(_ w: AXUIElement) -> Bool {
        let role = axString(w, kAXRoleAttribute as CFString)
        guard role == (kAXWindowRole as String) else { return false }
        let sub = axString(w, kAXSubroleAttribute as CFString)
        if sub.isEmpty { return true }
        return ["AXStandardWindow", "AXDocumentWindow"].contains(sub)
    }

    /// Stabile WindowID: AXWindowNumber → sonst CGWindowList-Matching → Pointer-Fallback
    private func windowID(for el: AXUIElement) -> WindowID? {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)

        // 1) AXWindowNumber (der bevorzugte Weg)
        var numRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXWindowNumber" as CFString, &numRef) == .success,
           let n = (numRef as? NSNumber)?.intValue {
            return WindowID(pid: pid, windowNumber: n)
        }

        // 2) CGWindowList-Matching (PID + Bounds/Titel)
        let titleAX = axString(el, kAXTitleAttribute as CFString)
        let frameAX = getFrame(el)

        if let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for entry in list {
                guard let entryPid = entry[kCGWindowOwnerPID as String] as? pid_t, entryPid == pid,
                      let wnum = entry[kCGWindowNumber as String] as? Int else { continue }

                if let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                   let x = bounds["X"] as? CGFloat,
                   let y = bounds["Y"] as? CGFloat,
                   let w = bounds["Width"] as? CGFloat,
                   let h = bounds["Height"] as? CGFloat {
                    let rect = CGRect(x: x, y: y, width: w, height: h)
                    if approxEqual(rect, frameAX, epsilon: 4.0) {
                        return WindowID(pid: pid, windowNumber: wnum)
                    }
                }

                if !titleAX.isEmpty, let name = entry[kCGWindowName as String] as? String, name == titleAX {
                    return WindowID(pid: pid, windowNumber: wnum)
                }
            }
        }

        // 3) Fallback: Pointer
        let ptr = Int(bitPattern: Unmanaged.passUnretained(el).toOpaque())
        return WindowID(pid: pid, windowNumber: ptr)
    }

    private func approxEqual(_ a: CGRect, _ b: CGRect, epsilon: CGFloat) -> Bool {
        abs(a.origin.x - b.origin.x) <= epsilon &&
        abs(a.origin.y - b.origin.y) <= epsilon &&
        abs(a.size.width - b.size.width) <= epsilon &&
        abs(a.size.height - b.size.height) <= epsilon
    }

    // MARK: - AppleScript Fallback (nur wenn AX-Minimize/Minimize-Button versagen)
    @discardableResult
    private func minimizeViaAppleScript(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let appName = app.localizedName else { return false }

        let script = """
        tell application "System Events"
            try
                tell process "\(appName)"
                    if (count of windows) > 0 then
                        click (first button whose subrole is "AXMinimizeButton") of (first window whose visible is true)
                        return true
                    end if
                end tell
                return false
            on error
                return false
            end try
        end tell
        """

        guard let scpt = NSAppleScript(source: script) else { return false }
        var err: NSDictionary?
        let res = scpt.executeAndReturnError(&err)
        if let err { print("AppleScript Error: \(err)") }
        return res.booleanValue
    }
}
