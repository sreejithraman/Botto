import AppKit
import SwiftUI

/// The local engine's recent output, for when something goes wrong.
struct MacServerLogView: View {
    let server: LocalT3ServerManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(server.logTail.isEmpty ? "No output yet." : "Recent engine output")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(server.logTail.joined(separator: "\n"), forType: .string)
                }
                .disabled(server.logTail.isEmpty)
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(server.logTail.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .onChange(of: server.logTail.count) { _, count in if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) } }
            }
        }
        .background(MacTheme.paper)
    }
}
