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
    @State private var currentUserId: UUID?
    @State private var currentUserName: String?

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
                                    isCurrentUser: message.userId == currentUserId,
                                    currentUserName: currentUserName
                                )
                                .id(message.id)
                            }
                        }
                        .padding()
                        .onAppear {
                            // Scroll to bottom when content first appears
                            scrollToBottom(proxy: proxy, delay: 0.3)
                        }
                    }
                    .onChange(of: messages.count) { oldCount in
                        // Scroll to bottom when messages count changes
                        // Use longer delay for initial load (0 -> N messages)
                        let isInitialLoad = oldCount == 0
                        scrollToBottom(proxy: proxy, animated: !isInitialLoad, delay: isInitialLoad ? 0.4 : 0.2)
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

    func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = false, delay: Double = 0.2) {
        guard let lastMessage = messages.last else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if animated {
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }

    func loadCurrentUser() async {
        do {
            let session = try await supabase.auth.session
            currentUserId = session.user.id

            // Get user name from metadata or email
            let metadata = session.user.userMetadata
            if let fullNameJSON = metadata["full_name"],
               case let .string(fullName) = fullNameJSON {
                currentUserName = fullName
            } else {
                currentUserName = session.user.email ?? "You"
            }
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

        // Subscribe to INSERT events on the messages table filtered by thing_id (for persistence)
        let insertions = await channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "messages",
            filter: "thing_id=eq.\(thingId)"
        )

        // Subscribe to broadcast events (for instant real-time updates)
        let broadcasts = channel.broadcastStream(event: "message")

        realtimeChannel = channel

        // Subscribe to the channel
        await channel.subscribe()

        // Listen for broadcast messages (instant updates)
        Task {
            for await broadcast in broadcasts {
                await handleBroadcastMessage(broadcast)
            }
        }

        // Listen for database changes (persistent updates, fallback)
        Task {
            for await insertion in insertions {
                await handleNewMessage(insertion.record)
            }
        }
    }

    func handleBroadcastMessage(_ payload: JSONObject) async {
        // Handle instant broadcast messages
        do {
            // Convert JSONObject (Dictionary<String, AnyJSON>) to encodable format
            let jsonData = try JSONEncoder().encode(payload)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let broadcastMsg = try decoder.decode(BroadcastMessage.self, from: jsonData)

            // Add the message optimistically (it will be confirmed by postgres change)
            await MainActor.run {
                // Check if message with this temporary/real ID already exists
                if !messages.contains(where: { $0.message == broadcastMsg.message && $0.userId == broadcastMsg.userId && abs($0.date.timeIntervalSince(broadcastMsg.date)) < 2 }) {
                    // Create a temporary ChatMessage from broadcast
                    let tempMessage = ChatMessage(
                        id: broadcastMsg.id ?? UUID(),
                        thingId: UUID(uuidString: thingId) ?? UUID(),
                        message: broadcastMsg.message,
                        userId: broadcastMsg.userId,
                        date: broadcastMsg.date,
                        meta: broadcastMsg.meta,
                        profile: nil  // Profile will come from DB
                    )
                    messages.append(tempMessage)
                }
            }
        } catch {
            debugPrint("Error decoding broadcast message:", error)
        }
    }

    func handleNewMessage(_ record: [String: AnyJSON]) async {
        // Decode the record to ChatMessage from database
        do {
            let jsonData = try JSONEncoder().encode(record)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let message = try decoder.decode(ChatMessage.self, from: jsonData)

            // Add the new message if it doesn't already exist (deduplication)
            await MainActor.run {
                if !messages.contains(where: { $0.id == message.id }) {
                    // Remove any temporary message that matches this one
                    messages.removeAll { tempMsg in
                        tempMsg.message == message.message &&
                        tempMsg.userId == message.userId &&
                        abs(tempMsg.date.timeIntervalSince(message.date)) < 2
                    }
                    messages.append(message)
                }
            }
        } catch {
            debugPrint("Error decoding database message:", error)
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
            guard let channel = realtimeChannel else {
                throw NSError(domain: "ChatRoom", code: -1, userInfo: [NSLocalizedDescriptionKey: "Channel not initialized"])
            }

            // Create ISO8601 date string for meta
            let dateFormatter = ISO8601DateFormatter()
            let createDate = dateFormatter.string(from: Date())
            let now = Date()
            let userName = currentUserName ?? "Unknown"

            // 1. Broadcast the message immediately for instant updates
            let broadcastMsg = BroadcastMessage(
                id: nil,  // Will be assigned by database
                message: messageContent,
                userId: currentUserId,
                date: now,
                meta: [
                    "createDate": AnyCodable(createDate),
                    "nameFromAuth": AnyCodable(userName)
                ]
            )

            // Encode broadcast message to JSON
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let broadcastData = try encoder.encode(broadcastMsg)

            // Decode as JSONObject directly
            let decoder = JSONDecoder()
            let broadcastJSON = try decoder.decode(JSONObject.self, from: broadcastData)

            // Send broadcast
            await channel.broadcast(event: "message", message: broadcastJSON)

            // 2. Write to database for persistence (this happens in parallel)
            try await supabase.rpc(
                "add_chat_message",
                params: AddChatMessageParams(
                    message: messageContent,
                    thingId: thingId,
                    meta: MessageMeta(createDate: createDate, nameFromAuth: userName)
                )
            ).execute()

            // The broadcast gives instant feedback, and the database write ensures persistence
            // The postgres change listener will update with the real ID and profile info

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
    let currentUserName: String?

    var body: some View {
        HStack {
            if isCurrentUser {
                Spacer(minLength: 60)
            }

            VStack(alignment: isCurrentUser ? .trailing : .leading, spacing: 4) {
                // Always show user name
                Text(displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

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

    private var displayName: String {
        if isCurrentUser {
            return currentUserName ?? "You"
        } else {
            // First try to get name from meta->nameFromAuth
            if let meta = message.meta,
               let nameFromAuthCodable = meta["nameFromAuth"],
               let nameFromAuth = nameFromAuthCodable.value as? String {
                return nameFromAuth
            }
            // Fall back to profile full_name
            if let fullName = message.profile?.fullName {
                return fullName
            }
            // Last resort
            return "Unknown User"
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
    let nameFromAuth: String
}

// Broadcast message structure (for instant real-time updates)
struct BroadcastMessage: Codable {
    let id: UUID?
    let message: String
    let userId: UUID?
    let date: Date
    let meta: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case id
        case message
        case userId = "user_id"
        case date
        case meta
    }
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
