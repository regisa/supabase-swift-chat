import SwiftUI
import Supabase
import Realtime

struct ChatRoomView: View {
    let thingId: String

    @State private var messages: [ChatMessage] = []
    @State private var newMessageText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var realtimeChannel: RealtimeChannelV2?
    @State private var currentUserId: String?

    var body: some View {
        VStack(spacing: 0) {
            // Messages List
            if isLoading && messages.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, messages.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await loadMessages() }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 50))
                        .foregroundStyle(.gray)
                    Text("No messages yet\nBe the first to send a message!")
                        .foregroundStyle(.gray)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    isCurrentUser: message.userId == currentUserId
                                )
                                .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _ in
                        if let lastMessage = messages.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            // Message Input
            HStack(spacing: 12) {
                TextField("Type a message...", text: $newMessageText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                Button {
                    Task { await sendMessage() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(newMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .blue)
                }
                .disabled(newMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(Color(.systemBackground))
        }
        .navigationTitle("Chat: \(thingId)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadCurrentUser()
            await loadMessages()
            await setupRealtimeSubscription()
        }
        .onDisappear {
            Task {
                await unsubscribeFromRealtime()
            }
        }
    }

    func loadCurrentUser() async {
        do {
            let session = try await supabase.auth.session
            currentUserId = session.user.id.uuidString
        } catch {
            debugPrint("Error loading current user:", error)
        }
    }

    func loadMessages() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Match web implementation: load messages with profile information
            let response: [ChatMessage] = try await supabase
                .from("messages")
                .select("*, profile:user_id(id, raw_user_meta_data->full_name)")
                .eq("thing_id", value: thingId)
                .order("date", ascending: true)
                .execute()
                .value

            messages = response
        } catch {
            // If the profile join fails, try without it
            debugPrint("Error loading messages with profile, trying without:", error)
            do {
                let response: [ChatMessage] = try await supabase
                    .from("messages")
                    .select()
                    .eq("thing_id", value: thingId)
                    .order("date", ascending: true)
                    .execute()
                    .value

                messages = response
            } catch {
                errorMessage = error.localizedDescription
                debugPrint("Error loading messages:", error)
            }
        }
    }

    func setupRealtimeSubscription() async {
        // Create a channel for this specific thing_id
        let channel = supabase.channel("messages:\(thingId)")

        // Subscribe to INSERT events on the messages table filtered by thing_id
        let insertions = await channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "messages",
            filter: "thing_id=eq.\(thingId)"
        )

        realtimeChannel = channel

        // Subscribe to the channel
        await channel.subscribe()

        // Listen for new messages
        Task {
            for await insertion in insertions {
                await handleNewMessage(insertion.record)
            }
        }
    }

    func handleNewMessage(_ record: [String: AnyJSON]) async {
        // Decode the record to ChatMessage
        do {
            let jsonData = try JSONEncoder().encode(record)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let message = try decoder.decode(ChatMessage.self, from: jsonData)

            // Add the new message if it doesn't already exist
            await MainActor.run {
                if !messages.contains(where: { $0.id == message.id }) {
                    messages.append(message)
                }
            }
        } catch {
            debugPrint("Error decoding realtime message:", error)
        }
    }

    func unsubscribeFromRealtime() async {
        if let channel = realtimeChannel {
            await supabase.removeChannel(channel)
            realtimeChannel = nil
        }
    }

    func sendMessage() async {
        let messageContent = newMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageContent.isEmpty else { return }

        // Clear the input immediately for better UX
        newMessageText = ""

        do {
            // Create ISO8601 date string for meta
            let dateFormatter = ISO8601DateFormatter()
            let createDate = dateFormatter.string(from: Date())

            // Use the RPC function like the web version
            try await supabase.rpc(
                "add_chat_message",
                params: AddChatMessageParams(
                    message: messageContent,
                    thingId: thingId,
                    meta: MessageMeta(createDate: createDate)
                )
            ).execute()

            // The realtime subscription will handle adding the message to the UI

        } catch {
            errorMessage = "Failed to send message: \(error.localizedDescription)"
            debugPrint("Error sending message:", error)
            // Restore the message text if sending failed
            newMessageText = messageContent
        }
    }
}

struct MessageBubbleView: View {
    let message: ChatMessage
    let isCurrentUser: Bool

    var body: some View {
        HStack {
            if isCurrentUser {
                Spacer(minLength: 60)
            }

            VStack(alignment: isCurrentUser ? .trailing : .leading, spacing: 4) {
                // Show user name for messages from others
                if !isCurrentUser, let profile = message.profile, let fullName = profile.fullName {
                    Text(fullName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }

                Text(message.message ?? "")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isCurrentUser ? Color.blue : Color(.systemGray5))
                    .foregroundStyle(isCurrentUser ? .white : .primary)
                    .cornerRadius(16)

                Text(message.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }

            if !isCurrentUser {
                Spacer(minLength: 60)
            }
        }
    }
}

// MARK: - Models

struct ChatMessage: Codable, Identifiable {
    let id: UUID
    let thingId: UUID
    let message: String?
    let userId: UUID?
    let date: Date
    let meta: [String: AnyCodable]?
    let profile: UserProfile?

    enum CodingKeys: String, CodingKey {
        case id
        case thingId = "thing_id"
        case message
        case userId = "user_id"
        case date
        case meta
        case profile
    }
}

struct UserProfile: Codable {
    let id: UUID
    let fullName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
    }
}

// RPC function parameters to match web implementation
struct AddChatMessageParams: Encodable {
    let message: String
    let thingId: String
    let meta: MessageMeta

    enum CodingKeys: String, CodingKey {
        case message
        case thingId = "thing_id"
        case meta
    }
}

struct MessageMeta: Encodable {
    let createDate: String
}

// Helper for decoding arbitrary JSON values
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
