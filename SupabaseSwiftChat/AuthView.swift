import SwiftUI
import Supabase

struct AuthView: View {
    @State var email = ""
    @State var password = ""
    @State var isLoading = false
    @State var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
                    .textContentType(.password)
            }

            Section {
                Button("Sign in") {
                    signInButtonTapped()
                }
                .bold()
                .disabled(email.isEmpty || password.isEmpty)

                if isLoading {
                    ProgressView()
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    func signInButtonTapped() {
        Task {
            isLoading = true
            errorMessage = nil
            defer { isLoading = false }

            do {
                try await supabase.auth.signIn(
                    email: email,
                    password: password
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
