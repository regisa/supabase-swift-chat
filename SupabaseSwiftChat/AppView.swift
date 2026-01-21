import SwiftUI

struct AppView: View {
    @State var isAuthenticated = false

    var body: some View {
        Group {
            if isAuthenticated {
                MessagesListView()
            } else {
                AuthView()
            }
        }
        .task {
            for await state in supabase.auth.authStateChanges {
                if [.initialSession, .signedIn, .signedOut].contains(state.event) {
                    isAuthenticated = state.session != nil
                }
            }
        }
    }
}
