import Combine
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var history = HistoryStore()
    @StateObject private var player = YouTubePlayerController()
    @Environment(\.scenePhase) private var scenePhase

    @State private var currentVideo: RecentVideo?
    @State private var linkText = ""
    @State private var linkError: String?
    @State private var isSearchPresented = false
    @State private var isFeedbackPresented = false
    @FocusState private var linkFieldFocused: Bool

    private let saveTimer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if currentVideo != nil {
                PracticeScreen(
                    video: Binding(
                        get: { currentVideo! },
                        set: { currentVideo = $0 }
                    ),
                    player: player,
                    onBack: closePlayer,
                    onPersist: persistActiveVideo
                )
                .id(currentVideo?.id)
            } else {
                HomeScreen(
                    linkText: $linkText,
                    linkError: linkError,
                    videos: history.videos,
                    linkFieldFocused: $linkFieldFocused,
                    onOpenLink: openFromInput,
                    onSearch: { isSearchPresented = true },
                    onFeedback: { isFeedbackPresented = true },
                    onOpenRecent: openVideo,
                    onRemoveRecent: history.remove,
                    onClearHistory: history.removeAll
                )
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $isSearchPresented) {
            YouTubeSearchScreen { result in
                selectSearchResult(result)
                isSearchPresented = false
            }
        }
        .sheet(isPresented: $isFeedbackPresented) {
            FeedbackSheet()
        }
        .onReceive(saveTimer) { _ in
            persistActiveVideo()
        }
        .onChange(of: player.videoTitle) { _, newTitle in
            guard !newTitle.isEmpty, var video = currentVideo else { return }
            video.title = newTitle
            currentVideo = video
            persistActiveVideo()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                persistActiveVideo()
            }
        }
    }

    private func openFromInput() {
        let enteredText = linkText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !enteredText.isEmpty {
            openLink(enteredText)
            return
        }

        guard let clipboardText = UIPasteboard.general.string,
              YouTubeURLParser.videoID(from: clipboardText) != nil else {
            linkError = "유튜브 링크를 입력하거나 복사해 주세요."
            return
        }

        linkText = clipboardText
        openLink(clipboardText)
    }

    private func openLink(_ rawLink: String) {
        guard let id = YouTubeURLParser.videoID(from: rawLink) else {
            linkError = "유튜브 링크를 다시 확인해 주세요."
            return
        }

        linkFieldFocused = false
        linkError = nil

        if let saved = history.video(id: id) {
            openVideo(saved)
            return
        }

        let video = RecentVideo(
            id: id,
            sourceURL: YouTubeURLParser.canonicalURL(for: id),
            title: "영상 불러오는 중…",
            lastPosition: 0,
            duration: 0,
            loopStart: nil,
            loopEnd: nil,
            playbackRate: 1,
            updatedAt: .now
        )
        history.upsert(video)
        openVideo(video)
    }

    private func selectSearchResult(_ result: YouTubeSearchResult) {
        linkText = YouTubeURLParser.canonicalURL(for: result.id)
        linkError = nil
        linkFieldFocused = false
    }

    private func openVideo(_ video: RecentVideo) {
        var refreshed = video
        refreshed.updatedAt = .now
        currentVideo = refreshed
        history.upsert(refreshed)
        player.load(videoID: refreshed.id, startAt: refreshed.lastPosition)
        player.setPlaybackRate(refreshed.playbackRate)
        player.setLoop(start: refreshed.loopStart, end: refreshed.loopEnd, enabled: refreshed.hasLoop)
    }

    private func persistActiveVideo() {
        guard var video = currentVideo else { return }
        video.lastPosition = player.currentTime
        video.duration = player.duration
        video.updatedAt = .now
        currentVideo = video
        history.upsert(video)
    }

    private func closePlayer() {
        persistActiveVideo()
        player.pause()
        currentVideo = nil
    }
}

private struct HomeScreen: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var linkText: String
    let linkError: String?
    let videos: [RecentVideo]
    let linkFieldFocused: FocusState<Bool>.Binding
    let onOpenLink: () -> Void
    let onSearch: () -> Void
    let onFeedback: () -> Void
    let onOpenRecent: (RecentVideo) -> Void
    let onRemoveRecent: (String) -> Void
    let onClearHistory: () -> Void

    @State private var confirmsClear = false

    var body: some View {
        ZStack {
            BandLoopTheme.background.ignoresSafeArea()

            ScrollView {
                Group {
                    if horizontalSizeClass == .regular {
                        tabletContent
                    } else {
                        phoneContent
                    }
                }
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, horizontalSizeClass == .regular ? 32 : 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .confirmationDialog("최근 영상을 모두 지울까요?", isPresented: $confirmsClear) {
            Button("20개 기록 모두 지우기", role: .destructive, action: onClearHistory)
            Button("취소", role: .cancel) {}
        }
    }

    private var phoneContent: some View {
        VStack(alignment: .leading, spacing: 30) {
            brand
            intro
            linkEntry
            recentSection
        }
        .frame(maxWidth: 720)
    }

    private var tabletContent: some View {
        VStack(alignment: .leading, spacing: 32) {
            brand

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 30) {
                    intro
                    linkEntry
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                recentSection
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var brand: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(BandLoopTheme.accent)
                    .frame(width: 44, height: 44)
                Image(systemName: "repeat")
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(Color.black)
            }

            Text("BANDLOOP")
                .font(.system(size: 17, weight: .black, design: .rounded))
                .tracking(1.5)

            Spacer()

            Button(action: onFeedback) {
                Label("개선 제안", systemImage: "bubble.left.and.pencil")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BandLoopTheme.primaryText)
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("BandLoop에 바라는 점을 보냅니다")
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("링크 붙이고\n바로 반복.")
                .font(.system(size: 42, weight: .black, design: .rounded))
                .tracking(-1.4)
                .lineSpacing(-3)

            Text("합주도, 카피도. 원하는 구간만 찍으면 끝.")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(BandLoopTheme.secondaryText)
        }
    }

    private var linkEntry: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("YOUTUBE LINK")
                .font(.caption2.weight(.black))
                .tracking(1.5)
                .foregroundStyle(BandLoopTheme.accent)

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(BandLoopTheme.secondaryText)

                TextField("유튜브 링크 붙여넣기", text: $linkText)
                    .focused(linkFieldFocused)
                    .keyboardType(.default)
                    .submitLabel(.go)
                    .onSubmit(onOpenLink)

                if !linkText.isEmpty {
                    Button {
                        linkText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(BandLoopTheme.secondaryText)
                    }
                    .accessibilityLabel("링크 지우기")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(BandLoopTheme.elevated, in: RoundedRectangle(cornerRadius: 17, style: .continuous))

            HStack(spacing: 10) {
                Button(action: onSearch) {
                    Label("검색", systemImage: "magnifyingglass")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button(action: onOpenLink) {
                    Label("열기", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            if let linkError {
                Label(linkError, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(BandLoopTheme.coral)
            } else if YouTubeURLParser.videoID(from: linkText) != nil {
                Label("링크 준비됨 · 열기를 누르세요", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(BandLoopTheme.accent)
            }
        }
        .padding(18)
        .cardStyle()
    }

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("최근 연습")
                    .font(.title2.bold())
                Text("\(videos.count)/20")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BandLoopTheme.secondaryText)
                Spacer()
                if !videos.isEmpty {
                    Button("전체 삭제") { confirmsClear = true }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BandLoopTheme.secondaryText)
                }
            }

            if videos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(BandLoopTheme.accent)
                    Text("한 번 연 영상은 여기에 저장돼요")
                        .font(.subheadline.weight(.semibold))
                    Text("링크와 반복 구간, 배속, 마지막 위치까지\n이 기기에만 최대 20개 보관합니다.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(BandLoopTheme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .cardStyle()
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(videos) { video in
                        RecentVideoRow(
                            video: video,
                            onOpen: { onOpenRecent(video) },
                            onDelete: { onRemoveRecent(video.id) }
                        )
                    }
                }
            }
        }
    }
}

private struct YouTubeSearchScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var query = ""
    @State private var results: [YouTubeSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @FocusState private var searchFieldFocused: Bool

    let onSelect: (YouTubeSearchResult) -> Void
    private let searchService = YouTubeSearchService()

    var body: some View {
        NavigationStack {
            ZStack {
                BandLoopTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    searchBar
                        .frame(maxWidth: 820)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 16)

                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    searchContent
                }
            }
            .navigationTitle("YouTube 검색")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기", systemImage: "xmark") {
                        dismiss()
                    }
                    .font(.subheadline.weight(.bold))
                }
            }
        }
        .tint(BandLoopTheme.accent)
        .preferredColorScheme(.dark)
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            searchFieldFocused = true
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(BandLoopTheme.secondaryText)

                TextField("곡명, 가수, 연주 영상 검색", text: $query)
                    .focused($searchFieldFocused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(performSearch)

                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                        errorMessage = nil
                        searchFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(BandLoopTheme.secondaryText)
                    }
                    .accessibilityLabel("검색어 지우기")
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 52)
            .background(BandLoopTheme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button(action: performSearch) {
                if isSearching {
                    ProgressView()
                        .tint(Color.black)
                        .frame(width: 62, height: 52)
                } else {
                    Text("검색")
                        .font(.subheadline.weight(.black))
                        .frame(width: 62, height: 52)
                }
            }
            .foregroundStyle(Color.black)
            .background(BandLoopTheme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .buttonStyle(.plain)
            .disabled(isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if isSearching && results.isEmpty {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(BandLoopTheme.accent)
                Text("YouTube에서 찾는 중…")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(BandLoopTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.magnifyingglass")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(BandLoopTheme.coral)
                Text(errorMessage)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(BandLoopTheme.secondaryText)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(BandLoopTheme.accent)
                Text("연습할 영상을 검색하세요")
                    .font(.headline.bold())
            }
            .multilineTextAlignment(.center)
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("검색 결과")
                            .font(.title2.bold())
                        Text("\(results.count)개")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(BandLoopTheme.secondaryText)
                        Spacer()
                    }

                    Text("영상을 고르면 링크가 입력되고 홈으로 돌아가요.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BandLoopTheme.accent)

                    LazyVGrid(columns: resultColumns, spacing: 10) {
                        ForEach(results) { result in
                            SearchResultRow(result: result) {
                                onSelect(result)
                            }
                        }
                    }
                }
                .frame(maxWidth: 1040)
                .frame(maxWidth: .infinity)
                .padding(horizontalSizeClass == .regular ? 24 : 18)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var resultColumns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible())]
        }
        return [GridItem(.flexible())]
    }

    private func performSearch() {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, !isSearching else { return }

        searchFieldFocused = false
        errorMessage = nil
        results = []
        isSearching = true

        Task { @MainActor in
            do {
                results = try await searchService.search(query: normalizedQuery)
            } catch is CancellationError {
                // The search screen was closed while waiting.
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "검색하지 못했어요."
            }
            isSearching = false
        }
    }
}

private struct SearchResultRow: View {
    let result: YouTubeSearchResult
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 13) {
                AsyncImage(url: result.thumbnailURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.white.opacity(0.06)
                            Image(systemName: "play.rectangle.fill")
                                .foregroundStyle(BandLoopTheme.secondaryText)
                        }
                    }
                }
                .frame(width: 108, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(result.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(BandLoopTheme.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(result.channelTitle)
                        .font(.caption)
                        .foregroundStyle(BandLoopTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(BandLoopTheme.accent)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle(cornerRadius: 18)
    }
}

private struct RecentVideoRow: View {
    let video: RecentVideo
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 13) {
                AsyncImage(url: video.thumbnailURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.white.opacity(0.06)
                            Image(systemName: "play.fill")
                                .foregroundStyle(BandLoopTheme.secondaryText)
                        }
                    }
                }
                .frame(width: 108, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if video.lastPosition > 0 {
                        Text(TimeFormatter.positional(video.lastPosition))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                            .padding(5)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(video.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(BandLoopTheme.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 7) {
                        if !video.savedLoops.isEmpty {
                            Label("저장 구간 \(video.savedLoops.count)개", systemImage: "bookmark.fill")
                        } else if video.hasLoop {
                            Label("최근 구간", systemImage: "repeat")
                        }
                        Text("\(video.playbackRate, specifier: "%g")×")
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle((video.hasLoop || !video.savedLoops.isEmpty) ? BandLoopTheme.accent : BandLoopTheme.secondaryText)
                }

                Spacer(minLength: 0)

                Menu {
                    Button("기록 삭제", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 44)
                        .foregroundStyle(BandLoopTheme.secondaryText)
                }
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle(cornerRadius: 18)
    }
}

private struct PracticeScreen: View {
    @Binding var video: RecentVideo
    @ObservedObject var player: YouTubePlayerController
    let onBack: () -> Void
    let onPersist: () -> Void

    @State private var loopStart: Double?
    @State private var loopEnd: Double?
    @State private var loopEnabled: Bool
    @State private var playbackRate: Double
    @State private var isImmersive = false
    @State private var isControlDrawerPresented = false
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var notice: String?
    @State private var loopPendingRename: SavedLoop?
    @State private var loopPendingDeletion: SavedLoop?
    @State private var loopRenameText = ""

    private let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    private let maximumSavedLoopCount = 10

    init(
        video: Binding<RecentVideo>,
        player: YouTubePlayerController,
        onBack: @escaping () -> Void,
        onPersist: @escaping () -> Void
    ) {
        _video = video
        self.player = player
        self.onBack = onBack
        self.onPersist = onPersist
        _loopStart = State(initialValue: video.wrappedValue.loopStart)
        _loopEnd = State(initialValue: video.wrappedValue.loopEnd)
        _loopEnabled = State(initialValue: video.wrappedValue.hasLoop)
        _playbackRate = State(initialValue: video.wrappedValue.playbackRate)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                (isImmersive ? Color.black : BandLoopTheme.background)
                    .ignoresSafeArea()

                standardPracticeLayout

                if isImmersive {
                    immersiveOverlay(in: proxy)
                }

                if let notice {
                    Text(notice)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(BandLoopTheme.accent, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear {
                if shouldAutomaticallyEnterImmersive(for: proxy.size) {
                    isImmersive = true
                }
            }
            .onChange(of: proxy.size) { _, newSize in
                if shouldAutomaticallyEnterImmersive(for: newSize) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isImmersive = true
                    }
                }
                if newSize.width <= newSize.height {
                    isControlDrawerPresented = false
                }
            }
        }
        .statusBarHidden(isImmersive)
        .persistentSystemOverlays(isImmersive ? .hidden : .automatic)
        .onAppear(perform: applyPlayerSettings)
        .onChange(of: loopStart) { _, _ in syncLoop() }
        .onChange(of: loopEnd) { _, _ in syncLoop() }
        .onChange(of: loopEnabled) { _, _ in syncLoop() }
        .onChange(of: playbackRate) { _, newRate in
            player.setPlaybackRate(newRate)
            video.playbackRate = newRate
            onPersist()
        }
        .onChange(of: player.errorMessage) { _, message in
            if let message { showNotice(message, long: true) }
        }
        .alert("구간 이름 변경", isPresented: renameAlertIsPresented) {
            TextField("구간 이름", text: $loopRenameText)
            Button("취소", role: .cancel) {
                loopPendingRename = nil
            }
            Button("저장", action: renameSavedLoop)
        } message: {
            Text("연습할 부분을 알아보기 쉽게 적어 두세요.")
        }
        .alert("저장한 구간 삭제", isPresented: deletionAlertIsPresented) {
            Button("취소", role: .cancel) {
                loopPendingDeletion = nil
            }
            Button("삭제", role: .destructive, action: deleteSavedLoop)
        } message: {
            Text("이 영상에서만 삭제되며 다른 저장 구간은 유지됩니다.")
        }
    }

    private var standardPracticeLayout: some View {
        VStack(spacing: isImmersive ? 0 : 10) {
            if !isImmersive {
                practiceHeader
                    .padding(.horizontal, 18)
            }

            playerSurface
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: isImmersive ? .infinity : nil)
                .clipShape(RoundedRectangle(cornerRadius: isImmersive ? 0 : 18, style: .continuous))
                .padding(.horizontal, isImmersive ? 0 : 16)

            if !isImmersive {
                timeline
                    .padding(.horizontal, 16)
                transport
                    .padding(.horizontal, 16)
                controlsPanel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: isImmersive ? .infinity : 900)
        .frame(maxWidth: .infinity)
    }

    private func shouldAutomaticallyEnterImmersive(for size: CGSize) -> Bool {
        size.width > size.height
    }

    private func immersiveOverlay(in proxy: GeometryProxy) -> some View {
        ZStack {
            if isControlDrawerPresented {
                Color.black.opacity(0.26)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isControlDrawerPresented = false
                        }
                    }
                    .transition(.opacity)
            }

            VStack {
                HStack {
                    Button {
                        if proxy.size.width > proxy.size.height {
                            isControlDrawerPresented = false
                            onBack()
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isControlDrawerPresented = false
                                isImmersive = false
                            }
                        }
                    } label: {
                        Image(systemName: proxy.size.width > proxy.size.height ? "chevron.left" : "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 16, weight: .black))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(Color.white)
                            .background(Color.black.opacity(0.72), in: Circle())
                    }
                    .accessibilityLabel(proxy.size.width > proxy.size.height ? "최근 영상으로 돌아가기" : "전체 화면 닫기")

                    Spacer()

                    if proxy.size.width > proxy.size.height && !isControlDrawerPresented {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                isControlDrawerPresented = true
                            }
                        } label: {
                            Label("조절", systemImage: "slider.horizontal.3")
                                .font(.caption.weight(.black))
                                .padding(.horizontal, 14)
                                .frame(height: 44)
                                .foregroundStyle(Color.black)
                                .background(BandLoopTheme.accent, in: Capsule())
                        }
                        .accessibilityLabel("연습 조절 사이드바 열기")
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.leading, max(6, proxy.safeAreaInsets.leading - 14))
            .padding(.trailing, max(6, proxy.safeAreaInsets.trailing - 14))
            .padding(.top, max(6, proxy.safeAreaInsets.top - 4))

            if isControlDrawerPresented {
                immersiveControlsDrawer(in: proxy)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isControlDrawerPresented)
    }

    private func immersiveControlsDrawer(in proxy: GeometryProxy) -> some View {
        VStack(spacing: 12) {
            HStack {
                Label("연습 조절", systemImage: "slider.horizontal.3")
                    .font(.headline.bold())
                    .foregroundStyle(BandLoopTheme.primaryText)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isControlDrawerPresented = false
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .black))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(BandLoopTheme.primaryText)
                        .background(Color.white.opacity(0.09), in: Circle())
                }
                .accessibilityLabel("연습 조절 사이드바 닫기")
            }

            Divider()
                .overlay(Color.white.opacity(0.09))

            timeline
            transport
            controlsPanel
        }
        .padding(16)
        .frame(width: min(max(proxy.size.width * 0.4, 310), 430))
        .frame(height: max(280, proxy.size.height - 16))
        .background(BandLoopTheme.background.opacity(0.97), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 28, x: -10)
        .padding(.trailing, max(8, proxy.safeAreaInsets.trailing))
        .padding(.vertical, 8)
    }

    private var practiceHeader: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .black))
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.09), in: Circle())
            }
            .accessibilityLabel("최근 영상으로 돌아가기")

            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(loopEnabled && validLoop ? "구간 반복 중 · \(player.loopCount + 1)회" : "연습 준비")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(loopEnabled && validLoop ? BandLoopTheme.accent : BandLoopTheme.secondaryText)
            }

            Spacer()

            Button {
                isImmersive = true
                isControlDrawerPresented = false
            } label: {
                Label("전체 화면", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(BandLoopTheme.accent, in: Capsule())
                    .foregroundStyle(Color.black)
            }
        }
        .frame(height: 48)
    }

    private var playerSurface: some View {
        ZStack {
            Color.black
            YouTubePlayerView(controller: player)

            if !player.isReady {
                VStack(spacing: 10) {
                    ProgressView().tint(BandLoopTheme.accent)
                    Text("유튜브 연결 중")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(BandLoopTheme.secondaryText)
                }
            }
        }
    }

    private var timeline: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                if player.duration > 0, let loopStart, let loopEnd, loopEnd > loopStart {
                    let left = geometry.size.width * loopStart / player.duration
                    let width = geometry.size.width * (loopEnd - loopStart) / player.duration
                    Capsule()
                        .fill(BandLoopTheme.accent.opacity(0.45))
                        .frame(width: max(3, width), height: 5)
                        .offset(x: left)
                }
            }
            .frame(height: 5)

            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubPosition : player.currentTime },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { player.seek(to: scrubPosition) }
                }
            )
            .tint(BandLoopTheme.accent)

            HStack {
                Text(TimeFormatter.positional(isScrubbing ? scrubPosition : player.currentTime))
                Spacer()
                Text(TimeFormatter.positional(player.duration))
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(BandLoopTheme.secondaryText)
        }
    }

    private var transport: some View {
        HStack(spacing: 22) {
            TransportButton(icon: "gobackward.5", label: "5초 뒤로") { player.skip(by: -5) }

            Button(action: player.togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 23, weight: .black))
                    .frame(width: 58, height: 48)
                    .foregroundStyle(Color.black)
                    .background(BandLoopTheme.accent, in: Capsule())
            }
            .accessibilityLabel(player.isPlaying ? "일시 정지" : "재생")

            TransportButton(icon: "goforward.5", label: "5초 앞으로") { player.skip(by: 5) }
        }
        .frame(maxWidth: .infinity)
    }

    private var controlsPanel: some View {
        ScrollView {
            controlCards
        }
        .scrollIndicators(.hidden)
    }

    private var controlCards: some View {
        VStack(spacing: 12) {
            loopCard
            speedCard
        }
    }

    private var loopCard: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("구간 반복")
                        .font(.headline.bold())
                    Text(validLoop ? "B에 닿으면 A로 돌아가요" : "재생하면서 A, B만 찍으세요")
                        .font(.caption)
                        .foregroundStyle(BandLoopTheme.secondaryText)
                }
                Spacer()
                Toggle("구간 반복", isOn: $loopEnabled)
                    .labelsHidden()
                    .disabled(!validLoop)
            }

            HStack(spacing: 10) {
                MarkerButton(
                    marker: "A",
                    caption: "시작 찍기",
                    time: loopStart,
                    color: BandLoopTheme.accent,
                    action: captureStart
                )
                MarkerButton(
                    marker: "B",
                    caption: "끝 찍기",
                    time: loopEnd,
                    color: BandLoopTheme.coral,
                    action: captureEnd
                )
            }

            if loopStart != nil || loopEnd != nil {
                VStack(spacing: 9) {
                    if loopStart != nil {
                        MarkerNudgeRow(
                            marker: "A",
                            label: "시작점 조절",
                            color: BandLoopTheme.accent,
                            minus: { nudgeStart(-0.5) },
                            plus: { nudgeStart(0.5) }
                        )
                    }
                    if loopEnd != nil {
                        MarkerNudgeRow(
                            marker: "B",
                            label: "끝점 조절",
                            color: BandLoopTheme.coral,
                            minus: { nudgeEnd(-0.5) },
                            plus: { nudgeEnd(0.5) }
                        )
                    }

                    if validLoop {
                        Button(action: saveCurrentLoop) {
                            HStack(spacing: 9) {
                                Image(systemName: "bookmark.fill")
                                Text("이 구간 저장")
                                Spacer()
                                Text("\(video.savedLoops.count)/\(maximumSavedLoopCount)")
                                    .font(.caption2.weight(.black))
                                    .foregroundStyle(Color.black.opacity(0.58))
                            }
                            .font(.caption.weight(.black))
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .foregroundStyle(Color.black)
                            .background(BandLoopTheme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        loopStart = nil
                        loopEnd = nil
                        loopEnabled = false
                    } label: {
                        Label("구간 설정 초기화", systemImage: "arrow.counterclockwise")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .foregroundStyle(BandLoopTheme.secondaryText)
                            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            if !video.savedLoops.isEmpty {
                savedLoopsSection
            }
        }
        .padding(16)
        .cardStyle(cornerRadius: 20)
    }

    private var savedLoopsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .overlay(Color.white.opacity(0.09))

            HStack(alignment: .firstTextBaseline) {
                Text("저장한 구간")
                    .font(.subheadline.bold())
                Spacer()
                Text("길게 눌러 이름 변경·삭제")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(BandLoopTheme.secondaryText)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 9) {
                    ForEach(video.savedLoops) { savedLoop in
                        SavedLoopButton(
                            loop: savedLoop,
                            isActive: isActive(savedLoop),
                            onOpen: { openSavedLoop(savedLoop) },
                            onRename: { beginRenaming(savedLoop) },
                            onDelete: { loopPendingDeletion = savedLoop }
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("재생 속도")
                    .font(.headline.bold())
                Spacer()
                Text("\(playbackRate, specifier: "%g")×")
                    .font(.system(.subheadline, design: .monospaced, weight: .black))
                    .foregroundStyle(BandLoopTheme.accent)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(rates, id: \.self) { rate in
                        Button {
                            playbackRate = rate
                        } label: {
                            Text("\(rate, specifier: "%g")×")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 13)
                                .frame(height: 36)
                                .foregroundStyle(playbackRate == rate ? Color.black : BandLoopTheme.primaryText)
                                .background(playbackRate == rate ? BandLoopTheme.accent : Color.white.opacity(0.08), in: Capsule())
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .cardStyle(cornerRadius: 20)
    }

    private var validLoop: Bool {
        guard let loopStart, let loopEnd else { return false }
        return loopEnd - loopStart >= 0.5
    }

    private var renameAlertIsPresented: Binding<Bool> {
        Binding(
            get: { loopPendingRename != nil },
            set: { isPresented in
                if !isPresented { loopPendingRename = nil }
            }
        )
    }

    private var deletionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { loopPendingDeletion != nil },
            set: { isPresented in
                if !isPresented { loopPendingDeletion = nil }
            }
        )
    }

    private func applyPlayerSettings() {
        player.setPlaybackRate(playbackRate)
        player.setLoop(start: loopStart, end: loopEnd, enabled: loopEnabled && validLoop)
    }

    private func captureStart() {
        let time = player.currentTime
        loopStart = time
        if let loopEnd, loopEnd - time < 0.5 {
            self.loopEnd = nil
            loopEnabled = false
        }
        showNotice("A 시작점  \(TimeFormatter.positional(time))")
    }

    private func captureEnd() {
        guard let loopStart else {
            showNotice("먼저 A 시작점을 찍어 주세요")
            return
        }
        let time = player.currentTime
        guard time - loopStart >= 0.5 else {
            showNotice("B는 A보다 0.5초 이상 뒤여야 해요")
            return
        }
        loopEnd = time
        loopEnabled = true
        player.seek(to: loopStart)
        player.play()
        showNotice("반복 시작  \(TimeFormatter.positional(loopStart)) – \(TimeFormatter.positional(time))")
    }

    private func nudgeStart(_ amount: Double) {
        guard let loopStart else { return }
        let upper = max(0, (loopEnd ?? player.duration) - 0.5)
        self.loopStart = min(max(0, loopStart + amount), upper)
    }

    private func nudgeEnd(_ amount: Double) {
        guard let loopEnd else { return }
        let lower = (loopStart ?? 0) + 0.5
        self.loopEnd = min(max(lower, loopEnd + amount), max(lower, player.duration))
    }

    private func saveCurrentLoop() {
        guard let loopStart, let loopEnd, validLoop else { return }

        if video.savedLoops.contains(where: {
            abs($0.start - loopStart) < 0.05 && abs($0.end - loopEnd) < 0.05
        }) {
            showNotice("이미 저장한 구간이에요")
            return
        }

        guard video.savedLoops.count < maximumSavedLoopCount else {
            showNotice("영상당 최대 \(maximumSavedLoopCount)개까지 저장할 수 있어요", long: true)
            return
        }

        let savedLoop = SavedLoop(
            name: nextSavedLoopName(),
            start: loopStart,
            end: loopEnd
        )
        video.savedLoops.append(savedLoop)
        onPersist()
        showNotice("\(savedLoop.name) 저장됨")
    }

    private func openSavedLoop(_ savedLoop: SavedLoop) {
        loopStart = savedLoop.start
        loopEnd = savedLoop.end
        loopEnabled = true
        video.loopStart = savedLoop.start
        video.loopEnd = savedLoop.end
        player.setLoop(start: savedLoop.start, end: savedLoop.end, enabled: true)
        player.seek(to: savedLoop.start)
        player.play()
        onPersist()
        showNotice("\(savedLoop.name) 반복 시작")
    }

    private func beginRenaming(_ savedLoop: SavedLoop) {
        loopRenameText = savedLoop.name
        loopPendingRename = savedLoop
    }

    private func renameSavedLoop() {
        guard let target = loopPendingRename,
              let index = video.savedLoops.firstIndex(where: { $0.id == target.id }) else {
            loopPendingRename = nil
            return
        }

        let trimmed = loopRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            loopPendingRename = nil
            return
        }

        video.savedLoops[index].name = String(trimmed.prefix(24))
        let newName = video.savedLoops[index].name
        loopPendingRename = nil
        onPersist()
        showNotice("\(newName)(으)로 변경됨")
    }

    private func deleteSavedLoop() {
        guard let target = loopPendingDeletion else { return }
        let wasActive = isActive(target)
        video.savedLoops.removeAll(where: { $0.id == target.id })
        loopPendingDeletion = nil

        if wasActive {
            loopStart = nil
            loopEnd = nil
            loopEnabled = false
            player.setLoop(start: nil, end: nil, enabled: false)
        }

        onPersist()
        showNotice("저장한 구간 삭제됨")
    }

    private func isActive(_ savedLoop: SavedLoop) -> Bool {
        guard let loopStart, let loopEnd else { return false }
        return abs(savedLoop.start - loopStart) < 0.05 && abs(savedLoop.end - loopEnd) < 0.05
    }

    private func nextSavedLoopName() -> String {
        let existingNames = Set(video.savedLoops.map(\.name))
        var index = 1
        while existingNames.contains("구간 \(index)") {
            index += 1
        }
        return "구간 \(index)"
    }

    private func syncLoop() {
        if !validLoop { loopEnabled = false }
        player.setLoop(start: loopStart, end: loopEnd, enabled: loopEnabled && validLoop)
        video.loopStart = loopStart
        video.loopEnd = loopEnd
        onPersist()
    }

    private func showNotice(_ message: String, long: Bool = false) {
        withAnimation(.spring(response: 0.3)) { notice = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + (long ? 3.5 : 1.8)) {
            guard notice == message else { return }
            withAnimation { notice = nil }
        }
    }
}

private struct SavedLoopButton: View {
    let loop: SavedLoop
    let isActive: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(loop.name)
                        .font(.caption.weight(.black))
                        .lineLimit(1)

                    if isActive {
                        Image(systemName: "repeat.circle.fill")
                            .font(.caption.weight(.bold))
                    }
                }

                Text("\(TimeFormatter.positional(loop.start)) – \(TimeFormatter.positional(loop.end))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isActive ? Color.black.opacity(0.64) : BandLoopTheme.secondaryText)
            }
            .frame(minWidth: 132, alignment: .leading)
            .padding(.horizontal, 13)
            .frame(height: 58)
            .foregroundStyle(isActive ? Color.black : BandLoopTheme.primaryText)
            .background(
                isActive ? BandLoopTheme.accent : Color.white.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                if !isActive {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("이름 변경", systemImage: "pencil", action: onRename)
            Button("삭제", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityLabel("\(loop.name), \(TimeFormatter.positional(loop.start))부터 \(TimeFormatter.positional(loop.end))까지")
        .accessibilityHint("두 번 탭하면 반복 재생, 길게 누르면 이름 변경 및 삭제")
    }
}

private struct MarkerButton: View {
    let marker: String
    let caption: String
    let time: Double?
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(marker)
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(Color.black)
                        .background(color, in: Circle())
                    Spacer()
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(color)
                }
                Text(time.map(TimeFormatter.positional) ?? "--:--")
                    .font(.system(size: 24, weight: .black, design: .monospaced))
                    .foregroundStyle(BandLoopTheme.primaryText)
                Text(caption)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BandLoopTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct MarkerNudgeRow: View {
    let marker: String
    let label: String
    let color: Color
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: 8) {
                Text(marker)
                    .font(.caption.weight(.black))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Color.black)
                    .background(color, in: Circle())

                Text(label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BandLoopTheme.primaryText)
            }
            .frame(width: 92, alignment: .leading)

            NudgeButton(title: "− 0.5초", action: minus)
            NudgeButton(title: "+ 0.5초", action: plus)
        }
        .padding(5)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct NudgeButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .black, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(BandLoopTheme.primaryText)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TransportButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .frame(width: 46, height: 46)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .accessibilityLabel(label)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .black, design: .rounded))
            .frame(height: 54)
            .foregroundStyle(Color.black)
            .background(BandLoopTheme.accent.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(BandLoopTheme.primaryText)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
