import Combine
import Foundation
import SwiftUI
import UIKit

struct IEMTrack: Identifiable, Codable, Equatable {
    let id: String
    let youtubeVideoID: String
    let title: String
    let artist: String
    let bpm: Int?
    let updatedAt: String?

    var thumbnailURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(youtubeVideoID)/mqdefault.jpg")
    }
}

private struct IEMCatalogResponse: Decodable {
    let tracks: [IEMTrack]
}

enum IEMLibraryError: LocalizedError {
    case missingEndpoint
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            return "인이어 목록 주소가 설정되지 않았어요."
        case .invalidResponse:
            return "인이어 목록을 읽지 못했어요."
        case let .server(message):
            return message
        }
    }
}

struct IEMLibraryService {
    private let session: URLSession
    private let endpoint: URL?

    init(session: URLSession = .shared, endpoint: URL? = nil) {
        self.session = session
        if let endpoint {
            self.endpoint = endpoint
        } else if let value = Bundle.main.object(forInfoDictionaryKey: "IEMCatalogAPIURL") as? String,
                  let url = URL(string: value),
                  url.scheme == "https" {
            self.endpoint = url
        } else {
            self.endpoint = nil
        }
    }

    func fetchTracks() async throws -> [IEMTrack] {
        guard let endpoint else { throw IEMLibraryError.missingEndpoint }
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadRevalidatingCacheData
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IEMLibraryError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let payload = try? JSONDecoder().decode([String: String].self, from: data),
               let message = payload["error"] {
                throw IEMLibraryError.server(message)
            }
            throw IEMLibraryError.invalidResponse
        }
        return try JSONDecoder().decode(IEMCatalogResponse.self, from: data).tracks
    }
}

@MainActor
final class IEMLibraryStore: ObservableObject {
    @Published private(set) var tracks: [IEMTrack] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let service: IEMLibraryService
    private var hasLoaded = false

    init(service: IEMLibraryService = IEMLibraryService()) {
        self.service = service
    }

    func load(force: Bool = false) async {
        guard force || !hasLoaded else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            tracks = try await service.fetchTracks()
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct IEMSetlist: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var trackIDs: [String]
    let createdAt: Date

    init(id: UUID = UUID(), name: String, trackIDs: [String], createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.createdAt = createdAt
    }
}

@MainActor
final class IEMSetlistStore: ObservableObject {
    @Published private(set) var setlists: [IEMSetlist] = []

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "bandloop.iem-setlists.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    func create(name: String, trackIDs: [String]) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trackIDs.isEmpty else { return }
        setlists.insert(IEMSetlist(name: trimmedName, trackIDs: trackIDs), at: 0)
        save()
    }

    func delete(id: UUID) {
        setlists.removeAll(where: { $0.id == id })
        save()
    }

    func moveTracks(in id: UUID, from offsets: IndexSet, to destination: Int) {
        guard let index = setlists.firstIndex(where: { $0.id == id }) else { return }
        setlists[index].trackIDs.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    func removeTracks(in id: UUID, at offsets: IndexSet) {
        guard let index = setlists.firstIndex(where: { $0.id == id }) else { return }
        setlists[index].trackIDs.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([IEMSetlist].self, from: data) else { return }
        setlists = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(setlists) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

struct IEMLibraryScreen: View {
    private enum Section: String, CaseIterable, Identifiable {
        case tracks = "전체 음원"
        case setlists = "셋리스트"

        var id: Self { self }
    }

    @ObservedObject var library: IEMLibraryStore
    @ObservedObject var setlists: IEMSetlistStore
    @ObservedObject var player: YouTubePlayerController
    let onBack: () -> Void
    let onOpen: (IEMTrack) -> Void

    @State private var section: Section = .tracks
    @State private var isSelecting = false
    @State private var selectedTrackIDs: Set<String> = []
    @State private var isNamingSetlist = false
    @State private var setlistName = ""

    var body: some View {
        NavigationStack {
            ZStack {
                BandLoopTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    Picker("인이어 목록", selection: $section) {
                        ForEach(Section.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)

                    if section == .tracks {
                        tracksContent
                    } else {
                        setlistsContent
                    }
                }
            }
            .navigationTitle("인이어 음원")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BandLoopTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(BandLoopTheme.accent)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .accessibilityLabel("뒤로")
                }

                if section == .tracks, !library.tracks.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(isSelecting ? "취소" : "셋리스트 만들기") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isSelecting.toggle()
                                if !isSelecting { selectedTrackIDs.removeAll() }
                            }
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(BandLoopTheme.accent)
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                IEMSetlistDetailScreen(
                    setlistID: id,
                    library: library,
                    setlists: setlists,
                    player: player,
                    onOpen: onOpen
                )
            }
        }
        .tint(BandLoopTheme.accent)
        .task { await library.load() }
        .alert("셋리스트 이름", isPresented: $isNamingSetlist) {
            TextField("예: 공연 1부", text: $setlistName)
            Button("취소", role: .cancel) {}
            Button("저장", action: saveSetlist)
                .disabled(setlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("선택한 \(selectedTrackIDs.count)곡을 저장합니다.")
        }
    }

    private var tracksContent: some View {
        ScrollView {
            Group {
                if library.isLoading && library.tracks.isEmpty {
                    ProgressView("인이어 음원 불러오는 중…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else if let error = library.errorMessage, library.tracks.isEmpty {
                    messageCard(
                        icon: "wifi.exclamationmark",
                        title: "목록을 불러오지 못했어요",
                        detail: error,
                        buttonTitle: "다시 시도"
                    ) {
                        Task { await library.load(force: true) }
                    }
                } else if library.tracks.isEmpty {
                    messageCard(
                        icon: "headphones",
                        title: "인이어 음원을 준비 중이에요",
                        detail: "새 연습곡이 추가되면 여기에 바로 보여요.",
                        buttonTitle: nil,
                        action: nil
                    )
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(library.tracks) { track in
                            IEMTrackRow(
                                track: track,
                                isSelected: isSelecting ? selectedTrackIDs.contains(track.id) : nil
                            ) {
                                if isSelecting {
                                    toggleSelection(track.id)
                                } else {
                                    onOpen(track)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, isSelecting ? 100 : 36)
        }
        .refreshable { await library.load(force: true) }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                Button {
                    setlistName = ""
                    isNamingSetlist = true
                } label: {
                    Text(selectedTrackIDs.isEmpty ? "음원을 선택해 주세요" : "\(selectedTrackIDs.count)곡으로 셋리스트 만들기")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(BandLoopTheme.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(selectedTrackIDs.isEmpty)
                .opacity(selectedTrackIDs.isEmpty ? 0.45 : 1)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var setlistsContent: some View {
        ScrollView {
            VStack(spacing: 12) {
                if setlists.setlists.isEmpty {
                    messageCard(
                        icon: "music.note.list",
                        title: "아직 셋리스트가 없어요",
                        detail: "전체 음원에서 곡을 고르고 연습 순서를 만들어 보세요.",
                        buttonTitle: "셋리스트 만들기"
                    ) {
                        section = .tracks
                        isSelecting = true
                    }
                } else {
                    ForEach(setlists.setlists) { setlist in
                        NavigationLink(value: setlist.id) {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(BandLoopTheme.accent.opacity(0.14))
                                        .frame(width: 56, height: 56)
                                    Image(systemName: "music.note.list")
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundStyle(BandLoopTheme.accent)
                                }

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(setlist.name)
                                        .font(.headline)
                                        .foregroundStyle(BandLoopTheme.primaryText)
                                    Text("\(setlist.trackIDs.count)곡")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(BandLoopTheme.secondaryText)
                                }

                                Spacer()

                                Menu {
                                    Button("셋리스트 삭제", systemImage: "trash", role: .destructive) {
                                        setlists.delete(id: setlist.id)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .frame(width: 36, height: 44)
                                        .foregroundStyle(BandLoopTheme.secondaryText)
                                }

                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(BandLoopTheme.secondaryText)
                            }
                            .padding(12)
                            .contentShape(Rectangle())
                            .cardStyle(cornerRadius: 18)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 36)
        }
    }

    private func messageCard(
        icon: String,
        title: String,
        detail: String,
        buttonTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(BandLoopTheme.accent)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(BandLoopTheme.secondaryText)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 18)
                    .frame(height: 42)
                    .background(BandLoopTheme.accent, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .padding(.horizontal, 24)
        .cardStyle()
        .padding(.top, 10)
    }

    private func toggleSelection(_ id: String) {
        if selectedTrackIDs.contains(id) {
            selectedTrackIDs.remove(id)
        } else {
            selectedTrackIDs.insert(id)
        }
    }

    private func saveSetlist() {
        let orderedIDs = library.tracks.map(\.id).filter(selectedTrackIDs.contains)
        setlists.create(name: setlistName, trackIDs: orderedIDs)
        selectedTrackIDs.removeAll()
        isSelecting = false
        section = .setlists
    }
}

private struct IEMTrackRow: View {
    let track: IEMTrack
    let isSelected: Bool?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 13) {
                AsyncImage(url: track.thumbnailURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.white.opacity(0.06)
                            Image(systemName: "headphones")
                                .foregroundStyle(BandLoopTheme.secondaryText)
                        }
                    }
                }
                .frame(width: 108, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(track.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(BandLoopTheme.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 7) {
                        Text(track.artist)
                        if let bpm = track.bpm {
                            Text("·")
                            Text("\(bpm) BPM")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BandLoopTheme.secondaryText)
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                if let isSelected {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(isSelected ? BandLoopTheme.accent : BandLoopTheme.secondaryText)
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(BandLoopTheme.accent)
                }
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle(cornerRadius: 18)
    }
}

private struct IEMSetlistDetailScreen: View {
    let setlistID: UUID
    @ObservedObject var library: IEMLibraryStore
    @ObservedObject var setlists: IEMSetlistStore
    @ObservedObject var player: YouTubePlayerController
    let onOpen: (IEMTrack) -> Void

    @State private var isPerformancePresented = false

    private var setlist: IEMSetlist? {
        setlists.setlists.first(where: { $0.id == setlistID })
    }

    private var playableTracks: [IEMTrack] {
        guard let setlist else { return [] }
        return setlist.trackIDs.compactMap { trackID in
            library.tracks.first(where: { $0.id == trackID })
        }
    }

    var body: some View {
        ZStack {
            BandLoopTheme.background.ignoresSafeArea()

            if let setlist {
                List {
                    ForEach(Array(setlist.trackIDs.enumerated()), id: \.offset) { _, trackID in
                        if let track = library.tracks.first(where: { $0.id == trackID }) {
                            IEMTrackRow(track: track, isSelected: nil) {
                                onOpen(track)
                            }
                            .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        } else {
                            Label("목록에서 제거된 음원", systemImage: "exclamationmark.circle")
                                .foregroundStyle(BandLoopTheme.secondaryText)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .onMove { offsets, destination in
                        setlists.moveTracks(in: setlistID, from: offsets, to: destination)
                    }
                    .onDelete { offsets in
                        setlists.removeTracks(in: setlistID, at: offsets)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 76)
                .overlay {
                    if setlist.trackIDs.isEmpty {
                        ContentUnavailableView("빈 셋리스트", systemImage: "music.note.list")
                            .foregroundStyle(BandLoopTheme.secondaryText)
                    }
                }
            }
        }
        .navigationTitle(setlist?.name ?? "셋리스트")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !playableTracks.isEmpty {
                Button {
                    isPerformancePresented = true
                } label: {
                    Label("공연 시작", systemImage: "play.fill")
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(BandLoopTheme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        .toolbarBackground(BandLoopTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .font(.subheadline.weight(.bold))
            }
        }
        .fullScreenCover(isPresented: $isPerformancePresented) {
            IEMPerformanceScreen(
                setlistName: setlist?.name ?? "셋리스트",
                tracks: playableTracks,
                player: player
            )
        }
    }
}

private struct IEMPerformanceScreen: View {
    private enum Phase {
        case waiting
        case playing
        case paused
        case finished
    }

    @Environment(\.dismiss) private var dismiss

    let setlistName: String
    let tracks: [IEMTrack]
    @ObservedObject var player: YouTubePlayerController

    @State private var currentIndex = 0
    @State private var phase: Phase = .waiting
    @State private var didPrepare = false
    @State private var hasStarted = false
    @State private var previousIdleTimerDisabled = false

    private var currentTrack: IEMTrack? {
        tracks.indices.contains(currentIndex) ? tracks[currentIndex] : nil
    }

    private var nextTrack: IEMTrack? {
        let nextIndex = currentIndex + 1
        return tracks.indices.contains(nextIndex) ? tracks[nextIndex] : nil
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width > proxy.size.height

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    performanceHeader

                    if isWide {
                        HStack(spacing: 12) {
                            playerArea
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            stagePanel(compact: proxy.size.height < 600)
                                .frame(width: min(max(proxy.size.width * 0.34, 330), 480))
                        }
                        .padding([.horizontal, .bottom], 12)
                    } else {
                        VStack(spacing: 0) {
                            playerArea
                                .aspectRatio(16 / 9, contentMode: .fit)

                            stagePanel(compact: false)
                                .frame(maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .interactiveDismissDisabled()
        .onAppear(perform: preparePerformance)
        .onDisappear(perform: finishPerformance)
        .onChange(of: player.playbackEndedCount) { oldValue, newValue in
            guard didPrepare, newValue > oldValue, phase == .playing else { return }
            moveForwardAfterSongEnds()
        }
    }

    private var performanceHeader: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .black))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("공연 모드 종료")

            VStack(alignment: .leading, spacing: 2) {
                Text(setlistName)
                    .font(.headline.weight(.black))
                    .lineLimit(1)
                Text("공연 모드")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BandLoopTheme.secondaryText)
            }

            Spacer()

            Text(tracks.isEmpty ? "0 / 0" : "\(currentIndex + 1) / \(tracks.count)")
                .font(.system(.subheadline, design: .monospaced, weight: .black))
                .foregroundStyle(BandLoopTheme.accent)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
    }

    private var playerArea: some View {
        ZStack {
            Color.black

            YouTubePlayerView(controller: player)
                .aspectRatio(16 / 9, contentMode: .fit)

            if let message = player.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(BandLoopTheme.coral)
                    Text(message)
                        .font(.subheadline.weight(.bold))
                        .multilineTextAlignment(.center)
                }
                .padding(22)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(20)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stagePanel(compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                    currentSongInfo(compact: compact)
                    nextSongInfo(compact: compact)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)

            if player.duration > 0, phase != .waiting, phase != .finished {
                ProgressView(value: min(player.currentTime, player.duration), total: player.duration)
                    .tint(BandLoopTheme.accent)
            }

            stageControls(compact: compact)
        }
        .padding(compact ? 14 : 18)
        .background(BandLoopTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func currentSongInfo(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption.weight(.black))
                    .foregroundStyle(statusColor)
            }

            Text(currentTrack?.title ?? "재생할 곡이 없어요")
                .font(.system(size: compact ? 24 : 32, weight: .black, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.72)

            HStack(spacing: 8) {
                Text(currentTrack?.artist ?? "")
                if let bpm = currentTrack?.bpm {
                    Text("·")
                    Text("\(bpm) BPM")
                }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(BandLoopTheme.secondaryText)
            .lineLimit(1)
        }
    }

    private func nextSongInfo(compact: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("다음 곡")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(BandLoopTheme.secondaryText)

                if let nextTrack {
                    Text(nextTrack.title)
                        .font((compact ? Font.subheadline : Font.body).weight(.bold))
                        .lineLimit(1)
                    Text(nextTrack.artist)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BandLoopTheme.secondaryText)
                        .lineLimit(1)
                } else {
                    Text("마지막 곡")
                        .font(.subheadline.weight(.bold))
                }
            }

            Spacer(minLength: 0)

            Image(systemName: nextTrack == nil ? "flag.checkered" : "chevron.right")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(nextTrack == nil ? BandLoopTheme.accent : BandLoopTheme.secondaryText)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: compact ? 58 : 70)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func stageControls(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 11) {
            Button(action: primaryAction) {
                HStack(spacing: 11) {
                    if !player.isReady, phase != .finished {
                        ProgressView()
                            .tint(Color.black)
                    } else {
                        Image(systemName: primaryButtonIcon)
                    }
                    Text(primaryButtonTitle)
                }
                .font(.system(size: compact ? 16 : 18, weight: .black, design: .rounded))
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 54 : 66)
                .background(BandLoopTheme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(PerformanceButtonStyle())
            .disabled((!player.isReady && phase != .finished) || tracks.isEmpty)

            HStack(spacing: 10) {
                stageNavigationButton(
                    title: "이전",
                    icon: "backward.end.fill",
                    isEnabled: currentIndex > 0,
                    action: { selectTrack(at: currentIndex - 1) }
                )
                stageNavigationButton(
                    title: "다시 재생",
                    icon: "arrow.counterclockwise",
                    isEnabled: currentTrack != nil,
                    action: restartCurrentTrack
                )
                stageNavigationButton(
                    title: "다음",
                    icon: "forward.end.fill",
                    isEnabled: currentIndex + 1 < tracks.count,
                    action: { selectTrack(at: currentIndex + 1) }
                )
            }
        }
    }

    private func stageNavigationButton(
        title: String,
        icon: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.black))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.32)
    }

    private var statusText: String {
        if player.errorMessage != nil { return "재생 오류" }
        switch phase {
        case .waiting:
            return hasStarted ? "다음 곡 준비됨" : "첫 곡 준비됨"
        case .playing:
            return "재생 중"
        case .paused:
            return "일시정지"
        case .finished:
            return "공연 완료"
        }
    }

    private var statusColor: Color {
        if player.errorMessage != nil { return BandLoopTheme.coral }
        return phase == .paused ? BandLoopTheme.secondaryText : BandLoopTheme.accent
    }

    private var primaryButtonTitle: String {
        if player.errorMessage != nil { return "다시 시도" }
        if !player.isReady, phase != .finished { return "음원 준비 중" }
        switch phase {
        case .waiting:
            return hasStarted ? "재생" : "공연 시작"
        case .playing:
            return "일시정지"
        case .paused:
            return "계속 재생"
        case .finished:
            return "처음부터 재생"
        }
    }

    private var primaryButtonIcon: String {
        if player.errorMessage != nil { return "arrow.clockwise" }
        switch phase {
        case .playing:
            return "pause.fill"
        case .finished:
            return "arrow.counterclockwise"
        case .waiting, .paused:
            return "play.fill"
        }
    }

    private func preparePerformance() {
        guard !didPrepare, !tracks.isEmpty else { return }
        didPrepare = true
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        cueCurrentTrack()
    }

    private func finishPerformance() {
        player.pause()
        player.setLoop(start: nil, end: nil, enabled: false)
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
    }

    private func cueCurrentTrack() {
        guard let currentTrack else { return }
        player.clearError()
        player.setLoop(start: nil, end: nil, enabled: false)
        player.setPlaybackRate(1)
        player.load(videoID: currentTrack.youtubeVideoID, autoplay: false)
    }

    private func primaryAction() {
        guard let currentTrack else { return }

        if player.errorMessage != nil {
            player.clearError()
            player.load(videoID: currentTrack.youtubeVideoID, autoplay: true)
            phase = .playing
            hasStarted = true
            return
        }

        switch phase {
        case .waiting:
            player.play()
            phase = .playing
            hasStarted = true
        case .playing:
            player.pause()
            phase = .paused
        case .paused:
            player.play()
            phase = .playing
        case .finished:
            currentIndex = 0
            hasStarted = true
            player.load(videoID: tracks[0].youtubeVideoID, autoplay: true)
            phase = .playing
        }
    }

    private func moveForwardAfterSongEnds() {
        let nextIndex = currentIndex + 1
        guard tracks.indices.contains(nextIndex) else {
            phase = .finished
            return
        }

        currentIndex = nextIndex
        phase = .waiting
        cueCurrentTrack()
    }

    private func selectTrack(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        currentIndex = index
        phase = .waiting
        cueCurrentTrack()
    }

    private func restartCurrentTrack() {
        guard let currentTrack else { return }
        player.clearError()
        player.setLoop(start: nil, end: nil, enabled: false)
        player.setPlaybackRate(1)
        player.load(videoID: currentTrack.youtubeVideoID, autoplay: true)
        phase = .playing
        hasStarted = true
    }
}

private struct PerformanceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
