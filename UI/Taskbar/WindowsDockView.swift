// UI/Taskbar/WindowsDockView.swift
import SwiftUI
import AppKit
import ApplicationServices

/// Taskleisten-View für genau EINEN Bildschirm.
struct WindowsDockView: View {
    @ObservedObject var scanner: WindowScanner
    let screen: NSScreen

    @ObservedObject private var theme = AppTheme.shared
    @State private var hoveredID: UUID?

    // Caches, um Arbeit im body zu reduzieren
    @State private var displayID: CGDirectDisplayID?
    @State private var cachedWindowsForScreen: [WindowInfo] = []

    // Eigene stabile Reihenfolge NUR für diese Leiste
    @State private var localOrder: [WindowID] = []

    // Vorgruppierte Items (Reihenfolge bleibt stabil!)
    @State private var items: [(app: String, windows: [WindowInfo])] = []

    // Scan-Throttle
    @State private var lastUpdate = Date.distantPast
    private let minUpdateInterval: TimeInterval = 0.12  // drosselt Updates (visuell trotzdem flüssig)

    // ✨ Anti-Flackern: Präsenz-Stabilisierung
    @State private var firstSeenAt: [WindowID: Date] = [:]   // wann neu gesehen
    @State private var lastSeenAt:  [WindowID: Date] = [:]   // wann zuletzt gesehen
    private let appearGrace: TimeInterval = 0.15             // erst zeigen, wenn so lange stabil gesehen
    private let vanishGrace: TimeInterval = 0.45             // erst entfernen, wenn so lange nicht gesehen

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if items.isEmpty {
                        HStack {
                            Text("Keine Fenster gefunden")
                                .foregroundColor(.white.opacity(0.6))
                                .font(.system(size: 12))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, theme.taskbar.horizontalPadding)
                        .frame(height: theme.taskbar.barHeight)
                    } else {
                        // Layout-Berechnung ausgelagert
                        let totalCount = items.reduce(0) { $0 + $1.windows.count }
                        let metrics = layout(for: geo.size,
                                             totalCount: totalCount,
                                             groupCount: items.count)

                        HStack(spacing: theme.taskbar.itemSpacing) {
                            ForEach(items.indices, id: \.self) { idx in
                                let group = items[idx]
                                HStack(spacing: theme.taskbar.groupGap) {
                                    ForEach(group.windows, id: \.id) { win in
                                        windowButton(win, width: metrics.perButtonWidth, height: metrics.innerHeight)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, theme.taskbar.horizontalPadding)
                        .padding(.vertical, theme.taskbar.verticalPadding)
                        .frame(height: metrics.innerHeight)
                        .clipped()
                    }
                }
            }
            // Wichtig: ScrollView selbst auf volle Breite/Höhe ziehen
            .frame(maxWidth: .infinity)
            .frame(height: theme.taskbar.barHeight)
            .background(theme.colors.barBackground)
            .ignoresSafeArea(edges: .bottom)
            .transaction { tx in tx.animation = nil }
            .onAppear {
                self.displayID = displayID(for: screen)
                rebuildItemsIfNeeded(from: scanner.windows)
            }
            .onReceive(scanner.$windows) { _ in
                rebuildItemsIfNeeded(from: scanner.windows)
            }
        }
    }

    // MARK: - Einzelner Button
    @ViewBuilder
    private func windowButton(_ window: WindowInfo, width: CGFloat, height: CGFloat) -> some View {
        let isActive = window.isMain && isAppActive(for: window.axElement)
        let minimized = window.minimized

        Button {
            scanner.toggleWindow(window)
        } label: {
            HStack(spacing: 8) {
                if let icon = iconFor(appNamed: window.appName) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                        .cornerRadius(3)
                        .opacity(minimized ? 0.6 : 1.0)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .frame(width: 18, height: 18)
                        .opacity(minimized ? 0.4 : 0.8)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(window.appName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(window.title)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .opacity(minimized ? 0.6 : 1.0)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: width, height: height, alignment: .leading)
            .contentShape(Rectangle())
            .clipped()
            .background(backgroundColor(isActive: isActive, minimized: minimized))
            .foregroundColor(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor(isActive: isActive, minimized: minimized), lineWidth: 1)
            )
            .cornerRadius(6)
            .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
            .onHover { hovering in
                hoveredID = hovering ? window.id : nil
            }
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button(minimized ? "Wiederherstellen" : "Minimieren") {
                if minimized {
                    _ = WindowSystem.backend.restore(axElement: window.axElement)
                } else {
                    _ = WindowSystem.backend.minimize(axElement: window.axElement)
                }
            }
            Button("In den Vordergrund") {
                _ = WindowSystem.backend.bringToFront(axElement: window.axElement)
            }
            Divider()
            Button("Schließen") {
                _ = WindowSystem.backend.close(axElement: window.axElement)
            }
        }
        .help("\(window.appName) — \(window.title)")
    }

    // MARK: - Rebuild / Throttle / Delta-Check (mit Stabilisierung)
    private func rebuildItemsIfNeeded(from allWindows: [WindowInfo]) {
        // 1) Throttle
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= minUpdateInterval else { return }

        // 2) Ziel-Display-ID da?
        if displayID == nil { displayID = displayID(for: screen) }
        guard let did = displayID else { return }

        // 3) Nur Fenster dieses Displays
        let current = allWindows.filter { $0.displayID == did }

        // 4) Präsenz-Zeiten aktualisieren
        let currentIDs = Set(current.map { $0.windowID })
        for w in current {
            if firstSeenAt[w.windowID] == nil { firstSeenAt[w.windowID] = now }
            lastSeenAt[w.windowID] = now
        }

        // 5) Mergen mit Gnadenfristen
        //    - Neue Fenster nur aufnehmen, wenn lang genug gesehen (appearGrace)
        //    - Verschwundene noch so lange halten (vanishGrace)
        let cachedByID = Dictionary(uniqueKeysWithValues: cachedWindowsForScreen.map { ($0.windowID, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.windowID, $0) })

        // im Rebuild
        var merged: [WindowInfo] = []

        // 5a) Erst die alten (CACHED) durchgehen: wenn weg, evtl. halten
        // bekannte Fenster durchgehen
        for old in cachedWindowsForScreen {
            if let fresh = current.first(where: { $0.windowID == old.windowID }) {
                // Fenster noch da → aktuelle Version nehmen
                merged.append(fresh)
            } else if old.minimized {
                // Fenster ist minimiert → trotzdem behalten
                merged.append(old)
            } else {
                // nur rauswerfen, wenn wirklich weg
                if let last = lastSeenAt[old.windowID], now.timeIntervalSince(last) <= vanishGrace {
                    merged.append(old)
                }
            }
        }

        // 5b) Neue, die noch nicht in merged sind
        // neue Fenster hinzufügen
        for w in current where !merged.contains(where: { $0.windowID == w.windowID }) {
            let seenFor = now.timeIntervalSince(firstSeenAt[w.windowID] ?? now)
            if seenFor >= appearGrace {
                merged.append(w)
            }
        }

        // 6) Lokale, stabile Reihenfolge anwenden
        let ordered = applyLocalOrder(to: merged)

        // 7) Wenn tatsächlich relevant anders → gruppieren & publish
        if !sameWindows(lhs: ordered, rhs: cachedWindowsForScreen) {
            cachedWindowsForScreen = ordered
            items = groupedByAppPreservingOrder(ordered)
            lastUpdate = now
        } else {
            // nichts geändert → nur Zeitstempel updaten
            lastUpdate = now
        }
    }
    
    /// Nutzt/aktualisiert `localOrder`, um Fenster stabil anzuordnen.
    private func applyLocalOrder(to windows: [WindowInfo]) -> [WindowInfo] {
        var result: [WindowInfo] = []

        // a) Zuerst in bestehender Reihenfolge einsammeln
        for id in localOrder {
            if let w = windows.first(where: { $0.windowID == id }) {
                result.append(w)
            }
        }
        // b) Neue IDs hinten anhängen und in localOrder aufnehmen
        for w in windows where !localOrder.contains(w.windowID) {
            result.append(w)
            localOrder.append(w.windowID)
        }
        // c) IDs entfernen, die es nicht mehr gibt
        localOrder.removeAll { id in
            !windows.contains(where: { $0.windowID == id })
        }
        return result
    }

    /// Vergleich „hat sich was Relevantes geändert?“ – schnell & günstig.
    private func sameWindows(lhs: [WindowInfo], rhs: [WindowInfo]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for i in lhs.indices {
            let a = lhs[i], b = rhs[i]
            if a.windowID != b.windowID { return false }
            if a.minimized != b.minimized { return false }
            if a.isMain != b.isMain { return false }
        }
        return true
    }

    // MARK: - Gruppierung nach App (ohne Reihenfolge zu verändern)
    private func groupedByAppPreservingOrder(_ windows: [WindowInfo]) -> [(app: String, windows: [WindowInfo])] {
        var order: [String] = []
        var buckets: [String: [WindowInfo]] = [:]
        for w in windows {
            if buckets[w.appName] == nil {
                order.append(w.appName)
                buckets[w.appName] = []
            }
            buckets[w.appName]?.append(w)
        }
        return order.map { app in (app, buckets[app] ?? []) }
    }

    // MARK: - Farben
    private func backgroundColor(isActive: Bool, minimized: Bool) -> Color {
        if minimized { return theme.colors.itemBackgroundMin }
        return isActive ? theme.colors.itemBackgroundActive : theme.colors.itemBackgroundNormal
    }

    private func borderColor(isActive: Bool, minimized: Bool) -> Color {
        if minimized { return theme.colors.borderMin }
        return isActive ? theme.colors.borderActive : theme.colors.borderNormal
    }

    // MARK: - AX Helpers
    private func isAppActive(for el: AXUIElement) -> Bool {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        return NSRunningApplication(processIdentifier: pid)?.isActive ?? false
    }

    private func bringToFront(_ el: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        _ = AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        _ = AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        app?.activate(options: [.activateAllWindows])
    }

    private func closeWindow(_ window: WindowInfo) {
        var closeBtnRef: CFTypeRef?
        let copyErr = AXUIElementCopyAttributeValue(
            window.axElement,
            kAXCloseButtonAttribute as CFString,
            &closeBtnRef
        )

        if copyErr == AXError.success, let btnRef = closeBtnRef {
            let btn = unsafeBitCast(btnRef, to: AXUIElement.self)
            let pressErr = AXUIElementPerformAction(btn, kAXPressAction as CFString)
            if pressErr != AXError.success {
                var pid: pid_t = 0
                AXUIElementGetPid(window.axElement, &pid)
                NSRunningApplication(processIdentifier: pid)?.terminate()
            }
        } else {
            var pid: pid_t = 0
            AXUIElementGetPid(window.axElement, &pid)
            NSRunningApplication(processIdentifier: pid)?.terminate()
        }
    }

    private func iconFor(appNamed name: String) -> NSImage? {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            let icon = app.icon
            icon?.size = NSSize(width: 18, height: 18)
            return icon
        }
        return nil
    }

    // MARK: - Layout-Helfer (aus dem ViewBuilder ausgelagert)
    private func layout(for size: CGSize, totalCount: Int, groupCount: Int) -> (innerHeight: CGFloat, perButtonWidth: CGFloat)
    {
        let innerHeight = max(1, theme.taskbar.barHeight - (theme.taskbar.verticalPadding * 2))
        let contentWidth = max(1, size.width - (theme.taskbar.horizontalPadding * 2))

        let totalItemGaps = CGFloat(max(0, totalCount - groupCount)) * theme.taskbar.itemSpacing
        let totalGroupGaps = CGFloat(max(0, groupCount - 1)) * theme.taskbar.groupGap
        let widthBudget = max(1, contentWidth - totalItemGaps - totalGroupGaps)

        let rawPerButton = widthBudget / CGFloat(max(1, totalCount))
        let perButtonWidth = max(theme.taskbar.minButtonWidth,
                                 min(theme.taskbar.maxButtonWidth, floor(rawPerButton)))
        return (innerHeight, perButtonWidth)
    }

    // MARK: - Screen ID Helpers
    func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard
            let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDirectDisplayID(num.uint32Value)
    }

    private func sameDisplay(_ a: NSScreen, _ b: NSScreen) -> Bool {
        guard let da = displayID(for: a), let db = displayID(for: b) else { return false }
        return da == db
    }
}
