import SwiftUI

struct ConnectionView: View {
    let store: AppStore
    @State var input = ""
    @State private var inputRevision = 0

    var body: some View {
        NavigationStack {
            T3PairingView(store: store, input: input).id(inputRevision)
        }
        .onChange(of: store.pendingConnectionInput) { _, pending in
            guard let pending else { return }
            input = pending
            inputRevision += 1
            store.pendingConnectionInput = nil
        }
        .onAppear { store.pendingConnectionInput = nil }
        .tint(BottoTheme.action)
    }
}
