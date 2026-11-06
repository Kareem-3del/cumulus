import SwiftUI

/// Native List of tracks: double-click / Return plays, right-click for every action, multi-select.
struct TrackList<Header: View>: View {
    @Environment(AppModel.self) private var app
    let tracks: [SCTrack]
    var loader: PagedLoader<SCTrack>? = nil
    var playlist: SCPlaylist? = nil
    var emptyText = "No tracks"
    @ViewBuilder var header: () -> Header
    @State private var selection = Set<String>()

    var body: some View {
        List(selection: $selection) {
            header()
                .listRowSeparator(.hidden)
                .selectionDisabled()
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t, number: i + 1)
                    .tag(t.id)
                    .onAppear {
                        if let loader, i >= tracks.count - 8, loader.hasMore {
                            Task { await loader.loadMore() }
                        }
                    }
            }
            if let loader {
                StatusFooter(loader: loader, emptyText: emptyText)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            } else if tracks.isEmpty {
                Text(emptyText).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                    .selectionDisabled()
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            TrackMenu(tracks: tracks.filter { ids.contains($0.id) }, playlist: playlist, loader: loader)
        } primaryAction: { ids in
            if let id = ids.first, let i = tracks.firstIndex(where: { $0.id == id }) {
                app.player.play(tracks, at: i, context: loader)
            }
        }
    }
}

extension TrackList where Header == EmptyView {
    init(tracks: [SCTrack], loader: PagedLoader<SCTrack>? = nil, playlist: SCPlaylist? = nil, emptyText: String = "No tracks") {
        self.init(tracks: tracks, loader: loader, playlist: playlist, emptyText: emptyText) { EmptyView() }
    }
}

struct TrackRow: View {
    @Environment(AppModel.self) private var app
    let track: SCTrack
    let number: Int
    @State private var hover = false

    var body: some View {
        let isCurrent = app.player.current?.id == track.id
        let liked = app.library.isLiked(track)
        HStack(spacing: 10) {
            ZStack {
                Artwork(url: track.art(.small), size: 36)
                if isCurrent || hover {
                    Rectangle().fill(.black.opacity(0.45))
                    Image(systemName: isCurrent && app.player.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if track.isPreview {
                Text("PREVIEW")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.secondary)
                    .help("Only a 30-second preview is available with this account")
            }
            if let plays = track.playbackCount, plays > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill").font(.system(size: 8))
                    Text(compactCount(plays))
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
            }
            LikeButton(track: track)
                .opacity(hover || liked ? 1 : 0)
            Text(formatTime(track.seconds))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// Every per-track action, shared by lists, the player bar and the queue.
struct TrackMenu: View {
    @Environment(AppModel.self) private var app
    let tracks: [SCTrack]
    var playlist: SCPlaylist? = nil
    var loader: PagedLoader<SCTrack>? = nil

    var body: some View {
        if let t = tracks.first {
            let single = tracks.count == 1
            if single {
                Button { app.player.play([t]) } label: { Label("Play", systemImage: "play") }
                Button { app.router.go(.track(t)) } label: { Label("Open Song Page", systemImage: "music.note.house") }
            }
            Button { app.player.playNext(tracks) } label: { Label("Play Next", systemImage: "text.insert") }
            Button { app.player.addToQueue(tracks) } label: { Label("Add to Queue", systemImage: "text.append") }
            Divider()
            if single {
                let liked = app.library.isLiked(t)
                Button { Task { await app.library.toggleLike(t) } } label: {
                    Label(liked ? "Unlike" : "Like", systemImage: liked ? "heart.slash" : "heart")
                }
                let reposted = app.library.isReposted(t)
                Button { Task { await app.library.toggleRepost(t) } } label: {
                    Label(reposted ? "Remove Repost" : "Repost", systemImage: "arrow.2.squarepath")
                }
            }
            if single, app.downloader.isDownloaded(t) {
                Button(role: .destructive) { app.downloader.deleteDownload(t) } label: { Label("Delete Download", systemImage: "arrow.down.circle.badge.xmark") }
            } else {
                Button { app.downloader.download(tracks) } label: {
                    Label(single ? "Download" : "Download \(tracks.count) Tracks", systemImage: "arrow.down.circle")
                }
            }
            Menu {
                Button("New Playlist…") { app.router.newPlaylist = PlaylistDraft(tracks: tracks) }
                if !app.library.myPlaylists.isEmpty { Divider() }
                ForEach(app.library.myPlaylists) { p in
                    Button(p.displayTitle) { Task { await app.library.add(tracks, to: p) } }
                }
            } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
            if let playlist, app.library.owns(playlist) {
                Button(role: .destructive) {
                    Task {
                        if await app.library.remove(tracks, from: playlist) {
                            loader?.remove(ids: Set(tracks.map(\.id)))
                        }
                    }
                } label: { Label("Remove from This Playlist", systemImage: "minus.circle") }
            }
            if single {
                Divider()
                Button { app.player.startStation(from: t) } label: { Label("Start Station", systemImage: "dot.radiowaves.left.and.right") }
                if let u = t.user {
                    Button { app.router.go(.user(u)) } label: { Label("Go to \(u.displayName)", systemImage: "person") }
                }
                Divider()
                Button { System.copy(t.permalinkUrl) } label: { Label("Copy Link", systemImage: "link") }
                Button { System.open(t.permalinkUrl) } label: { Label("Open on SoundCloud.com", systemImage: "safari") }
            }
        }
    }
}

/// A section backed by a paged loader (Stream, Likes, Your Tracks…).
struct LoaderTrackSection: View {
    @Environment(AppModel.self) private var app
    let title: String
    let loader: PagedLoader<SCTrack>
    var emptyText = "No tracks"

    var body: some View {
        TrackList(tracks: loader.items, loader: loader, emptyText: emptyText)
            .navigationTitle(title)
            .task { await loader.loadIfNeeded() }
            .toolbar {
                ToolbarItemGroup {
                    Button { app.player.play(loader.items, at: 0, context: loader) } label: {
                        Label("Play All", systemImage: "play.fill")
                    }
                    .disabled(loader.items.isEmpty)
                    Button { app.player.playShuffled(loader.items, context: loader) } label: {
                        Label("Shuffle All", systemImage: "shuffle")
                    }
                    .disabled(loader.items.isEmpty)
                    Button { app.downloader.download(loader.items) } label: {
                        Label("Download All Loaded", systemImage: "arrow.down.circle")
                    }
                    .disabled(loader.items.isEmpty)
                    Button { Task { await loader.reload() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
    }
}

struct HistorySection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TrackList(tracks: app.player.history, emptyText: "Tracks you play show up here")
            .navigationTitle("History")
            .toolbar {
                ToolbarItemGroup {
                    Button { app.player.play(app.player.history) } label: { Label("Play All", systemImage: "play.fill") }
                        .disabled(app.player.history.isEmpty)
                    Button { app.player.clearHistory() } label: { Label("Clear History", systemImage: "trash") }
                        .disabled(app.player.history.isEmpty)
                }
            }
    }
}
