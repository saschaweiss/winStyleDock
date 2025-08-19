// Services/WindowScanner.swift
import Foundation
import Cocoa
import ApplicationServices
import Collections

@MainActor
final class WindowScanner: ObservableObject {
    @Published var windows: [WindowInfo] = []

    private var timer: Timer?
    private var scanInterval: TimeInterval = 0.12

    /// Reihenfolge stabil halten
    private var stableOrder = OrderedSet<WindowID>()

    /// Pending-UI (Entprellung)
    var pendingStates: [AXUIElement: (minimized: Bool, isMain: Bool, timestamp: Date)] = [:]

    /// Scans nicht überlappen lassen
    private var isScanInFlight = false

    private let pendingGrace: TimeInterval = 0.35

    // MARK: - Singleton
    static let shared = WindowScanner()

    // MARK: - Start/Stop
    func start(interval: TimeInterval = 0.12) {
        stop()
        scanInterval = interval

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.scanTick() }
        }
        timer?.tolerance = interval * 0.3
        RunLoop.current.add(timer!, forMode: .common)

        Task { @MainActor in self.scanTick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    private func scanTick() {
        // Überlappende Scans vermeiden
        if isScanInFlight { return }
        isScanInFlight = true

        // Alles MainActor-gebundene vorab abgreifen
        let prev  = self.windows
        let order = self.stableOrder
        let grace = self.pendingGrace

        // Teure CGWindowList einmalig für diesen Tick
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let cgInfo = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                          as? [[String: Any]]) ?? []

            let (updated, newOrder) = ScanUtil.performScan(prev: prev,
                                                           order: Array(order),
                                                           cgInfo: cgInfo)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stableOrder = OrderedSet(newOrder)

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
                self.isScanInFlight = false
            }
        }
    }

    // MARK: - Toggle (Minimieren / Wiederherstellen / Vordergrund)
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

        // Optimistisch sofort im UI spiegeln
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

            if AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
                didMinimize = true
            } else {
                var btnRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXMinimizeButtonAttribute as CFString, &btnRef) == .success,
                   let raw = btnRef {
                    let btn = unsafeBitCast(raw, to: AXUIElement.self)
                    if AXUIElementPerformAction(btn, kAXPressAction as CFString) == .success {
                        didMinimize = true
                    }
                }
            }

            if !didMinimize {
                _ = minimizeViaAppleScript(pid: pid)
            }
        }

        // Pending-State puffern
        pendingStates[axWindow] = (!isMin, !isMain, Date())

        // Kleiner verzögerter Refresh (stabilisiert den Status nach Toggle)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) { [weak self, pid] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.refreshApp(pid: pid, grace: self.pendingGrace)
            }
        }
    }

    // MARK: - Mini-Refresh nach Toggle (App-weit)
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
                continue
            } else {
                windows[i].minimized = isMin
                windows[i].isMain = isMain
                pendingStates[w] = nil
            }
        }
    }
    
    // Services/WindowScanner.swift  (innerhalb von class WindowScanner)
    @discardableResult
    private func minimizeViaAppleScript(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let appName = app.localizedName else { return false }

        // Versucht zuerst den AX-Minimize-Button des sichtbaren Fensters zu klicken.
        // Fallback: CMD+M per "System Events" (benötigt Bedienungshilfen/Automation).
        let script = """
        tell application "System Events"
            try
                tell process "\(appName)"
                    if (count of windows) > 0 then
                        set frontmost to true
                        try
                            click (first button whose subrole is "AXMinimizeButton") of (first window whose visible is true)
                        on error
                            keystroke "m" using {command down}
                        end try
                        return true
                    end if
                end tell
                return false
            on error
                return false
            end try
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else { return false }
        var errorDict: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDict)
        if let err = errorDict {
            NSLog("AppleScript minimize error for \(appName): \(err)")
        }
        return result.booleanValue
    }
}

// MARK: - Off-main Scan Utility
fileprivate enum ScanUtil {
    // Debug-Flags
    private static let DEBUG_VERBOSE = false           // Fenster-Details pro Tick
    private static let RELAX_ROLE_FILTER = false       // in DEV ggf. true setzen

    // Sichtbarer einmal-Log pro PID (wenn AX nicht zugreifbar)
    private static var warnedPIDs = Set<pid_t>()

    /// Führt den kompletten Fenster-Scan aus (off-main!)
    static func performScan(prev: [WindowInfo],
                            order: [WindowID],
                            cgInfo: [[String: Any]]) -> (updated: [WindowInfo], newOrder: [WindowID]) {

        var windowList: [WindowInfo] = []

        let selfPid: pid_t = getpid()
        let selfBundleID = Bundle.main.bundleIdentifier
        let selfAppName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ""

        for app in NSWorkspace.shared.runningApplications {
            guard let appName = app.localizedName else { continue }

            if ["Dock", "loginwindow", "Window Server"].contains(appName) { continue }
            if app.processIdentifier == selfPid { continue }
            if let bid = app.bundleIdentifier, let selfBid = selfBundleID, bid == selfBid { continue }
            if !selfAppName.isEmpty && appName == selfAppName { continue }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var cfWindows: CFTypeRef?
            let axErr = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &cfWindows)
            guard axErr == .success, let axWindows = cfWindows as? [AXUIElement] else {
                // nur 1x pro PID warnen
                if !warnedPIDs.contains(app.processIdentifier) {
                    warnedPIDs.insert(app.processIdentifier)
                    if app.activationPolicy == .regular,
                       (app.localizedName?.range(of: "Helper", options: .caseInsensitive) == nil) {
                        NSLog("⚪️ \(app.localizedName ?? "?"): kAXWindowsAttribute not accessible (pid \(app.processIdentifier))")
                    }
                }
                continue
            }

            if DEBUG_VERBOSE {
                NSLog("🔹 \(appName): \(axWindows.count) AX windows")
            }

            for axWindow in axWindows {
                if DEBUG_VERBOSE {
                    let dbgTitle = axString(axWindow, kAXTitleAttribute as CFString)
                    let dbgRole  = axString(axWindow, kAXRoleAttribute as CFString)
                    let dbgSub   = axString(axWindow, kAXSubroleAttribute as CFString)
                    NSLog("   • title='\(dbgTitle)' role='\(dbgRole)' subrole='\(dbgSub)'")
                }

                // Skip our own process windows (Panels/Settings)
                var winPid: pid_t = 0
                AXUIElementGetPid(axWindow, &winPid)
                if winPid == selfPid { continue }

                guard isTopLevelNormalWindow(axWindow) else { continue }

                let title = axString(axWindow, kAXTitleAttribute as CFString)
                let isMin  = isMinimized(axWindow)
                let isMain = isMainWindow(axWindow)
                let frame  = getFrame(axWindow)

                // Nur sichtbare nicht-minimierte
                let intersects = NSScreen.screens.contains { $0.frame.intersects(frame) }
                if !isMin && !intersects { continue }

                // 1) stabile ID – jetzt mit bereits bereitgestellter cgInfo (kein weiterer System-Call)
                guard let winID = windowID(for: axWindow, cgInfo: cgInfo) else { continue }

                // 2) Screen
                let screen: NSScreen = {
                    if let s = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) { return s }
                    if let old = prev.first(where: { $0.windowID == winID }) { return old.screen }
                    return NSScreen.main ?? NSScreen.screens.first!
                }()

                let finalTitle = title.isEmpty ? appName : title
                let stableUUID = prev.first(where: { $0.windowID == winID })?.id ?? UUID()

                let info = WindowInfo(
                    id: stableUUID,
                    windowID: winID,
                    appName: appName,
                    title: finalTitle,
                    displayID: displayID(for: screen),
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

        for id in order {
            if let w = windowList.first(where: { $0.windowID == id }) {
                updated.append(w)
            }
        }
        for w in windowList where !newOrder.contains(w.windowID) {
            updated.append(w)
            newOrder.append(w.windowID)
        }

        return (updated, newOrder)
    }

    // MARK: - Helpers (off-main)
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
        if RELAX_ROLE_FILTER { return true }
        let role = axString(w, kAXRoleAttribute as CFString)
        guard role == (kAXWindowRole as String) else { return false }
        let sub = axString(w, kAXSubroleAttribute as CFString)
        let excluded: Set<String> = [
            "AXSheet", "AXSystemDialog", "AXDialog",
            "AXPopover", "AXFloatingWindow", "AXUnknown"
        ]
        if sub.isEmpty { return true }
        return !excluded.contains(sub)
    }

    /// Nutzt **die bereits übergebene cgInfo** (keine weiteren System-Calls pro Fenster!)
    private static func windowID(for el: AXUIElement, cgInfo: [[String: Any]]) -> WindowID? {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)

        var numRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXWindowNumber" as CFString, &numRef) == .success,
           let n = (numRef as? NSNumber)?.intValue {
            return WindowID(pid: pid, windowNumber: n)
        }

        let titleAX = axString(el, kAXTitleAttribute as CFString)
        let frameAX = getFrame(el)

        for entry in cgInfo {
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

        let ptr = Int(bitPattern: Unmanaged.passUnretained(el).toOpaque())
        return WindowID(pid: pid, windowNumber: ptr)
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let num = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
        return CGDirectDisplayID(num)
    }

    private static func approxEqual(_ a: CGRect, _ b: CGRect, epsilon: CGFloat) -> Bool {
        abs(a.origin.x - b.origin.x) <= epsilon &&
        abs(a.origin.y - b.origin.y) <= epsilon &&
        abs(a.size.width - b.size.width) <= epsilon &&
        abs(a.size.height - b.size.height) <= epsilon
    }
}
