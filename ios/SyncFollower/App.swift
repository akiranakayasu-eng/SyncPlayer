import SwiftUI

@main
struct SyncFollowerApp: App {
    @StateObject private var model = FollowerModel()
    var body: some Scene {
        WindowGroup { ContentView(model: model).preferredColorScheme(.dark) }
    }
}
