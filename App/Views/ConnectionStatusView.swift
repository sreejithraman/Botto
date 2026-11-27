import SwiftUI

struct ConnectionStatusView: View {
    let store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(store.link == .connecting ? "Connecting to your Mac…" : "You’re offline",
                  systemImage: store.link == .connecting ? "network" : "wifi.slash")
                .font(.subheadline.weight(.semibold))
            Text("Try your action again once connected. Nothing will be sent automatically.")
                .font(.footnote).foregroundStyle(.secondary)
            if store.link != .connecting {
                if let error = store.connectionError {
                    // The whole message, so every route that was tried stays readable.
                    Text(error).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button("Reconnect") {
                    if let configuration = store.configuration { Task { await store.connect(configuration) } }
                }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("connection-feedback")
    }
}
