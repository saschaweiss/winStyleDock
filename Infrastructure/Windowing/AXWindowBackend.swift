// Core/Windowing/AXWindowBackend.swift
import Foundation
import AppKit
import ApplicationServices

final class AXWindowBackend: WindowBackend {
    static let shared = AXWindowBackend()
    private init() {}

    func minimize(axElement: AXUIElement) -> Bool {
        if AXUIElementSetAttributeValue(axElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }
        // Minimize-Button Fallback
        var btnRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXMinimizeButtonAttribute as CFString, &btnRef) == .success,
           let raw = btnRef {
            let btn = unsafeBitCast(raw, to: AXUIElement.self)
            return AXUIElementPerformAction(btn, kAXPressAction as CFString) == .success
        }
        return false
    }

    func restore(axElement: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(axElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
    }

    func bringToFront(axElement: AXUIElement) -> Bool {
        var pid: pid_t = 0
        AXUIElementGetPid(axElement, &pid)
        _ = AXUIElementSetAttributeValue(axElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        _ = AXUIElementSetAttributeValue(axElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        return NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows]) ?? false
    }

    func close(axElement: AXUIElement) -> Bool {
        var closeBtnRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXCloseButtonAttribute as CFString, &closeBtnRef) == .success,
           let raw = closeBtnRef {
            let btn = unsafeBitCast(raw, to: AXUIElement.self)
            return AXUIElementPerformAction(btn, kAXPressAction as CFString) == .success
        }
        return false
    }
}
