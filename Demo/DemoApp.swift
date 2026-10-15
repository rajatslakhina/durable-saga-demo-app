import SwiftUI
import DurableSaga

/// Entry point. The app owns the saga definition and retry configuration
/// (`DemoConfiguration`) and hands them to the library's `SagaCoordinator`
/// through `CheckoutLab`; the library itself ships no UI.
@main
struct DemoApp: App {
    @StateObject private var lab = CheckoutLab()

    var body: some Scene {
        WindowGroup {
            ContentView(lab: lab)
        }
    }
}
