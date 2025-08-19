import Foundation
import Cocoa
import ApplicationServices

/// Stabile, app-unabhängige Fenster-ID (PID + WindowNumber)
public struct WindowID: Hashable {
    public let pid: pid_t
    public let windowNumber: Int
    public init(pid: pid_t, windowNumber: Int) {
        self.pid = pid
        self.windowNumber = windowNumber
    }
}

/// Datenmodell für ein Fenster in der Taskleiste.
/// `id` ist eine UI-stabile UUID (wird bei Rescan wiederverwendet),
/// `windowID` identifiziert das OS-Fenster stabil (PID + CGWindowNumber oder Fallback).
public struct WindowInfo: Identifiable, Equatable {
    public let id: UUID
    public let windowID: WindowID
    public let appName: String
    public let title: String
    public let screen: NSScreen
    public let axElement: AXUIElement
    public var minimized: Bool
    public var isMain: Bool

    public init(id: UUID = UUID(),
                windowID: WindowID,
                appName: String,
                title: String,
                screen: NSScreen,
                axElement: AXUIElement,
                minimized: Bool,
                isMain: Bool)
    {
        self.id = id
        self.windowID = windowID
        self.appName = appName
        self.title = title
        self.screen = screen
        self.axElement = axElement
        self.minimized = minimized
        self.isMain = isMain
    }

    public static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.windowID == rhs.windowID
    }
}
