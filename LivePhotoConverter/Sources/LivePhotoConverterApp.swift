import SwiftUI

@main
struct LivePhotoConverterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 560, height: 720)
    }
}
