import SwiftUI

/// 请求控制台: 按"新的在前"展示发往设备的每一次请求与关键播放事件,
/// 支持按类型筛选、文本搜索、暂停滚动、一键清空与复制全部, 供远程排查。
struct ConsoleView: View {
    @State private var console = RequestConsole.shared
    /// nil = 全部类型
    @State private var filter: ConsoleEntry.Kind?
    @State private var searchText = ""
    @State private var copied = false

    private var filtered: [ConsoleEntry] {
        console.entries.filter { entry in
            guard filter == nil || entry.kind == filter else { return false }
            if searchText.isEmpty { return true }
            return entry.title.localizedCaseInsensitiveContains(searchText)
                || (entry.detail?.localizedCaseInsensitiveContains(searchText) ?? false)
                || entry.result.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        console.entries.isEmpty ? "暂无请求记录" : "没有匹配的记录",
                        systemImage: "terminal",
                        description: Text(console.entries.isEmpty
                            ? "连接设备后的每一次请求都会出现在这里"
                            : "试试更换筛选类型或搜索词")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("控制台")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索命令/文件/结果")
            .toolbar { toolbarContent }
        }
    }

    private var list: some View {
        List {
            ForEach(filtered) { entry in
                row(entry)
            }
        }
        .listStyle(.plain)
    }

    private func row(_ entry: ConsoleEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.timeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(entry.kind.rawValue)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(color(for: entry.kind).opacity(0.15), in: Capsule())
                    .foregroundStyle(color(for: entry.kind))
                Spacer()
                Text(entry.durationText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(entry.title)
                .font(.footnote.weight(.semibold))
            if let detail = entry.detail {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Text(entry.result)
                .font(.caption)
                .foregroundStyle(entry.ok ? .green : .red)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            // 复制这条记录, 方便贴出来排查
            UIPasteboard.general.string = """
            [\(entry.timeText)] \(entry.kind.rawValue) \(entry.title)\(entry.detail.map { " | \($0)" } ?? "") | \(entry.durationText) | \(entry.ok ? "OK" : "失败") | \(entry.result)
            """
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // 暂停滚动: 排查时冻结当前视图, 新记录不再插到眼前
            Button {
                console.paused.toggle()
            } label: {
                Image(systemName: console.paused ? "playpause" : "pause.rectangle")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button("全部") { filter = nil }
                ForEach(ConsoleEntry.Kind.allCases, id: \.self) { kind in
                    Button {
                        filter = (filter == kind) ? nil : kind
                    } label: {
                        if filter == kind {
                            Label(kind.rawValue, systemImage: "checkmark")
                        } else {
                            Text(kind.rawValue)
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .symbolVariant(filter == nil ? .none : .fill)
            }
            Button {
                UIPasteboard.general.string = console.exportText
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            Button(role: .destructive) {
                console.clear()
            } label: {
                Image(systemName: "trash")
            }
        }
    }

    private func color(for kind: ConsoleEntry.Kind) -> Color {
        switch kind {
        case .command: return .blue
        case .heartbeat: return .green
        case .download: return .orange
        case .event: return .purple
        }
    }
}
