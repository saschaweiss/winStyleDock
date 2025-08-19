import SwiftUI

/// Ein Platzhalter, falls die App (noch) keine eigenen Menü-Kommandos hat.
/// Verhindert den Compilerfehler in MainApp.
struct EmptyCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) { }
    }
}
