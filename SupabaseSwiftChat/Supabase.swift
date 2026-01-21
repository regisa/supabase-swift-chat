import Foundation
import Supabase

struct Config {
    static let shared = Config()

    private let config: NSDictionary

    private init() {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let config = NSDictionary(contentsOfFile: path) else {
            fatalError("Config.plist not found. Please copy Config.example.plist to Config.plist and add your credentials.")
        }
        self.config = config
    }

    var supabaseURL: String {
        guard let url = config["SupabaseURL"] as? String else {
            fatalError("SupabaseURL not found in Config.plist")
        }
        return url
    }

    var supabaseKey: String {
        guard let key = config["SupabaseKey"] as? String else {
            fatalError("SupabaseKey not found in Config.plist")
        }
        return key
    }
}

let supabase = SupabaseClient(
    supabaseURL: URL(string: Config.shared.supabaseURL)!,
    supabaseKey: Config.shared.supabaseKey
)
