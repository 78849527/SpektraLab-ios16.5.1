import SwiftUI

@main
struct SpectraPortApp: App {
    // This view intentionally does not create any Metal device, CIContext,
    // photo picker, or native engine during process launch.
    var body: some Scene {
        WindowGroup {
            DiagnosticHomeView()
        }
    }
}
