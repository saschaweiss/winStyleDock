// Core/Windowing/WindowBackend.swift
import ApplicationServices
import AppKit

/// Abstraktion für Fenster-Aktionen (AX, Swindler, …)
protocol WindowBackend: AnyObject {
    func minimize(axElement: AXUIElement) -> Bool
    func restore(axElement: AXUIElement) -> Bool
    func bringToFront(axElement: AXUIElement) -> Bool
    func close(axElement: AXUIElement) -> Bool
}

/// Globale Zugriffsstelle – die UI/Scanner sprechen nur noch mit dem Backend.
enum WindowSystem {
    static var backend: WindowBackend = AXWindowBackend.shared  // Fallback: klassisches AX
}
