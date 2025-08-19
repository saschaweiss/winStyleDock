import SwiftUI
import AppKit
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let activeColor      = "settings.activeColor"
        static let inactiveColor    = "settings.inactiveColor"
        static let normalColor      = "settings.normalColor"
        static let backgroundColor  = "settings.backgroundColor"
        static let buttonMaxWidth   = "settings.buttonMaxWidth"
        static let buttonPadding    = "settings.buttonPadding"
        static let buttonSpacing    = "settings.buttonSpacing"
        static let pollInterval     = "settings.pollInterval"
        static let groupByApp       = "settings.groupByApp"
        static let showIcons        = "settings.showIcons"
    }

    private let ud = UserDefaults.standard

    // MARK: - Published Properties
    @Published var activeColor: Color
    @Published var inactiveColor: Color
    @Published var normalColor: Color
    @Published var backgroundColor: Color

    @Published var buttonMaxWidth: CGFloat
    @Published var buttonPadding: CGFloat
    @Published var buttonSpacing: CGFloat
    @Published var pollInterval: TimeInterval
    @Published var groupByApp: Bool
    @Published var showIcons: Bool

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init
    init() {
        activeColor     = Self.loadColor(forKey: Keys.activeColor)     ?? Color(NSColor.systemBlue)
        inactiveColor   = Self.loadColor(forKey: Keys.inactiveColor)   ?? Color(NSColor.systemGray)
        normalColor     = Self.loadColor(forKey: Keys.normalColor)     ?? Color(NSColor.controlAccentColor)
        backgroundColor = Self.loadColor(forKey: Keys.backgroundColor) ?? Color.black.opacity(0.75)

        buttonMaxWidth  = ud.object(forKey: Keys.buttonMaxWidth) as? CGFloat ?? 300
        buttonPadding   = ud.object(forKey: Keys.buttonPadding)   as? CGFloat ?? 6
        buttonSpacing   = ud.object(forKey: Keys.buttonSpacing)   as? CGFloat ?? 6
        pollInterval    = ud.object(forKey: Keys.pollInterval)    as? TimeInterval ?? 0.12
        groupByApp      = ud.object(forKey: Keys.groupByApp)      as? Bool ?? true
        showIcons       = ud.object(forKey: Keys.showIcons)       as? Bool ?? true

        setUpBindings()
    }

    private func setUpBindings() {
        $activeColor.sink { Self.saveColor($0, forKey: Keys.activeColor) }.store(in: &cancellables)
        $inactiveColor.sink { Self.saveColor($0, forKey: Keys.inactiveColor) }.store(in: &cancellables)
        $normalColor.sink { Self.saveColor($0, forKey: Keys.normalColor) }.store(in: &cancellables)
        $backgroundColor.sink { Self.saveColor($0, forKey: Keys.backgroundColor) }.store(in: &cancellables)

        $buttonMaxWidth.sink { [weak self] in self?.ud.set($0, forKey: Keys.buttonMaxWidth) }.store(in: &cancellables)
        $buttonPadding.sink { [weak self] in self?.ud.set($0, forKey: Keys.buttonPadding) }.store(in: &cancellables)
        $buttonSpacing.sink { [weak self] in self?.ud.set($0, forKey: Keys.buttonSpacing) }.store(in: &cancellables)
        $pollInterval.sink { [weak self] in self?.ud.set($0, forKey: Keys.pollInterval) }.store(in: &cancellables)
        $groupByApp.sink { [weak self] in self?.ud.set($0, forKey: Keys.groupByApp) }.store(in: &cancellables)
        $showIcons.sink { [weak self] in self?.ud.set($0, forKey: Keys.showIcons) }.store(in: &cancellables)
    }

    // MARK: - Color Storage Helpers
    private static func saveColor(_ color: Color, forKey key: String) {
        #if canImport(AppKit)
        let nsColor = NSColor(color)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: nsColor,
                                                       requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: key)
        }
        #endif
    }

    private static func loadColor(forKey key: String) -> Color? {
        #if canImport(AppKit)
        guard let data = UserDefaults.standard.data(forKey: key),
              let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
        else { return nil }
        return Color(nsColor: nsColor)
        #else
        return nil
        #endif
    }
}
