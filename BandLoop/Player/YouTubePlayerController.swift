import Combine
import Foundation
import WebKit

final class YouTubePlayerController: NSObject, ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var videoTitle = ""
    @Published private(set) var loopCount = 0
    @Published private(set) var playbackState = -1
    @Published private(set) var playbackEndedCount = 0
    @Published private(set) var errorMessage: String?

    private weak var webView: WKWebView?
    private var currentVideoID: String?
    private var requestedStartTime: Double = 0
    private var requestedAutoplay = true
    private var desiredRate: Double = 1
    private var loopStart: Double?
    private var loopEnd: Double?
    private var loopEnabled = false

    func attach(_ webView: WKWebView) {
        self.webView = webView
        isReady = false
    }

    func detach(_ webView: WKWebView) {
        if self.webView === webView {
            self.webView = nil
            isReady = false
        }
    }

    func load(videoID: String, startAt: Double = 0, autoplay: Bool = true) {
        currentVideoID = videoID
        requestedStartTime = max(0, startAt)
        requestedAutoplay = autoplay
        currentTime = requestedStartTime
        duration = 0
        videoTitle = ""
        loopCount = 0
        playbackState = -1
        isPlaying = false
        errorMessage = nil
        guard isReady else { return }
        sendLoadCommand()
    }

    func togglePlayback() {
        evaluate(isPlaying ? "bandLoopPause()" : "bandLoopPlay()")
    }

    func play() {
        evaluate("bandLoopPlay()")
    }

    func pause() {
        evaluate("bandLoopPause()")
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), duration > 0 ? duration : seconds)
        currentTime = clamped
        evaluate("bandLoopSeek(\(javascriptNumber(clamped)))")
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func setPlaybackRate(_ rate: Double) {
        desiredRate = rate
        evaluate("bandLoopSetRate(\(javascriptNumber(rate)))")
    }

    func setLoop(start: Double?, end: Double?, enabled: Bool) {
        loopStart = start
        loopEnd = end
        loopEnabled = enabled
        loopCount = 0
        applyLoopConfiguration()
    }

    func clearError() {
        errorMessage = nil
    }

    private func sendLoadCommand() {
        guard let currentVideoID else { return }
        let command = requestedAutoplay ? "bandLoopLoad" : "bandLoopCue"
        evaluate("\(command)('\(currentVideoID)', \(javascriptNumber(requestedStartTime)))")
        evaluate("bandLoopSetRate(\(javascriptNumber(desiredRate)))")
        applyLoopConfiguration()
    }

    private func applyLoopConfiguration() {
        let startValue = loopStart.map(javascriptNumber) ?? "null"
        let endValue = loopEnd.map(javascriptNumber) ?? "null"
        evaluate("bandLoopConfigure(\(startValue), \(endValue), \(loopEnabled ? "true" : "false"))")
    }

    private func javascriptNumber(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func evaluate(_ script: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(script)
        }
    }
}

extension YouTubePlayerController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bandloop",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            switch type {
            case "ready":
                self.isReady = true
                self.sendLoadCommand()
            case "state":
                let state = (body["value"] as? NSNumber)?.intValue ?? -1
                if state == 0, self.playbackState != 0 {
                    self.playbackEndedCount += 1
                }
                self.playbackState = state
                self.isPlaying = state == 1
            case "time":
                if let current = body["current"] as? NSNumber {
                    self.currentTime = current.doubleValue
                }
                if let duration = body["duration"] as? NSNumber {
                    self.duration = duration.doubleValue
                }
            case "metadata":
                if let title = body["title"] as? String, !title.isEmpty {
                    self.videoTitle = title
                }
            case "looped":
                self.loopCount += 1
            case "error":
                let code = (body["code"] as? NSNumber)?.intValue ?? 0
                self.errorMessage = Self.message(forYouTubeError: code)
                self.isPlaying = false
            default:
                break
            }
        }
    }

    private static func message(forYouTubeError code: Int) -> String {
        switch code {
        case 2:
            return "유튜브 링크를 다시 확인해 주세요."
        case 5:
            return "이 영상은 현재 플레이어에서 재생할 수 없어요."
        case 100:
            return "삭제되었거나 비공개인 영상이에요."
        case 101, 150:
            return "업로더가 외부 앱 재생을 허용하지 않은 영상이에요."
        case 153:
            return "유튜브가 앱 플레이어를 확인하지 못했어요. 잠시 뒤 다시 시도해 주세요."
        default:
            return "영상을 불러오지 못했어요. (오류 \(code))"
        }
    }
}

extension YouTubePlayerController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        errorMessage = "인터넷 연결을 확인해 주세요."
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        errorMessage = "인터넷 연결을 확인해 주세요."
    }
}
