// Infrastructure/Windowing/DockWindowManager.swift
import AppKit
import SwiftUI

@MainActor
final class DockWindowManager {
    static let shared = DockWindowManager()

    /// Panels werden über den stabilen DisplayID-Key gemanagt
    private var panelsByDisplayID: [CGDirectDisplayID: NSPanel] = [:]
    private var screenChangeObserver: NSObjectProtocol?

    // MARK: - Public API
    func show() {
        // Scanner starten
        WindowScanner.shared.start()
        
        // ⬇️ EdgeGuard aktivieren
        EdgeGuard.shared.start(using: WindowScanner.shared, barHeight: AppTheme.shared.taskbar.barHeight)

        // ⬇️ WICHTIG: MainActor hoppen (nicht synchron aufrufen)
        Task { @MainActor [weak self] in
            self?.rebuildPanels()
        }

        // Bildschirm-Änderungen beobachten – Closure ist NICHT MainActor-isoliert,
        // daher ebenfalls immer über Task { @MainActor in ... } hoppen.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildPanels()
            }
        }
    }

    func hide() {
        // ⬇️ EdgeGuard stoppen
        EdgeGuard.shared.stop()
        
        for panel in panelsByDisplayID.values {
            panel.orderOut(nil)
        }
        panelsByDisplayID.removeAll()

        if let obs = screenChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            screenChangeObserver = nil
        }
    }

    // MARK: - Panels
    func rebuildPanels() {
        let theme = AppTheme.shared
        let barHeight = theme.taskbar.barHeight

        // Aktuelle Displays erfassen (stabile IDs)
        let currentScreens = NSScreen.screens
        let currentIDs: Set<CGDirectDisplayID> = Set(currentScreens.compactMap { $0.displayID })

        // 1) Nicht mehr vorhandene Panels schließen
        let existingIDs = Set(panelsByDisplayID.keys)
        let toRemove = existingIDs.subtracting(currentIDs)
        for id in toRemove {
            panelsByDisplayID[id]?.orderOut(nil)
            panelsByDisplayID[id] = nil
        }

        // 2) Vorhandene Panels aktualisieren (Frame) & fehlende Panels erzeugen
        for screen in currentScreens {
            guard let displayID = screen.displayID else { continue }

            let frame = NSRect(
                x: screen.frame.minX,
                y: screen.frame.minY,
                width: screen.frame.width,
                height: barHeight
            )

            if let panel = panelsByDisplayID[displayID] {
                // Frame updaten (z.B. bei Auflösungswechsel)
                panel.setFrame(frame, display: true)
                // Sicherheitsnetz: falls HostingView nicht korrekt autoresize’d
                if let hosting = panel.contentView as? NSHostingView<AnyView> {
                    hosting.frame = panel.contentView?.bounds ?? .zero
                }
                panel.orderFrontRegardless()
            } else {
                // Neu erzeugen
                let panel = makePanel(for: screen, frame: frame)
                panelsByDisplayID[displayID] = panel
                panel.orderFrontRegardless()
            }
        }
    }

    // MARK: - Panel Factory
    private func makePanel(for screen: NSScreen, frame: NSRect) -> NSPanel {
        let theme = AppTheme.shared

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        // Sichtbarkeit/Verhalten
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary // falls du die Leiste auch in Fullscreen-Spaces sehen willst
        ]
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        // Inhalt: deine Taskbar-View, an diesen Screen gebunden
        let root = WindowsDockView(scanner: WindowScanner.shared, screen: screen)
            .frame(height: theme.taskbar.barHeight)

        // HostingView robust mit autoresizing
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = panel.contentView?.bounds ?? frame
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        return panel
    }
}

// MARK: - NSScreen ➜ DisplayID helper
private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        // „NSScreenNumber“ liefert eine stabile CGDirectDisplayID
        guard let num = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(num.uint32Value)
    }
}
