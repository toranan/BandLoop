import SwiftUI
import WebKit

struct YouTubePlayerView: UIViewRepresentable {
    @ObservedObject var controller: YouTubePlayerController

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(controller, name: "bandloop")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = controller
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        controller.attach(webView)

        // YouTube requires WebView embeds to identify the embedding app through
        // the HTTP Referer. Using youtube.com itself as the base URL is rejected
        // as an invalid embed context (player error 152-4). A Bundle-ID origin
        // gives WKWebView a stable, app-specific Referer as required by YouTube.
        let bundleID = Bundle.main.bundleIdentifier?.lowercased() ?? "com.bandloop.ios"
        let appOrigin = "https://\(bundleID)"
        let html = Self.playerHTML.replacingOccurrences(of: "__BANDLOOP_ORIGIN__", with: appOrigin)
        webView.loadHTMLString(html, baseURL: URL(string: "\(appOrigin)/"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: ()) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bandloop")
    }

    private static let playerHTML = #"""
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="initial-scale=1, width=device-width, viewport-fit=cover">
      <meta name="referrer" content="strict-origin-when-cross-origin">
      <style>
        html, body, #player { width: 100%; height: 100%; margin: 0; padding: 0; overflow: hidden; background: #000; }
        iframe { display: block; }
      </style>
    </head>
    <body>
      <div id="player"></div>
      <script>
        let player = null;
        let playerReady = false;
        let desiredRate = 1;
        let loopStart = null;
        let loopEnd = null;
        let loopEnabled = false;
        let loopSeeking = false;

        function post(payload) {
          window.webkit.messageHandlers.bandloop.postMessage(payload);
        }

        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {
            width: '100%',
            height: '100%',
            playerVars: {
              playsinline: 1,
              autoplay: 0,
              controls: 0,
              fs: 0,
              rel: 0,
              iv_load_policy: 3,
              enablejsapi: 1,
              origin: '__BANDLOOP_ORIGIN__'
            },
            events: {
              onReady: onReady,
              onStateChange: onStateChange,
              onError: event => post({ type: 'error', code: event.data })
            }
          });
        }

        function onReady() {
          playerReady = true;
          post({ type: 'ready' });
          window.setInterval(tick, 100);
        }

        function onStateChange(event) {
          post({ type: 'state', value: event.data });
          if (event.data === 1 || event.data === 5) {
            window.setTimeout(() => {
              try {
                player.setPlaybackRate(desiredRate);
                const data = player.getVideoData();
                post({ type: 'metadata', title: data && data.title ? data.title : '' });
              } catch (_) {}
            }, 80);
          }
        }

        function tick() {
          if (!playerReady || !player || typeof player.getCurrentTime !== 'function') return;
          try {
            const current = player.getCurrentTime() || 0;
            const duration = player.getDuration() || 0;
            post({ type: 'time', current: current, duration: duration });

            if (loopEnabled && loopStart !== null && loopEnd !== null &&
                loopEnd > loopStart && current >= loopEnd - 0.045 && !loopSeeking) {
              loopSeeking = true;
              player.seekTo(loopStart, true);
              post({ type: 'looped' });
              window.setTimeout(() => { loopSeeking = false; }, 180);
            }
          } catch (_) {}
        }

        function bandLoopLoad(videoID, startSeconds) {
          if (!playerReady) return;
          loopSeeking = false;
          player.loadVideoById({ videoId: videoID, startSeconds: Math.max(0, startSeconds || 0) });
        }

        function bandLoopPlay() { if (playerReady) player.playVideo(); }
        function bandLoopPause() { if (playerReady) player.pauseVideo(); }
        function bandLoopSeek(seconds) { if (playerReady) player.seekTo(Math.max(0, seconds), true); }
        function bandLoopSetRate(rate) {
          desiredRate = rate;
          if (playerReady) player.setPlaybackRate(rate);
        }
        function bandLoopConfigure(start, end, enabled) {
          loopStart = start;
          loopEnd = end;
          loopEnabled = enabled;
          loopSeeking = false;
        }
      </script>
      <script src="https://www.youtube.com/iframe_api"></script>
    </body>
    </html>
    """#
}
