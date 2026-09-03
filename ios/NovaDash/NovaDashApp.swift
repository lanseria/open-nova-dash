import SwiftUI

@main
struct NovaDashApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("状态", systemImage: "gauge") }
            AlbumView()
                .tabItem { Label("相册", systemImage: "photo.on.rectangle.angled") }
            ControlView()
                .tabItem { Label("控制", systemImage: "camera.fill") }
        }
    }
}
