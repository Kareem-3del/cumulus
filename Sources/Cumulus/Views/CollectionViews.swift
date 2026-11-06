import SwiftUI

// MARK: - Playlists grid

struct PlaylistGrid: View {
    let loader: PagedLoader<SCPlaylist>
    var emptyText = "No playlists"

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18)], alignment: .leading, spacing: 22) {
                ForEach(Array(loader.items.enumerated()), id: \.element.id) { i, p in
                    PlaylistCard(playlist: p)
                        .onAppear {
                            if i >= loader.items.count - 6, loader.hasMore { Task { await loader.loadMore() } }
                        }
                }
            }
            .padding(20)
            StatusFooter(loader: loader, emptyText: emptyText)
        }
        .task { await loader.loadIfNeeded() }
    }
}

struct PlaylistCard: View {
    @Environment(AppModel.self) private var app
    let playlist: SCPlaylist
    @State private var hover = false

    var body: some View {
        Button { app.router.go(.playlist(playlist)) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(url: playlist.art(.medium), radius: 6, placeholder: "music.note.list")
                        .shadow(color: .black.opacity(hover ? 0.25 : 0.1), radius: hover ? 8 : 3, y: 2)
                    if hover {
                        Button { Task { await play(shuffled: false) } } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Brand.accent))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .transition(.opacity)
                    }
                }
                Text(playlist.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
                Text([playlist.user?.displayName, playlist.trackCount.map { "\($0) tracks" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .contextMenu { PlaylistMenu(playlist: playlist) }
    }

    private func play(shuffled: Bool) async {
        await PlaylistMenu.play(playlist, app: app, shuffled: shuffled)
    }
}

struct PlaylistMenu: View {
    @Environment(AppModel.self) private var app
    let playlist: SCPlaylist

    var body: some View {
        Button { Task { await Self.play(playlist, app: app, shuffled: false) } } label: { Label("Play", systemImage: "play") }
        Button { Task { await Self.play(playlist, app: app, shuffled: true) } } label: { Label("Shuffle", systemImage: "shuffle") }
        Button {
            Task { if let t = try? await app.library.allTracks(of: playlist) { app.player.addToQueue(t) } }
        } label: { Label("Add to Queue", systemImage: "text.append") }
        Divider()
        if !app.library.owns(playlist) {
            let liked = app.library.isLiked(playlist)
            Button { Task { await app.library.toggleLike(playlist) } } label: {
                Label(liked ? "Unlike" : "Like", systemImage: liked ? "heart.slash" : "heart")
            }
        }
        if let u = playlist.user {
            Button { app.router.go(.user(u)) } label: { Label("Go to \(u.displayName)", systemImage: "person") }
        }
        Divider()
        Button { System.copy(playlist.permalinkUrl) } label: { Label("Copy Link", systemImage: "link") }
        Button { System.open(playlist.permalinkUrl) } label: { Label("Open on SoundCloud.com", systemImage: "safari") }
    }

    static func play(_ p: SCPlaylist, app: AppModel, shuffled: Bool) async {
        do {
            let tracks = try await app.library.allTracks(of: p)
            shuffled ? app.player.playShuffled(tracks) : app.player.play(tracks)
        } catch {
            Toast.shared.show("Couldn't load playlist: \(error.localizedDescription)")
        }
    }
}

// MARK: - Playlist detail

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let playlist: SCPlaylist
    @State private var loader: PagedLoader<SCTrack>?
    @State private var full: SCPlaylist?
    @State private var confirmDelete = false

    var body: some View {
        let p = full ?? playlist
        Group {
            if let loader {
                TrackList(tracks: loader.items, loader: loader, playlist: p) { header(p, loader) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(p.displayTitle)
        .task(id: playlist.id) {
            if loader == nil {
                var q: [String: String] = [:]
                if let s = playlist.secretToken { q["secret_token"] = s }
                loader = app.api.trackLoader("/playlists/\(playlist.id)/tracks", q)
            }
            await loader?.loadIfNeeded()
            if full == nil { full = try? await app.api.get("/playlists/\(playlist.id)", ["show_tracks": "false"]) }
        }
        .confirmationDialog("Delete “\(p.displayTitle)”?", isPresented: $confirmDelete) {
            Button("Delete Playlist", role: .destructive) {
                Task {
                    if await app.library.deletePlaylist(p) {
                        if app.router.section == .playlist(p.id) { app.router.section = .playlists } else { dismiss() }
                    }
                }
            }
        } message: { Text("This deletes the playlist on SoundCloud. It can't be undone.") }
    }

    private func header(_ p: SCPlaylist, _ loader: PagedLoader<SCTrack>) -> some View {
        HStack(alignment: .bottom, spacing: 20) {
            Artwork(url: p.art(.big), size: 172, radius: 8, placeholder: "music.note.list")
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 8) {
                Text((p.isAlbum ? "Album" : "Playlist") + (p.isPrivate ? " · Private" : ""))
                    .font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                Text(p.displayTitle).font(.largeTitle.weight(.bold)).lineLimit(2)
                HStack(spacing: 6) {
                    if let u = p.user {
                        Button(u.displayName) { app.router.go(.user(u)) }.buttonStyle(.link)
                    }
                    Text("· \(p.trackCount ?? loader.items.count) tracks · \(formatDuration(p.duration))")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                HStack(spacing: 10) {
                    Button {
                        Task { await loader.loadAll(); app.player.play(loader.items, at: 0, context: loader) }
                    } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 64) }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Task { await loader.loadAll(); app.player.playShuffled(loader.items, context: loader) }
                    } label: { Label("Shuffle", systemImage: "shuffle") }
                    if app.library.owns(p) {
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    } else {
                        let liked = app.library.isLiked(p)
                        Button { Task { await app.library.toggleLike(p) } } label: {
                            Label(liked ? "Liked" : "Like", systemImage: liked ? "heart.fill" : "heart")
                        }
                    }
                    Menu { PlaylistMenu(playlist: p) } label: { Image(systemName: "ellipsis") }
                        .menuIndicator(.hidden).fixedSize()
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 4)
    }
}

// MARK: - Users

struct UserGrid: View {
    let loader: PagedLoader<SCUser>
    var emptyText = "Nobody here yet"

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 18)], spacing: 22) {
                ForEach(Array(loader.items.enumerated()), id: \.element.id) { i, u in
                    UserCard(user: u)
                        .onAppear { if i >= loader.items.count - 6, loader.hasMore { Task { await loader.loadMore() } } }
                }
            }
            .padding(20)
            StatusFooter(loader: loader, emptyText: emptyText)
        }
        .task { await loader.loadIfNeeded() }
    }
}

struct UserCard: View {
    @Environment(AppModel.self) private var app
    let user: SCUser

    var body: some View {
        Button { app.router.go(.user(user)) } label: {
            VStack(spacing: 6) {
                Artwork(url: user.avatar(.medium), circle: true, placeholder: "person.fill")
                    .padding(.horizontal, 8)
                Text(user.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                if let f = user.followersCount {
                    Text("\(compactCount(f)) followers").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            let following = app.library.isFollowing(user)
            Button(following ? "Unfollow" : "Follow") { Task { await app.library.toggleFollow(user) } }
            Button("Copy Link") { System.copy(user.permalinkUrl) }
            Button("Open on SoundCloud.com") { System.open(user.permalinkUrl) }
        }
    }
}

@MainActor @Observable final class UserPageModel {
    let tracks: PagedLoader<SCTrack>
    let playlists: PagedLoader<SCPlaylist>
    let likes: PagedLoader<SCTrack>
    var full: SCUser?

    init(api: SoundCloudAPI, user: SCUser) {
        tracks = api.trackLoader("/users/\(user.id)/tracks")
        playlists = api.loader("/users/\(user.id)/playlists", ["show_tracks": "false"])
        likes = api.trackLoader("/users/\(user.id)/likes/tracks")
    }
}

enum UserTab: String, CaseIterable, Identifiable {
    case tracks = "Tracks", playlists = "Playlists", likes = "Likes"
    var id: String { rawValue }
}

struct UserDetailView: View {
    @Environment(AppModel.self) private var app
    let user: SCUser
    @State private var model: UserPageModel?
    @State private var tab: UserTab = .tracks

    var body: some View {
        let u = model?.full ?? user
        VStack(spacing: 0) {
            header(u)
            Picker("", selection: $tab) {
                ForEach(UserTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.bottom, 10)
            Divider()
            if let m = model {
                switch tab {
                case .tracks:
                    TrackList(tracks: m.tracks.items, loader: m.tracks, emptyText: "No tracks")
                        .task { await m.tracks.loadIfNeeded() }
                case .playlists:
                    PlaylistGrid(loader: m.playlists)
                case .likes:
                    TrackList(tracks: m.likes.items, loader: m.likes, emptyText: "No likes, or they're private")
                        .task { await m.likes.loadIfNeeded() }
                }
            } else {
                Spacer()
            }
        }
        .navigationTitle(u.displayName)
        .task(id: user.id) {
            if model == nil { model = UserPageModel(api: app.api, user: user) }
            if model?.full == nil { model?.full = try? await app.api.get("/users/\(user.id)") }
        }
    }

    private func header(_ u: SCUser) -> some View {
        HStack(spacing: 20) {
            Artwork(url: u.avatar(.big), size: 112, circle: true, placeholder: "person.fill")
            VStack(alignment: .leading, spacing: 6) {
                Text(u.displayName).font(.largeTitle.weight(.bold)).lineLimit(1)
                if let loc = [u.fullName, u.city, u.country].compactMap({ $0?.nilIfEmpty }).joined(separator: " · ").nilIfEmpty {
                    Text(loc).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    stat(u.followersCount, "Followers")
                    stat(u.followingsCount, "Following")
                    stat(u.trackCount, "Tracks")
                }
                HStack(spacing: 10) {
                    if u.id != app.library.me?.id {
                        let following = app.library.isFollowing(u)
                        Button { Task { await app.library.toggleFollow(u) } } label: {
                            Label(following ? "Following" : "Follow", systemImage: following ? "checkmark" : "person.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(following ? .secondary : Brand.accent)
                    }
                    Button {
                        Task {
                            await model?.tracks.loadIfNeeded()
                            if let m = model { app.player.play(m.tracks.items, context: m.tracks) }
                        }
                    } label: { Label("Play", systemImage: "play.fill") }
                    Button { System.open(u.permalinkUrl) } label: { Label("Open", systemImage: "safari") }
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(20)
    }

    private func stat(_ n: Int?, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(compactCount(n)).fontWeight(.semibold)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

// MARK: - Search

enum SearchScope: String, CaseIterable, Identifiable {
    case tracks = "Tracks", playlists = "Playlists", people = "People"
    var id: String { rawValue }
}

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var scope: SearchScope = .tracks
    @State private var tracks: PagedLoader<SCTrack>?
    @State private var playlists: PagedLoader<SCPlaylist>?
    @State private var people: PagedLoader<SCUser>?

    var body: some View {
        @Bindable var router = app.router
        content
            .navigationTitle("Search")
            .searchable(text: $router.searchQuery, placement: .toolbar, prompt: "Tracks, playlists, people or a link")
            .searchScopes($scope) {
                ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .task(id: "\(router.searchQuery)|\(scope.rawValue)") { await run() }
    }

    @ViewBuilder private var content: some View {
        if app.router.searchQuery.trimmed.isEmpty {
            VStack(spacing: 16) {
                ContentUnavailableView("Search SoundCloud", systemImage: "magnifyingglass",
                                       description: Text("Find tracks, playlists and people, or paste a soundcloud.com link. Press ⌘K for quick search."))
                if !app.router.recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Recent").font(.headline)
                            Spacer()
                            Button("Clear") { app.router.clearRecentSearches() }.buttonStyle(.link).font(.caption)
                        }
                        FlowChips(items: app.router.recentSearches) { q in app.router.search(q) }
                    }
                    .frame(maxWidth: 420)
                }
            }
        } else {
            switch scope {
            case .tracks:
                if let tracks { TrackList(tracks: tracks.items, loader: tracks, emptyText: "No tracks found") }
            case .playlists:
                if let playlists { PlaylistGrid(loader: playlists, emptyText: "No playlists found") }
            case .people:
                if let people { UserGrid(loader: people, emptyText: "No people found") }
            }
        }
    }

    private func run() async {
        let q = app.router.searchQuery.trimmed
        guard !q.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        if q.lowercased().hasPrefix("http"), q.contains("soundcloud.com") {
            await app.openLink(q)
            return
        }
        switch scope {
        case .tracks:
            let l = app.api.trackLoader("/tracks", ["q": q])
            tracks = l
            await l.reload()
        case .playlists:
            let l: PagedLoader<SCPlaylist> = app.api.loader("/playlists", ["q": q, "show_tracks": "false"])
            playlists = l
            await l.reload()
        case .people:
            let l: PagedLoader<SCUser> = app.api.loader("/users", ["q": q])
            people = l
            await l.reload()
        }
    }
}
