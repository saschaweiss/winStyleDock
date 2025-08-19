import SwiftUI

/// Zentrale Defaults + State für Farben/Abstände/Zeiten.
/// Alles ist hier gebündelt und kann über SettingsView live verändert werden.
@MainActor
final class AppTheme: ObservableObject {
    static let shared = AppTheme()

    // Farben der Taskleiste
    @Published var colors = Colors()
    // Abstände & Maße
    @Published var taskbar = TaskbarMetrics()

    struct Colors {
        var barBackground: Color = .black.opacity(0.78)

        var itemBackgroundActive: Color = .blue.opacity(0.75)
        var itemBackgroundNormal: Color = .gray.opacity(0.55)
        var itemBackgroundMin: Color = .gray.opacity(0.35)

        var borderActive: Color = .blue
        var borderNormal: Color = .gray
        var borderMin: Color = .gray.opacity(0.35)
    }

    struct TaskbarMetrics {
        var verticalPadding: CGFloat = 6
        var horizontalPadding: CGFloat = 8
        var itemSpacing: CGFloat = 6
        var groupGap: CGFloat = 10
        var maxButtonWidth: CGFloat = 300
        var barHeight: CGFloat = 60

        /// Scan-Intervall, kleiner = weniger Latenz, größer = weniger CPU
        var scanInterval: TimeInterval = 0.12
        /// Pending-State-Timeout (UI-Entprellung nach Toggle)
        var pendingGrace: TimeInterval = 0.35
    }
}
