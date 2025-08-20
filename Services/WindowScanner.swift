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
    
    // ↓ direkt unter den bestehenden Properties einfügen
    private var lastScreenCount: [CGDirectDisplayID: Int] = [:]
    private var lastScreenLogAt: Date = .distantPast
    private let screenLogMinInterval: TimeInterval = 1.0

    /// Reihenfolge stabil halten
    private var stableOrder = OrderedSet<WindowID>()

    /// Pending-UI (Entprellung)
    var pendingStates: [AXUIElement: (minimized: Bool, isMain: Bool, timestamp: Date)] = [:]
    
    // --- Debounce gegen Flackern ---
    private var seenCount: [WindowID: Int] = [:]      // wie oft in Folge gesehen
    private var missCount: [WindowID: Int] = [:]      // wie oft in Folge NICHT gesehen

    /// Ab wann ein NEUES Fenster wirklich aufgenommen wird (Scans in Folge)
    private let appearThreshold = 2     // 2 Scans ≈ ~240ms bei 120ms Intervall

    /// Ab wann ein NICHT mehr gesehenes Fenster wirklich entfernt wird
    private let disappearThreshold = 3  // 3 Scans ≈ ~360ms

    // Titel-Entprellung
    private var lastTitle: [WindowID: String] = [:]
    private var titleStableCount: [WindowID: Int] = [:]
    private let titleConfirmScans = 2   // Titel muss in 2 Scans stabil sein, bevor wir UI updaten

    /// Scans nicht überlappen lassen
    private var isScanInFlight = false

    private let pendingGrace: TimeInterval = 0.35
    
    /// Per-PID AXObserver, damit wir Fokus/Minimize/WindowCreate-Events bekommen
    private var observers: [pid_t: AXObserver] = [:]
    
    /// Workspace-Observer für App-Start/-Ende
    private var wsLaunchObs: NSObjectProtocol?
    private var wsTerminateObs: NSObjectProtocol?
    
    // --- Anti-Flackern: Sichtbarkeits-Hysterese ---
    private var firstSeenAt: [WindowID: Date] = [:]   // erstes Auftauchen
    private var lastSeenAt:  [WindowID: Date] = [:]   // letztes Mal gesehen

    /// Wie lange ein neues Fenster stabil "gesehen" sein muss, bevor wir es anzeigen
    private let appearConfirm: TimeInterval = 0.25

    /// Wie lange ein verschwundenes Fenster fehlen darf, bevor wir es ausblenden
    private let vanishGrace: TimeInterval = 0.40

    // MARK: - Singleton
    static let shared = WindowScanner()

    // MARK: - Start/Stop
    func start(interval: TimeInterval = 0.12) {
        stop()
        scanInterval = interval
        prewarm()
        
        // AX-Events für bereits laufende Apps
        registerAXObserversForRunningApps()

        // Wenn neue Apps starten oder beendet werden → Observer (de)registrieren
        wsLaunchObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.registerAXObserver(for: app)
        }

        wsTerminateObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.unregisterAXObserver(forPID: app.processIdentifier)
        }

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
        
        if let o = wsLaunchObs { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = wsTerminateObs { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        wsLaunchObs = nil
        wsTerminateObs = nil

        for (_, obs) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observers.removeAll()
    }
    
    /// Führt sofort einen vollständigen Scan aus und setzt `windows` direkt.
    /// Verhindert, dass die ersten Buttons erst nach dem ersten Timer-Tick erscheinen.
    @MainActor
    func prewarm() {
        // Kleines Timeout, damit wir bei „zickigen“ Apps nicht hängen
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.05)
        // performScan läuft off-main – wir triggern den Weg über scanTick(),
        // damit Reihenfolge/Pending-Logik umgangen wird.
        self.scanTick()
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
                self.logScreenCountsIfChanged(final) // <- NEU
                self.isScanInFlight = false
            }
        }
    }

    // MARK: - Toggle (Minimieren / Wiederherstellen / Vordergrund)
    @MainActor
    func toggleWindow(_ window: WindowInfo) {
        let ax = window.axElement

        // Zustand lesen
        var minRef: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &minRef)
        let isMin = (minRef as? Bool) ?? false

        if isMin {
            _ = WindowSystem.backend.restore(axElement: ax)
        } else {
            // Wenn es Main/aktiv ist → minimieren, sonst in den Vordergrund
            var mainRef: CFTypeRef?
            AXUIElementCopyAttributeValue(ax, kAXMainAttribute as CFString, &mainRef)
            let isMain = (mainRef as? Bool) ?? false

            if isMain {
                _ = WindowSystem.backend.minimize(axElement: ax)
            } else {
                _ = WindowSystem.backend.bringToFront(axElement: ax)
            }
        }

        var mainRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXMainAttribute as CFString, &mainRef)
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
            _ = AXUIElementSetAttributeValue(axElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            _ = AXUIElementSetAttributeValue(axElement, kAXMainAttribute as CFString, kCFBooleanTrue)
            app.activate(options: [.activateAllWindows])
        } else {
            // Minimieren – robust mit Fallbacks
            var didMinimize = false

            if AXUIElementSetAttributeValue(axElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
                didMinimize = true
            } else {
                var btnRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axElement, kAXMinimizeButtonAttribute as CFString, &btnRef) == .success,
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
        pendingStates[axElement] = (!isMin, !isMain, Date())

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
    
    /// Loggt pro Display die Fensteranzahl – aber nur bei Änderung und max. 1×/s.
    private func logScreenCountsIfChanged(_ windows: [WindowInfo]) {
        let now = Date()
        // Throttling
        guard now.timeIntervalSince(lastScreenLogAt) >= screenLogMinInterval else { return }

        // aktuelle Counts bauen
        var counts: [CGDirectDisplayID: Int] = [:]
        for w in windows {
            counts[w.displayID, default: 0] += 1
        }

        // nur loggen, wenn sich etwas geändert hat
        guard counts != lastScreenCount else { return }
        lastScreenCount = counts
        lastScreenLogAt = now

        // kompakt ausgeben
        let line = counts
            .sorted(by: { $0.key < $1.key })
            .map { "Screen \($0.key): \($0.value) Fenster" }
            .joined(separator: " | ")
        NSLog("🧭 \(line)")
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
    
    /// Für alle aktuell laufenden, „normalen“ Apps Observer setzen
    private func registerAXObserversForRunningApps() {
        for app in NSWorkspace.shared.runningApplications {
            registerAXObserver(for: app)
        }
    }

    /// Für genau eine App Observer setzen (falls sinnvoll)
    private func registerAXObserver(for app: NSRunningApplication) {
        guard app.activationPolicy == .regular else { return }
        guard let _ = app.localizedName else { return }
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return } // schon vorhanden

        var observer: AXObserver?
        let err = AXObserverCreate(pid, { (_, _, _, refcon) in
            // AX Callback -> auf Main hoppen → schneller kleiner Tick
            guard let refcon = refcon else { return }
            let unmanaged = Unmanaged<WindowScanner>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                unmanaged.scanTick()
            }
        }, &observer)

        guard err == .success, let obs = observer else { return }

        // typische Notifications – nicht jede App schickt alle; ist okay
        let appAX = AXUIElementCreateApplication(pid)
        func add(_ name: String) {
            let err = AXObserverAddNotification(obs, appAX, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            if err != .success {
                NSLog("AXObserverAddNotification failed for \(app.localizedName ?? "?") / \(name): \(err.rawValue)")
            }
        }

        add(kAXWindowCreatedNotification)
        add(kAXUIElementDestroyedNotification)
        add(kAXFocusedWindowChangedNotification)
        add(kAXMainWindowChangedNotification)
        add(kAXTitleChangedNotification)

        observers[pid] = obs
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    /// Observer entfernen, z. B. bei App-Terminate
    private func unregisterAXObserver(forPID pid: pid_t) {
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }
}

// MARK: - Off-main Scan Utility
fileprivate enum ScanUtil {
    // Titel-Entprellung (ScanUtil-interner Zustand)
    private static var lastTitle: [WindowID: String] = [:]
    private static var titleStableCount: [WindowID: Int] = [:]
    private static let titleConfirmScans: Int = 2

    // Debug-Flags
    private static let DEBUG_VERBOSE = false           // Fenster-Details pro Tick
    private static let RELAX_ROLE_FILTER = false       // in DEV ggf. true setzen

    // Sichtbarer einmal-Log pro PID (wenn AX nicht zugreifbar)
    private static var warnedPIDs = Set<pid_t>()

    /// Führt den kompletten Fenster-Scan aus (off-main!).
    /// Diese Utility-Funktion ist **rein funktional**: Sie hält keinen Bezug auf
    /// WindowScanner-Instanzzustand. Debounce/Pending/Grace werden außerhalb gehandhabt.
    static func performScan(prev: [WindowInfo], order: [WindowID], cgInfo: [[String: Any]]) -> (updated: [WindowInfo], newOrder: [WindowID]) {
        var windowList: [WindowInfo] = []

        let selfPid: pid_t = getpid()
        let selfBundleID = Bundle.main.bundleIdentifier
        let selfAppName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ""

        for app in NSWorkspace.shared.runningApplications {
            guard let appName = app.localizedName else { continue }

            // System und eigene App ausblenden
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
                        #if DEBUG
                        NSLog("⚪️ \(app.localizedName ?? "?"): kAXWindowsAttribute not accessible (pid \(app.processIdentifier))")
                        #endif
                    }
                }
                continue
            }

            if DEBUG_VERBOSE {
                NSLog("🔹 \(appName): \(axWindows.count) AX windows")
            }

            for axElement in axWindows {
                if DEBUG_VERBOSE {
                    let dbgTitle = axString(axElement, kAXTitleAttribute as CFString)
                    let dbgRole  = axString(axElement, kAXRoleAttribute as CFString)
                    let dbgSub   = axString(axElement, kAXSubroleAttribute as CFString)
                    NSLog("   • title='\(dbgTitle)' role='\(dbgRole)' subrole='\(dbgSub)'")
                }

                // Skip our own process windows (Panels/Settings)
                var winPid: pid_t = 0
                AXUIElementGetPid(axElement, &winPid)
                if winPid == selfPid { continue }

                guard isTopLevelNormalWindow(axElement) else { continue }

                let title = axString(axElement, kAXTitleAttribute as CFString)
                let isMin  = isMinimized(window.axElement)
                let isMain = isMainWindow(window.axElement)
                let frame  = getFrame(window.axElement)

                // Nur sichtbare nicht-minimierte Fenster; minimierte behalten wir
                let intersects = NSScreen.screens.contains { $0.frame.intersects(frame) }
                if !isMin && !intersects { continue }
                
                // Stabile ID mit bereits übergebenem cgInfo (keine Extra-Systemcalls)
                guard let winID = windowID(for: axElement, cgInfo: cgInfo) else { continue }
                // Stabile ID mit bereits übergebenem cgInfo (keine Extra-Systemcalls)

                // Screen bestimmen (sichtbar → prev → main)
                let screen: NSScreen = {
                    if let s = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) { return s }
                    if let old = prev.first(where: { $0.windowID == winID }) { return old.screen }
                    return NSScreen.main ?? NSScreen.screens.first!
                }()

                // Titel mit einfachem Fallback
                let rawTitle = title.isEmpty ? appName : title

                // Titel-Entprellung (enum-intern, unabhängig vom WindowScanner)
                let lastAX = Self.lastTitle[winID] ?? rawTitle
                if rawTitle == lastAX {
                    Self.titleStableCount[winID] = (Self.titleStableCount[winID] ?? 0) + 1
                } else {
                    Self.titleStableCount[winID] = 1
                    Self.lastTitle[winID] = rawTitle
                }

                let effectiveTitle: String = {
                    if (Self.titleStableCount[winID] ?? 0) >= Self.titleConfirmScans {
                        return rawTitle
                    } else if let prevTitle = prev.first(where: { $0.windowID == winID })?.title {
                        return prevTitle
                    } else {
                        return rawTitle
                    }
                }()
                
                // UI-stabile UUID wiederverwenden
                let stableUUID = prev.first(where: { $0.windowID == winID })?.id ?? UUID()

                let info = WindowInfo(
                    id: stableUUID,
                    windowID: winID,
                    appName: appName,
                    title: effectiveTitle,
                    displayID: displayID(for: screen),
                    screen: screen,
                    axElement: axElement,
                    minimized: isMin,
                    isMain: isMain
                )

                if !windowList.contains(where: { $0.windowID == winID }) {
                    windowList.append(info)
                }
            }
        }

        // Reihenfolge stabil halten (nur anhand der übergebenen `order`)
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

    private static func isMinimized(_ axElement: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXMinimizedAttribute as CFString, &ref)
        return (ref as? Bool) ?? false
    }

    private static func isMainWindow(_ axElement: AXUIElement) -> Bool {
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
