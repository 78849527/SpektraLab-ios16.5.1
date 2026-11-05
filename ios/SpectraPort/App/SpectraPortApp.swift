import SwiftUI

@main
struct SpectraPortApp: App {
    @AppStorage("spectraport.startup.destination") private var destination = "editor"

    // Never open the former diagnostic screen on launch. The user may
    // choose camera/editor from Settings without re-creating the app shell.
    var body: some Scene {
        WindowGroup {
            EditorView(
                onBack: {},
                launchCameraOnFirstAppear: destination == "camera"
            )
        }
    }
}
