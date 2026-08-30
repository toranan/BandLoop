import XCTest
@testable import BandLoop

@MainActor
final class HistoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "HistoryStoreTests")
        defaults.removePersistentDomain(forName: "HistoryStoreTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "HistoryStoreTests")
        defaults = nil
        super.tearDown()
    }

    func testKeepsOnlyNewestTwentyVideos() {
        let store = HistoryStore(defaults: defaults, storageKey: "recent", maximumCount: 20)

        for index in 0..<23 {
            store.upsert(makeVideo(id: String(format: "video%06d", index), date: Date(timeIntervalSince1970: Double(index))))
        }

        XCTAssertEqual(store.videos.count, 20)
        XCTAssertEqual(store.videos.first?.id, "video000022")
        XCTAssertNil(store.video(id: "video000000"))
    }

    func testUpsertMovesExistingVideoToFront() {
        let store = HistoryStore(defaults: defaults, storageKey: "recent")
        store.upsert(makeVideo(id: "aaaaaaaaaaa", date: .distantPast))
        store.upsert(makeVideo(id: "bbbbbbbbbbb", date: .now))

        var first = makeVideo(id: "aaaaaaaaaaa", date: .now)
        first.lastPosition = 42
        store.upsert(first)

        XCTAssertEqual(store.videos.map(\.id), ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        XCTAssertEqual(store.video(id: "aaaaaaaaaaa")?.lastPosition, 42)
    }

    func testPersistsSavedLoopsForEachVideo() {
        let storageKey = "recent-with-saved-loops"
        let store = HistoryStore(defaults: defaults, storageKey: storageKey)
        var video = makeVideo(id: "aaaaaaaaaaa", date: .now)
        video.savedLoops = [
            SavedLoop(name: "기타 솔로", start: 42.5, end: 58.25)
        ]
        store.upsert(video)

        let reloadedStore = HistoryStore(defaults: defaults, storageKey: storageKey)
        let reloadedLoop = reloadedStore.video(id: video.id)?.savedLoops.first

        XCTAssertEqual(reloadedLoop?.name, "기타 솔로")
        XCTAssertEqual(reloadedLoop?.start, 42.5)
        XCTAssertEqual(reloadedLoop?.end, 58.25)
    }

    func testLoadsLegacyVideoWithoutSavedLoops() throws {
        let storageKey = "legacy-recent"
        let legacyVideo = LegacyRecentVideo(
            id: "aaaaaaaaaaa",
            sourceURL: "https://youtube.com/watch?v=aaaaaaaaaaa",
            title: "Legacy",
            lastPosition: 12,
            duration: 120,
            loopStart: 20,
            loopEnd: 30,
            playbackRate: 0.75,
            updatedAt: .now
        )
        defaults.set(try JSONEncoder().encode([legacyVideo]), forKey: storageKey)

        let store = HistoryStore(defaults: defaults, storageKey: storageKey)

        XCTAssertEqual(store.videos.count, 1)
        XCTAssertTrue(store.videos[0].savedLoops.isEmpty)
        XCTAssertEqual(store.videos[0].loopStart, 20)
        XCTAssertEqual(store.videos[0].loopEnd, 30)
    }

    private func makeVideo(id: String, date: Date) -> RecentVideo {
        RecentVideo(
            id: id,
            sourceURL: "https://youtube.com/watch?v=\(id)",
            title: id,
            lastPosition: 0,
            duration: 0,
            loopStart: nil,
            loopEnd: nil,
            playbackRate: 1,
            updatedAt: date
        )
    }

    private struct LegacyRecentVideo: Codable {
        let id: String
        let sourceURL: String
        let title: String
        let lastPosition: Double
        let duration: Double
        let loopStart: Double?
        let loopEnd: Double?
        let playbackRate: Double
        let updatedAt: Date
    }
}
