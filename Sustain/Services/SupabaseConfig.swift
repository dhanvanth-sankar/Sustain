import Foundation

/// The Supabase project's base URL and public anon key, read from
/// `Info.plist` the same way `AIProteinEstimator`'s function URL/anon key
/// already are (sourced from `Secrets.xcconfig` via `project.yml`, never
/// hardcoded, never a secret on their own — see that file's header comment
/// for the full "this is safe to embed client-side" reasoning, which applies
/// identically here).
///
/// This is a *separate* value from `SupabaseFunctionURL`: that one points at
/// one specific deployed Edge Function
/// (`.../functions/v1/anthropic-proxy`), while `AuthManager` and
/// `CloudSyncManager` need the project's root URL to reach Supabase's own
/// built-in Auth (`/auth/v1/...`) and PostgREST (`/rest/v1/...`) APIs, which
/// live at a different path than any Edge Function.
enum SupabaseConfig {
    static let shared: (projectURL: URL, anonKey: String)? = {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: "SupabaseProjectURL") as? String,
              let anonKey = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
              !urlString.isEmpty, !anonKey.isEmpty,
              let url = URL(string: urlString) else {
            return nil
        }
        return (url, anonKey)
    }()

    /// Shared JSON coding for every Supabase Auth/PostgREST call. Supabase
    /// returns timestamps as ISO-8601 with fractional seconds
    /// (`2026-07-30T12:34:56.789012+00:00`), which `JSONDecoder`'s built-in
    /// `.iso8601` strategy can't parse (it rejects the fractional-second
    /// component and throws on every single date field) — this bit during
    /// initial testing of this exact pattern in `AIProteinEstimator`'s sibling
    /// services, so both formatters are configured with `.withFractionalSeconds`
    /// up front rather than discovering the gap against a live response.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601Formatter.string(from: date))
        }
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = iso8601Formatter.date(from: string) {
                return date
            }
            // Fall back to no-fractional-seconds in case a given row's
            // timestamp happens to land exactly on a whole second (Postgres
            // sometimes omits the trailing ".000000" in that case).
            if let date = iso8601FormatterNoFraction.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date format: \(string)")
        }
        return decoder
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601FormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
