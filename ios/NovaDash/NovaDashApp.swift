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
    /// 驱动 logo 呼吸与涟漪动画的单次开关 (onAppear 置 true 后一直循环)
    @State private var breathing = false

    private var isConnecting: Bool { connection.state == .connecting }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                Spacer()
                logoSection
                instructionCard
                    .padding(.top, 36)
                connectControl
                    .padding(.top, 30)
                if let error = connection.errorText {
                    errorCard(error)
                        .padding(.top, 16)
                }
                Spacer()
                Text("NovaDash · 行车记录仪伴侣")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(.bottom, 6)
            }
            .padding(.horizontal, 28)
        }
        .onAppear { breathing = true }
        .animation(.easeInOut(duration: 0.3), value: connection.state)
        .animation(.easeInOut(duration: 0.3), value: connection.errorText)
    }

    // MARK: - 背景: 深色渐变 + logo 后方光晕

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.11, blue: 0.22),
                    Color(red: 0.03, green: 0.04, blue: 0.09),
                    Color(red: 0.01, green: 0.02, blue: 0.04),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(red: 0.20, green: 0.50, blue: 1.00).opacity(isConnecting ? 0.30 : 0.16), .clear],
                center: .center, startRadius: 5, endRadius: 300
            )
            .frame(height: 540)
            .offset(y: -140)
            .animation(.easeInOut(duration: 0.6), value: isConnecting)
        }
        .ignoresSafeArea()
    }

    // MARK: - Logo + 标题

    private var logoSection: some View {
        VStack(spacing: 18) {
            ZStack {
                if isConnecting {
                    rippleRing(delay: 0)
                    rippleRing(delay: 0.7)
                    rippleRing(delay: 1.4)
                }
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 118, height: 118)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: Color(red: 0.20, green: 0.50, blue: 1.00).opacity(0.45), radius: 24, y: 12)
                    .scaleEffect(breathing ? 1.03 : 0.97)
                    .animation(
                        .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                        value: breathing
                    )
            }
            VStack(spacing: 8) {
                Text("NovaDash")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, Color(red: 0.65, green: 0.82, blue: 1.00)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                Text(isConnecting ? "正在寻找你的记录仪…" : "行车记录仪智慧伴侣")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    /// 连接中向外扩散的涟漪圈
    private func rippleRing(delay: Double) -> some View {
        Circle()
            .strokeBorder(Color(red: 0.30, green: 0.60, blue: 1.00).opacity(0.6), lineWidth: 2)
            .frame(width: 118, height: 118)
            .scaleEffect(breathing ? 1.6 : 1.0)
            .opacity(breathing ? 0 : 0.7)
            .animation(
                .easeOut(duration: 2.1).repeatForever(autoreverses: false).delay(delay),
                value: breathing
            )
    }

    // MARK: - 连接步骤说明卡片

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepRow(icon: "wifi", tint: Color(red: 0.30, green: 0.60, blue: 1.00),
                    title: "连接记录仪 Wi-Fi", detail: "设置 → WLAN, 选择行车记录仪热点")
            Divider().overlay(.white.opacity(0.08))
            stepRow(icon: "number", tint: Color(red: 0.25, green: 0.80, blue: 0.95),
                    title: "设备地址 192.168.1.254", detail: "连接后自动探测, 无需手动输入")
            Divider().overlay(.white.opacity(0.08))
            stepRow(icon: "hand.raised.fill", tint: .orange,
                    title: "允许本地网络权限", detail: "首次连接时在系统弹窗中选择允许")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func stepRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // MARK: - 连接按钮 / 进行中指示

    @ViewBuilder
    private var connectControl: some View {
        if isConnecting {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("正在探测设备, 最多尝试 3 次…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.vertical, 10)
        } else {
            Button {
                Task { await connection.connect() }
            } label: {
                Label(connection.errorText == nil ? "连接记录仪" : "重新连接",
                      systemImage: "bolt.horizontal.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.15, green: 0.45, blue: 1.00),
                                     Color(red: 0.10, green: 0.75, blue: 0.95)],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: Capsule()
                    )
                    .shadow(color: Color(red: 0.20, green: 0.50, blue: 1.00).opacity(0.4), radius: 14, y: 6)
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    // MARK: - 错误提示卡片

    private func errorCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.red.opacity(0.30), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// 按下时轻微缩放的按钮反馈
private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
