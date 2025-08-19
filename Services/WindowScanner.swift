// Services/WindowScanner.swift
import Foundation
import Cocoa
import ApplicationServices

/// Scannt regelmäßig alle Top-Level-Fenster, hält eine stabile Reihenfolge je Fenster (WindowID),
/// liefert minimierte Fenster weiterhin aus, gruppiert NICHT (UI erledigt das),
/// und puffert UI-Zustände kurz (pendingStates), um Flackern zu verhindern.
///
/// Achtung: Der eigentliche AX/CG-Scan läuft im Hintergrund-Thread.
/// Das Zurückschreiben in `windows` passiert immer auf dem MainActor.
@MainActor
final class WindowScanner: ObservableObject {
    @Published var windows: [WindowInfo] = []

    private var timer: Timer?
    private var scanInterval: TimeInterval = 0.12

    /// Stabile Reihenfolge der Buttons (per WindowID – kommt aus Core/Models/WindowInfo.swift)
    private var stableOrder: [WindowID] = []

    /// Nach Toggle: erwarteter Zustand für kurze Zeit (unterdrückt “Springen”).
    var pendingStates: [AXUIElement: (minimized: Bool, isMain: Bool, timestamp: Date)] = [:]

    private let pendingGrace: TimeInterval = 0.35
    
    // ──────────────────────────────────────────────────────────────────────
    // Public API
    // ──────────────────────────────────────────────────────────────────────
    static let shared = WindowScanner()

    func start(interval: TimeInterval = 0.12) {
        func start() {
            stop()
            let interval = AppTheme.shared.taskbar.scanInterval
            let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.scanTick()
            }
            t.tolerance = interval * 0.3
            self.timer = t
            print("🔎 WindowScanner started (interval=\(interval)s)")
            scanTick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    // Backward-compat aliases – optional
    @MainActor
    func startAutoScan(interval: TimeInterval = 0.12) {
        start(interval: interval)
    }

    @MainActor
    func stopAutoScan() {
        stop()
    }

    /// Minimieren / Wiederherstellen / Vordergrund holen (mit Fallbacks).
    func toggleWindow(_ window: WindowInfo) {
        let axWindow = window.axElement

        // Zustand lesen
        var minRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minRef)
        let isMin = (minRef as? Bool) ?? false

        var mainRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXMainAttribute as CFString, &mainRef)
        let isMain = (mainRef as? Bool) ?? false

        var pid: pid_t = 0
        AXUIElementGetPid(axWindow, &pid)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }

        // Optimistisch sofort ins UI spiegeln (entprellt später)
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

            // 1) Direktes Setzen des Attributes
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

            // 3) AppleScript-Fallback, nur wenn 1+2 scheitern
            if !didMinimize {
                _ = minimizeViaAppleScript(pid: pid)
            }
        }

        // Pending-State kurz puffern (Scan respektiert das eine Weile)
        pendingStates[axWindow] = (!isMin, !isMain, Date())

        // Nach kurzer Gnadenfrist App-weit refreshen (stabilisiert Status)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(pendingGrace * 1_000_000_000))
            self.refreshApp(pid: pid, grace: pendingGrace)
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // Private
    // ──────────────────────────────────────────────────────────────────────
    /// Ein Timer-Tick: performScan im Hintergrund, anschließend windows am MainActor setzen.
    @MainActor
    private func scanTick() {
        // Alles, was MainActor-gebunden ist, JETZT abgreifen und dann im Hintergrund arbeiten
        let prev        = self.windows
        let order       = self.stableOrder
        let grace       = AppTheme.shared.taskbar.pendingGrace

        // Hintergrund-Task OHNE Capture von `self`
        Task.detached(priority: .userInitiated) {
            // Schweres Scannen off-main
            let (updated, newOrder) = ScanUtil.performScan(prev: prev, order: order)

            // Ergebnis sicher auf den MainActor zurückschreiben
            await MainActor.run {
                self.stableOrder = newOrder

                // Pending-States respektieren (Entprellung)
                var final = updated
                let now = Date()
                for i in final.indices {
                    if let pend = self.pendingStates[final[i].axElement],
                       now.timeIntervalSince(pend.timestamp) < grace {
                        final[i].minimized = pend.minimized
                        final[i].isMain    = pend.isMain
                    }
                }
                self.windows = final
            }
        }
    }

    /// Führt den kompletten Fenster-Scan durch und gibt die geordnete Liste zurück.
    /// NICHT am Main-Thread aufrufen.
    private func performScan() -> [WindowInfo] {
        let prev = self.windows
        var windowList: [WindowInfo] = []

        // Eigene App dynamisch bestimmen und ausblenden
        let selfAppName = NSRunningApplication.current.localizedName ?? Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "winstyledock"

        // Debug: sind wir “trusted”?
        let trusted = AXIsProcessTrusted()
        if !trusted {
            print("⚠️ AXIsProcessTrusted() == false – Accessibility-Rechte fehlen oder wurden nicht bestätigt.")
        }

        for app in NSWorkspace.shared.runningApplications {
            guard let appName = app.localizedName else { continue }
            // System + eigene App herausfiltern
            if ["Dock", "loginwindow", "Window Server"].contains(appName) { continue }
            if appName == selfAppName { continue }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var cfWindows: CFTypeRef?
            let winErr = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &cfWindows)
            guard winErr == .success, let axWindows = cfWindows as? [AXUIElement] else {
                // Debug
                // print("ℹ️ \(appName): kAXWindowsAttribute -> \(winErr)")
                continue
            }

            // Debug: Anzahl Fenster per App
            // print("🔹 \(appName): \(axWindows.count) AX windows")

            for axWindow in axWindows {
                // Titel holen – wenn leer, ist es meist kein echtes Fenster
                let title = self.axString(axWindow, kAXTitleAttribute as CFString)
                if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }

                // Rolle/Subrolle – wenn nicht lesbar, nicht hart rausfiltern!
                let role = self.axString(axWindow, kAXRoleAttribute as CFString)
                let sub  = self.axString(axWindow, kAXSubroleAttribute as CFString)

                // Entspannter Filter: akzeptiere, wenn (role leer ODER role==Window) UND (sub leer ODER Standard/Document)
                let roleLooksLikeWindow = role.isEmpty || role == (kAXWindowRole as String)
                let subLooksFine = sub.isEmpty || ["AXStandardWindow", "AXDocumentWindow"].contains(sub)
                if !(roleLooksLikeWindow && subLooksFine) {
                    // Debug
                    // print("   ↪︎ skip (role=\(role), sub=\(sub), title=\(title))")
                    continue
                }

                let isMin = self.isMinimized(axWindow)
                let isMain = self.isMainWindow(axWindow)
                let frame = self.getFrame(axWindow)

                // Sichtbarkeit: Nicht-minimierte nur, wenn auf einem Screen sichtbar
                let intersects = NSScreen.screens.contains { $0.frame.intersects(frame) }
                if !isMin && !intersects { continue }

                // Screen ermitteln (Intersects → vorheriger → main)
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

        // Reihenfolge stabil halten
        var updated: [WindowInfo] = []
        for id in self.stableOrder {
            if let w = windowList.first(where: { $0.windowID == id }) {
                updated.append(w)
            }
        }
        for w in windowList {
            if !self.stableOrder.contains(w.windowID) {
                updated.append(w)
                self.stableOrder.append(w.windowID)
            }
        }
        self.stableOrder.removeAll { id in
            !windowList.contains(where: { $0.windowID == id })
        }

        // Debug Summaries pro Screen
        #if DEBUG
        let byScreen = Dictionary(grouping: updated, by: { $0.screen })
        for (scr, arr) in byScreen {
            let num = (scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            print("🟦 Screen \(num): \(arr.count) Fenster")
            // arr.forEach { print("   • \($0.appName) — \($0.title)") }
        }
        #endif

        return updated
    }

    // Mini-Refresh nach Toggle (App-weit)
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

    // ──────────────────────────────────────────────────────────────────────
    // AX/CG Helpers
    // ──────────────────────────────────────────────────────────────────────
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

    /// Nur echte App-Hauptfenster (keine Tabs/Sheets/Popover/Transient)
    private func isTopLevelNormalWindow(_ w: AXUIElement) -> Bool {
        let role = axString(w, kAXRoleAttribute as CFString)
        guard role == (kAXWindowRole as String) else { return false }
        let sub = axString(w, kAXSubroleAttribute as CFString)
        if sub.isEmpty { return true }
        return ["AXStandardWindow", "AXDocumentWindow"].contains(sub)
    }

    /// Stabile WindowID: AXWindowNumber → CGWindowList-Matching → Pointer-Fallback
    private func windowID(for el: AXUIElement) -> WindowID? {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)

        // 1) AXWindowNumber (bevorzugt)
        var numRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXWindowNumber" as CFString, &numRef) == .success,
           let n = (numRef as? NSNumber)?.intValue {
            return WindowID(pid: pid, windowNumber: n)
        }

        // 2) CGWindowList-Matching
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

    // AppleScript-Fallback (nur wenn AX-Minimize/Minimize-Button versagen)
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

// MARK: - Off-main Scan Utility (kein @MainActor!)
fileprivate enum ScanUtil {
    static func performScan(prev: [WindowInfo], order: [WindowID]) -> (updated: [WindowInfo], newOrder: [WindowID]) {
        var windowList: [WindowInfo] = []
        
        // Exclude our own app by PID/Bundle/Name
        let selfPid: pid_t = getpid()
        let selfBundleID = Bundle.main.bundleIdentifier
        let selfAppName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ""

        for app in NSWorkspace.shared.runningApplications {
            guard let appName = app.localizedName else { continue }
            
            // System apps and our own process
            if ["Dock", "loginwindow", "Window Server"].contains(appName) { continue }
            if app.processIdentifier == selfPid { continue }
            if let bid = app.bundleIdentifier, let selfBid = selfBundleID, bid == selfBid { continue }
            if !selfAppName.isEmpty && appName == selfAppName { continue }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var cfWindows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &cfWindows) == .success,
                  let axWindows = cfWindows as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                // Skip windows that belong to our own process (panels, settings, etc.)
                var winPid: pid_t = 0
                AXUIElementGetPid(axWindow, &winPid)
                if winPid == selfPid { continue }

                // Lockerer Filter für echte App-Fenster (Tabs sind keine eigenen Windows)
                guard isTopLevelNormalWindow(axWindow) else { continue }

                // Zustand lesen
                let title = axString(axWindow, kAXTitleAttribute as CFString)
                let isMin = isMinimized(axWindow)
                let isMain = isMainWindow(axWindow)
                let frame = getFrame(axWindow)

                // Nicht-minimierte nur, wenn auf einem Screen sichtbar
                let intersects = NSScreen.screens.contains { $0.frame.intersects(frame) }
                if !isMin && !intersects { continue }

                // 1) Stabile WindowID **zuerst** bestimmen
                guard let winID = windowID(for: axWindow) else { continue }

                // 2) Screen wählen: sichtbar → vorheriger (über windowID) → main
                let screen: NSScreen = {
                    if let s = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) { return s }
                    if let old = prev.first(where: { $0.windowID == winID }) { return old.screen }
                    return NSScreen.main ?? NSScreen.screens.first!
                }()

                let finalTitle = title.isEmpty ? appName : title

                // Stabile WindowID
                guard let winID = windowID(for: axWindow) else { continue }
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

        // Reihenfolge stabil halten
        var updated: [WindowInfo] = []
        var newOrder = order.filter { id in windowList.contains(where: { $0.windowID == id }) }

        // 1) alte Reihenfolge
        for id in order {
            if let w = windowList.first(where: { $0.windowID == id }) {
                updated.append(w)
            }
        }
        // 2) neue ans Ende
        for w in windowList {
            if !newOrder.contains(w.windowID) {
                updated.append(w)
                newOrder.append(w.windowID)
            }
        }

        return (updated, newOrder)
    }

    // ---------- Helper (off-main, ohne Actor-Abhängigkeit) ----------

    private static func axString(_ el: AXUIElement, _ attr: CFString) -> String {
        var ref: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(el, attr, &ref)
        return (r == .success) ? (ref as? String ?? "") : ""
    }

    private static func getFrame(_ el: AXUIElement) -> CGRect {
        var frame = CGRect.zero
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, "AXFrame" as CFString, &ref)
        if let r = ref, CFGetTypeID(r) == AXValueGetTypeID() {
            let axVal = unsafeBitCast(r, to: AXValue.self)
            AXValueGetValue(axVal, .cgRect, &frame)
        }
        return frame
    }

    private static func isMinimized(_ el: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXMinimizedAttribute as CFString, &ref)
        return (ref as? Bool) ?? false
    }

    private static func isMainWindow(_ el: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXMainAttribute as CFString, &ref)
        return (ref as? Bool) ?? false
    }

    private static func isTopLevelNormalWindow(_ w: AXUIElement) -> Bool {
        let role = axString(w, kAXRoleAttribute as CFString)
        guard role == (kAXWindowRole as String) else { return false }
        let sub = axString(w, kAXSubroleAttribute as CFString)
        // Erlaube reguläre Fenster; schließe nur typische Nicht-Hauptfenster aus
        let excluded: Set<String> = [
            "AXSheet",
            "AXSystemDialog",
            "AXDialog",
            "AXPopover",
            "AXFloatingWindow",
            "AXUnknown"
        ]
        if sub.isEmpty { return true }
        return !excluded.contains(sub)
    }

    private static func windowID(for el: AXUIElement) -> WindowID? {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)

        var numRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXWindowNumber" as CFString, &numRef) == .success,
           let n = (numRef as? NSNumber)?.intValue {
            return WindowID(pid: pid, windowNumber: n)
        }

        // Fallback via CGWindowList (PID + Bounds/Titel)
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

        // Letzter Fallback: Pointer
        let ptr = Int(bitPattern: Unmanaged.passUnretained(el).toOpaque())
        return WindowID(pid: pid, windowNumber: ptr)
    }

    private static func approxEqual(_ a: CGRect, _ b: CGRect, epsilon: CGFloat) -> Bool {
        abs(a.origin.x - b.origin.x) <= epsilon &&
        abs(a.origin.y - b.origin.y) <= epsilon &&
        abs(a.size.width - b.size.width) <= epsilon &&
        abs(a.size.height - b.size.height) <= epsilon
    }
}
