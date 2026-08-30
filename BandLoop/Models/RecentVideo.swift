import Foundation

struct SavedLoop: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var start: Double
    var end: Double
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        start: Double,
        end: Double,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
        self.createdAt = createdAt
    }
}

struct RecentVideo: Identifiable, Codable, Equatable {
    let id: String
    var sourceURL: String
    var title: String
    var lastPosition: Double
    var duration: Double
    var loopStart: Double?
    var loopEnd: Double?
    var playbackRate: Double
    var savedLoops: [SavedLoop]
    var updatedAt: Date

    init(
        id: String,
        sourceURL: String,
        title: String,
        lastPosition: Double,
        duration: Double,
        loopStart: Double?,
        loopEnd: Double?,
        playbackRate: Double,
        savedLoops: [SavedLoop] = [],
        updatedAt: Date
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.lastPosition = lastPosition
        self.duration = duration
        self.loopStart = loopStart
        self.loopEnd = loopEnd
        self.playbackRate = playbackRate
        self.savedLoops = savedLoops
        self.updatedAt = updatedAt
    }

    var thumbnailURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
    }

    var hasLoop: Bool {
        guard let loopStart, let loopEnd else { return false }
        return loopEnd > loopStart
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceURL
        case title
        case lastPosition
        case duration
        case loopStart
        case loopEnd
        case playbackRate
        case savedLoops
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceURL = try container.decode(String.self, forKey: .sourceURL)
        title = try container.decode(String.self, forKey: .title)
        lastPosition = try container.decode(Double.self, forKey: .lastPosition)
        duration = try container.decode(Double.self, forKey: .duration)
        loopStart = try container.decodeIfPresent(Double.self, forKey: .loopStart)
        loopEnd = try container.decodeIfPresent(Double.self, forKey: .loopEnd)
        playbackRate = try container.decode(Double.self, forKey: .playbackRate)
        savedLoops = try container.decodeIfPresent([SavedLoop].self, forKey: .savedLoops) ?? []
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}
