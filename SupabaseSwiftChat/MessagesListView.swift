import SwiftUI

struct MessagesListView: View {
    @State var thingIds: [UUID] = []
    @State var isLoading = false
    @State var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 50))
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await loadThingIds() }
                        }
                    }
                    .padding()
                } else if thingIds.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "tray")
                            .font(.system(size: 50))
                            .foregroundStyle(.gray)
                        Text("No messages yet")
                            .foregroundStyle(.gray)
                    }
                } else {
                    List(thingIds, id: \.self) { thingId in
                        NavigationLink(destination: ChatRoomView(thingId: thingId.uuidString)) {
                            HStack {
                                Image(systemName: "message.fill")
                                    .foregroundStyle(.blue)
                                Text(thingId.uuidString)
                                    .font(.body)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Messages")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out", role: .destructive) {
                        Task {
                            try? await supabase.auth.signOut()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadThingIds() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .task {
            await loadThingIds()
        }
    }

    func loadThingIds() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response: [Message] = try await supabase
                .from("messages")
                .select("thing_id")
                .execute()
                .value

            // Extract unique thing_ids
            let ids = response.compactMap { $0.thingId }
            self.thingIds = Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }

        } catch {
            errorMessage = error.localizedDescription
            debugPrint("Error loading thing_ids:", error)
        }
    }
}

struct Message: Decodable {
    let thingId: UUID?

    enum CodingKeys: String, CodingKey {
        case thingId = "thing_id"
    }
}
