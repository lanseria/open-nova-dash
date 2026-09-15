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
    @State private var connection = ConnectionModel()

    var body: some View {
        Group {
            if connection.isConnected {
                MainTabView()
            } else {
                // 待连接 / 连接中 / 已断开: 一律停留在连接页面
                ConnectView()
            }
        }
        .environment(connection)
        .animation(.easeInOut(duration: 0.25), value: connection.state)
    }
}

/// 三个功能页仅在连接成功后出现
struct MainTabView: View {
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

/// 待连接页面: 手动点击后才发起连接
struct ConnectView: View {
    @Environment(ConnectionModel.self) private var connection

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "video.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("NovaDash")
                .font(.largeTitle.bold())
            Text("请先将 iPhone 连接至行车记录仪 Wi-Fi\n(设备地址 192.168.1.254)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if connection.state == .connecting {
                ProgressView("正在连接…")
                    .padding(.top, 8)
            } else {
                Button {
                    Task { await connection.connect() }
                } label: {
                    Label("连接记录仪", systemImage: "wifi")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
            }

            if let error = connection.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
