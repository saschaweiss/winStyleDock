import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            // MARK: Farben
            Section("Farben") {
                ColorPicker("Aktiv", selection: $settings.activeColor)
                ColorPicker("Nicht aktiv (minimiert)", selection: $settings.inactiveColor)
                ColorPicker("Hintergrund (Taskbar)", selection: $settings.backgroundColor)
                ColorPicker("Normal (Hintergrundfenster)", selection: $settings.normalColor)
            }

            // MARK: Layout
            Section("Taskleisten-Layout") {
                HStack {
                    Text("Max. Buttonbreite")
                    Spacer()
                    Text("\(Int(settings.buttonMaxWidth)) px").foregroundStyle(.secondary)
                }
                Slider(value: $settings.buttonMaxWidth, in: 120...420, step: 10)

                HStack {
                    Text("Button-Padding")
                    Spacer()
                    Text("\(Int(settings.buttonPadding)) pt").foregroundStyle(.secondary)
                }
                Slider(value: $settings.buttonPadding, in: 2...16, step: 1)

                HStack {
                    Text("Button-Abstand")
                    Spacer()
                    Text("\(Int(settings.buttonSpacing)) pt").foregroundStyle(.secondary)
                }
                Slider(value: $settings.buttonSpacing, in: 0...24, step: 1)
            }

            // MARK: Verhalten
            Section("Verhalten") {
                Toggle("Buttons nach App gruppieren", isOn: $settings.groupByApp)
                Toggle("App-Icons anzeigen", isOn: $settings.showIcons)

                HStack {
                    Text("Scan-Intervall")
                    Spacer()
                    Text(String(format: "%.0f ms", settings.pollInterval * 1000)).foregroundStyle(.secondary)
                }
                Slider(value: $settings.pollInterval, in: 0.05...0.50, step: 0.01)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 420)
    }
}

#Preview {
    SettingsView()
}
