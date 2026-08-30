import Foundation

enum YouTubeURLParser {
    private static let videoIDPattern = #"^[A-Za-z0-9_-]{11}$"#

    static func videoID(from rawInput: String) -> String? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if input.range(of: videoIDPattern, options: .regularExpression) != nil {
            return input
        }

        let normalized = input.contains("://") ? input : "https://\(input)"
        guard let components = URLComponents(string: normalized),
              let host = components.host?.lowercased() else {
            return nil
        }

        let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var candidate: String?

        switch cleanHost {
        case "youtu.be":
            candidate = components.path.split(separator: "/").first.map(String.init)
        case "youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com":
            let parts = components.path.split(separator: "/").map(String.init)
            if components.path == "/watch" {
                candidate = components.queryItems?.first(where: { $0.name == "v" })?.value
            } else if let markerIndex = parts.firstIndex(where: { ["shorts", "embed", "live"].contains($0) }),
                      parts.indices.contains(markerIndex + 1) {
                candidate = parts[markerIndex + 1]
            }
        default:
            return nil
        }

        guard let candidate else { return nil }
        let trimmed = String(candidate.prefix(11))
        return trimmed.range(of: videoIDPattern, options: .regularExpression) == nil ? nil : trimmed
    }

    static func canonicalURL(for videoID: String) -> String {
        "https://www.youtube.com/watch?v=\(videoID)"
    }
}
