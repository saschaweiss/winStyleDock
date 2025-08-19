// App/ContentView.swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("WinStyleDock läuft")
                .font(.title2).bold()
            Text("Die Taskleisten werden pro Bildschirm als eigene, rahmenlose Fenster angezeigt.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 10) {
                // ✅ Offizieller Weg, öffnet die Settings-Scene
                SettingsLink {
                    Label("Einstellungen öffnen", systemImage: "gearshape")
                }

                Button("Neu scannen") {
                    NotificationCenter.default.post(name: .init("WinStyleDock.TriggerScan"), object: nil)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 220)
    }
}

#Preview { ContentView() }
