import Foundation

struct YouTubeSearchResult: Identifiable, Equatable {
    let id: String
    let title: String
    let channelTitle: String
    let thumbnailURL: URL?
}

enum YouTubeSearchError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case quotaExceeded
    case badResponse
    case noResults

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "YouTube 검색 API 키를 먼저 설정해 주세요."
        case .invalidAPIKey:
            return "YouTube API 키가 올바르지 않거나 앱 제한 설정이 맞지 않아요."
        case .quotaExceeded:
            return "오늘의 YouTube 검색 한도를 모두 사용했어요."
        case .badResponse:
            return "YouTube 검색 결과를 불러오지 못했어요."
        case .noResults:
            return "검색 결과가 없어요. 다른 검색어를 입력해 보세요."
        }
    }
}

struct YouTubeSearchService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String) async throws -> [YouTubeSearchResult] {
        guard let apiKey = Self.apiKey else {
            throw YouTubeSearchError.missingAPIKey
        }

        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "videoEmbeddable", value: "true"),
            URLQueryItem(name: "videoSyndicated", value: "true"),
            URLQueryItem(name: "maxResults", value: "12"),
            URLQueryItem(name: "regionCode", value: "KR"),
            URLQueryItem(name: "relevanceLanguage", value: "ko"),
            URLQueryItem(name: "safeSearch", value: "moderate"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "key", value: apiKey)
        ]

        guard let url = components.url else { throw YouTubeSearchError.badResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let bundleID = Bundle.main.bundleIdentifier {
            request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeSearchError.badResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseText = String(decoding: data, as: UTF8.self)
            if responseText.contains("quotaExceeded") || responseText.contains("rateLimitExceeded") {
                throw YouTubeSearchError.quotaExceeded
            }
            if httpResponse.statusCode == 400 || httpResponse.statusCode == 403 {
                throw YouTubeSearchError.invalidAPIKey
            }
            throw YouTubeSearchError.badResponse
        }

        let responseBody = try JSONDecoder().decode(SearchResponse.self, from: data)
        let results = responseBody.items.compactMap { item -> YouTubeSearchResult? in
            guard let videoID = item.id.videoId else { return nil }
            return YouTubeSearchResult(
                id: videoID,
                title: item.snippet.title.htmlDecoded,
                channelTitle: item.snippet.channelTitle.htmlDecoded,
                thumbnailURL: URL(string: item.snippet.thumbnails.medium?.url ?? item.snippet.thumbnails.default.url)
            )
        }

        guard !results.isEmpty else { throw YouTubeSearchError.noResults }
        return results
    }

    private static var apiKey: String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "YouTubeAPIKey") as? String else {
            return nil
        }
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != "YOUR_API_KEY_HERE" else { return nil }
        return key
    }
}

private struct SearchResponse: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let id: ItemID
        let snippet: Snippet
    }

    struct ItemID: Decodable {
        let videoId: String?
    }

    struct Snippet: Decodable {
        let title: String
        let channelTitle: String
        let thumbnails: Thumbnails
    }

    struct Thumbnails: Decodable {
        let `default`: Thumbnail
        let medium: Thumbnail?
    }

    struct Thumbnail: Decodable {
        let url: String
    }
}

private extension String {
    var htmlDecoded: String {
        replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
