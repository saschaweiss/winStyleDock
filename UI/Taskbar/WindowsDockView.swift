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

    var body: some View {
        let windowsForScreen = scanner.windows.filter { sameDisplay($0.screen, screen) }
        let grouped = groupedByAppPreservingOrder(windowsForScreen)

        ScrollView(.horizontal, showsIndicators: false) {
            if grouped.isEmpty {
                // Dezent: leerer Zustand zum Debuggen
                HStack {
                    Text("Keine Fenster gefunden")
                        .foregroundColor(.white.opacity(0.6))
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, theme.taskbar.horizontalPadding)
                .frame(height: theme.taskbar.barHeight)
            } else {
                HStack(spacing: theme.taskbar.itemSpacing) {
                    ForEach(grouped.indices, id: \.self) { groupIndex in
                        let group = grouped[groupIndex]
                        HStack(spacing: theme.taskbar.groupGap) {
                            ForEach(group.windows, id: \.id) { win in
                                windowButton(win)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, theme.taskbar.horizontalPadding)
                .padding(.vertical, theme.taskbar.verticalPadding)
                .frame(height: theme.taskbar.barHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: theme.taskbar.barHeight)
        .background(theme.colors.barBackground)
        .ignoresSafeArea(edges: .bottom)
        // ---- Debug-Ausgabe hierhin verlegt (kein View-Builder-Konflikt) ----
        .onAppear {
            print("Screen \(displayID(for: screen) ?? 0): \(windowsForScreen.count) Fenster")
        }
        .onReceive(scanner.$windows) { _ in
            let count = scanner.windows.filter { sameDisplay($0.screen, screen) }.count
            print("Screen \(displayID(for: screen) ?? 0): \(count) Fenster")
        }
        // --------------------------------------------------------------------
    }

    // MARK: - Einzelner Button
    @ViewBuilder
    private func windowButton(_ window: WindowInfo) -> some View {
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
                        .truncationMode(.tail)
                }
                .opacity(minimized ? 0.6 : 1.0)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: theme.taskbar.maxButtonWidth)
            .background(backgroundColor(isActive: isActive, minimized: minimized))
            .foregroundColor(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor(isActive: isActive, minimized: minimized), lineWidth: 1)
            )
            .cornerRadius(6)
            .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
            .contentShape(Rectangle())
            .onHover { hovering in
                hoveredID = hovering ? window.id : nil
            }
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button(minimized ? "Wiederherstellen" : "Minimieren") {
                scanner.toggleWindow(window)
            }
            Button("In den Vordergrund") {
                bringToFront(window.axElement)
            }
            Divider()
            Button("Schließen") {
                closeWindow(window)
            }
        }
        .help("\(window.appName) — \(window.title)")
    }

    // MARK: - Gruppierung nach App (stabile Reihenfolge)
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
        // Close-Button holen
        let copyErr = AXUIElementCopyAttributeValue(
            window.axElement,
            kAXCloseButtonAttribute as CFString,
            &closeBtnRef
        )

        if copyErr == AXError.success, let btnRef = closeBtnRef {
            // Button „drücken“
            let btn = unsafeBitCast(btnRef, to: AXUIElement.self)
            let pressErr = AXUIElementPerformAction(btn, kAXPressAction as CFString)
            if pressErr != AXError.success {
                // Fallback: App freundlich beenden
                var pid: pid_t = 0
                AXUIElementGetPid(window.axElement, &pid)
                NSRunningApplication(processIdentifier: pid)?.terminate()
            }
        } else {
            // Fallback: App freundlich beenden
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

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    private func sameDisplay(_ a: NSScreen, _ b: NSScreen) -> Bool {
        guard let da = displayID(for: a), let db = displayID(for: b) else { return false }
        return da == db
    }
}
