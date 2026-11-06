import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.auth.isLoggedIn { MainView() } else { LoginView() }
        }
        .task(id: app.auth.isLoggedIn) { await app.bootstrap() }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var router = app.router
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            NavigationStack(path: $router.path) {
                SectionView(section: router.section ?? .feed)
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .playlist(let p): PlaylistDetailView(playlist: p).id(p.id)
                        case .user(let u): UserDetailView(user: u).id(u.id)
                        case .track(let t): TrackDetailView(track: t).id(t.id)
                        }
                    }
            }
        }
        .inspector(isPresented: $router.showQueue) {
            QueueView().inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { PlayerBar() }
        .overlay(alignment: .bottom) {
            ToastView()
                .padding(.bottom, 80)
                .animation(.spring(duration: 0.3), value: Toast.shared.message)
                .allowsHitTesting(false)
        }
        .onChange(of: router.section) { router.path = NavigationPath() }
        .sheet(isPresented: $router.showOpenLink) { OpenLinkSheet() }
        .sheet(item: $router.newPlaylist) { NewPlaylistSheet(draft: $0) }
        .sheet(isPresented: $router.showPalette) { CommandPalette() }
        .sheet(isPresented: $router.showNowPlaying) { NowPlayingFullView() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { router.showQueue.toggle() } label: { Label("Queue", systemImage: "list.bullet") }
                    .help("Show the play queue")
            }
        }
    }
}

struct SectionView: View {
    @Environment(AppModel.self) private var app
    let section: SidebarItem

    var body: some View {
        let lib = app.library
        switch section {
        case .home:
            HomeView()
        case .feed:
            LoaderTrackSection(title: "Stream", loader: lib.feed, emptyText: "Follow artists to fill your stream")
        case .search:
            SearchView()
        case .likes:
            LoaderTrackSection(title: "Likes", loader: lib.likes, emptyText: "Tracks you like show up here")
        case .myTracks:
            LoaderTrackSection(title: "Your Tracks", loader: lib.myTracks, emptyText: "You haven't uploaded tracks")
        case .playlists:
            PlaylistGrid(loader: lib.playlists, emptyText: "You don't have playlists yet")
                .navigationTitle("Playlists")
                .toolbar {
                    Button { app.router.newPlaylist = PlaylistDraft(tracks: []) } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                }
        case .likedPlaylists:
            PlaylistGrid(loader: lib.likedPlaylists, emptyText: "Playlists and albums you like show up here")
                .navigationTitle("Liked Playlists")
        case .following:
            UserGrid(loader: lib.followings, emptyText: "You aren't following anyone")
                .navigationTitle("Following")
        case .downloads:
            DownloadsView()
        case .history:
            HistorySection()
        case .playlist(let id):
            if let p = lib.myPlaylists.first(where: { $0.id == id }) {
                PlaylistDetailView(playlist: p).id(id)
            } else {
                ContentUnavailableView("Playlist not found", systemImage: "music.note.list")
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var router = app.router
        List(selection: $router.section) {
            Section("Discover") {
                Label("Home", systemImage: "house").tag(SidebarItem.home)
                Label("Stream", systemImage: "dot.radiowaves.left.and.right").tag(SidebarItem.feed)
                Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
            }
            Section("Library") {
                Label("Likes", systemImage: "heart").tag(SidebarItem.likes)
                Label("Playlists", systemImage: "music.note.list").tag(SidebarItem.playlists)
                Label("Liked Playlists", systemImage: "rectangle.stack").tag(SidebarItem.likedPlaylists)
                Label("Your Tracks", systemImage: "waveform").tag(SidebarItem.myTracks)
                Label("Following", systemImage: "person.2").tag(SidebarItem.following)
                Label("Downloads", systemImage: "arrow.down.circle").tag(SidebarItem.downloads)
                Label("History", systemImage: "clock.arrow.circlepath").tag(SidebarItem.history)
            }
            if !app.library.myPlaylists.isEmpty {
                Section("Your Playlists") {
                    ForEach(app.library.myPlaylists) { p in
                        Label(p.displayTitle, systemImage: p.isPrivate ? "lock" : "music.note.list")
                            .lineLimit(1)
                            .tag(SidebarItem.playlist(p.id))
                            .contextMenu { PlaylistMenu(playlist: p) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { AccountRow() }
    }
}

struct AccountRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            Artwork(url: app.library.me?.avatar(.small), size: 26, circle: true, placeholder: "person.fill")
            Text(app.library.me?.displayName ?? "SoundCloud").font(.callout).lineLimit(1)
            Spacer()
            Menu {
                if let me = app.library.me {
                    Button("View Profile") { app.router.go(.user(me)) }
                }
                Button("Settings…") { openSettings() }
                Divider()
                Button("Log Out") { app.logout() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Sheets

struct OpenLinkSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open SoundCloud Link").font(.headline)
            TextField("https://soundcloud.com/artist/track", text: $link)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
                .onSubmit(open)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open", action: open).keyboardShortcut(.defaultAction).disabled(link.trimmed.isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            if let s = NSPasteboard.general.string(forType: .string), s.contains("soundcloud.com") { link = s }
        }
    }

    private func open() {
        let l = link
        dismiss()
        Task { await app.openLink(l) }
    }
}

struct NewPlaylistSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let draft: PlaylistDraft
    @State private var title = ""
    @State private var isPrivate = false
    @State private var busy = false

    var body: some View {
        Form {
            TextField("Title", text: $title)
            Toggle("Private", isOn: $isPrivate)
            if !draft.tracks.isEmpty {
                Text("\(draft.tracks.count) track\(draft.tracks.count == 1 ? "" : "s") will be added")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    busy = true
                    Task {
                        await app.library.createPlaylist(title: title.trimmed, isPrivate: isPrivate, tracks: draft.tracks)
                        dismiss()
                    }
                }
                .disabled(title.trimmed.isEmpty || busy)
            }
        }
        .navigationTitle("New Playlist")
    }
}
