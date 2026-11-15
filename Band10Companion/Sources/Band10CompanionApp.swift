import SwiftUI

@main
struct Band10CompanionApp: App {
    @StateObject private var bluetooth = BandBluetoothManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetooth)
        }
    }
}
