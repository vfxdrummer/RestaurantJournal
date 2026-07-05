import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            JournalListView()
                .tabItem { Label("Journal", systemImage: "book.fill") }

            AskJournalView()
                .tabItem { Label("Ask", systemImage: "sparkles") }
        }
    }
}
