import SwiftUI

@main
struct PlayCoverVRChatPatcherApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(model: PatcherViewModel())
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
