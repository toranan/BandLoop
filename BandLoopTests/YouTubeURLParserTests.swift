import XCTest
@testable import BandLoop

final class YouTubeURLParserTests: XCTestCase {
    func testParsesCommonYouTubeLinks() {
        let id = "dQw4w9WgXcQ"
        XCTAssertEqual(YouTubeURLParser.videoID(from: "https://www.youtube.com/watch?v=\(id)&t=42"), id)
        XCTAssertEqual(YouTubeURLParser.videoID(from: "https://youtu.be/\(id)?si=abc"), id)
        XCTAssertEqual(YouTubeURLParser.videoID(from: "https://youtube.com/shorts/\(id)"), id)
        XCTAssertEqual(YouTubeURLParser.videoID(from: "https://www.youtube.com/live/\(id)?feature=share"), id)
        XCTAssertEqual(YouTubeURLParser.videoID(from: id), id)
    }

    func testRejectsNonYouTubeAndMalformedLinks() {
        XCTAssertNil(YouTubeURLParser.videoID(from: ""))
        XCTAssertNil(YouTubeURLParser.videoID(from: "https://example.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(YouTubeURLParser.videoID(from: "https://youtube.com/watch?v=short"))
    }
}
