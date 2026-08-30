import Combine
import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var videos: [RecentVideo] = []

    private let defaults: UserDefaults
    private let storageKey: String
    private let maximumCount: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "bandloop.recent-videos.v1",
        maximumCount: Int = 20
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maximumCount = maximumCount
        load()
    }

    func video(id: String) -> RecentVideo? {
        videos.first(where: { $0.id == id })
    }

    func upsert(_ video: RecentVideo) {
        videos.removeAll(where: { $0.id == video.id })
        videos.insert(video, at: 0)
        if videos.count > maximumCount {
            videos.removeLast(videos.count - maximumCount)
        }
        save()
    }

    func remove(id: String) {
        videos.removeAll(where: { $0.id == id })
        save()
    }

    func removeAll() {
        videos = []
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([RecentVideo].self, from: data) else {
            return
        }
        videos = Array(decoded.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(maximumCount))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(videos) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
