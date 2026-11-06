import SwiftUI

// MARK: - Command palette (⌘K)

@MainActor @Observable final class PaletteModel {
    var query = ""
    private(set) var tracks: [SCTrack] = []
    private(set) var playlists: [SCPlaylist] = []
    private(set) var users: [SCUser] = []
    private(set) var loading = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func run(_ api: SoundCloudAPI) {
        task?.cancel()
        let q = query.trimmed
        guard q.count >= 2 else { tracks = []; playlists = []; users = []; loading = false; return }
        loading = true
        task = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let r = await api.quickSearch(q)
            guard !Task.isCancelled else { return }
            tracks = r.tracks; playlists = r.playlists; users = r.users; loading = false
        }
    }

    func clear() { query = ""; tracks = []; playlists = []; users = []; task?.cancel() }
}

struct CommandPalette: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model = PaletteModel()
    @FocusState private var focused: Bool

    var jumps: [(String, String, SidebarItem)] {
        let q = model.query.trimmed.lowercased()
        var items: [(String, String, SidebarItem)] = [
            ("Home", "house", .home), ("Stream", "dot.radiowaves.left.and.right", .feed),
            ("Likes", "heart", .likes), ("Playlists", "music.note.list", .playlists),
            ("Downloads", "arrow.down.circle", .downloads), ("Following", "person.2", .following),
            ("History", "clock.arrow.circlepath", .history),
        ]
        items += app.library.myPlaylists.map { ($0.displayTitle, "music.note.list", SidebarItem.playlist($0.id)) }
        guard !q.isEmpty else { return q.isEmpty && model.query.isEmpty ? Array(items.prefix(5)) : items }
        return items.filter { $0.0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tracks, people, playlists — or jump anywhere", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(primaryAction)
                    .onChange(of: model.query) { model.run(app.api) }
                if model.loading { ProgressView().controlSize(.small) }
                Text("esc").font(.caption).foregroundStyle(.tertiary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.query.trimmed.isEmpty && !app.router.recentSearches.isEmpty {
                        PaletteHeader("Recent")
                        ForEach(app.router.recentSearches, id: \.self) { q in
                            PaletteRow(icon: "clock.arrow.circlepath", title: q) { model.query = q; model.run(app.api) }
                        }
                    }
                    if !jumps.isEmpty {
                        PaletteHeader("Jump to")
                        ForEach(jumps, id: \.2) { j in
                            PaletteRow(icon: j.1, title: j.0) { app.router.section = j.2; close() }
                        }
                    }
                    if !model.tracks.isEmpty {
                        PaletteHeader("Tracks")
                        ForEach(model.tracks) { t in
                            PaletteRow(art: t.art(.small), title: t.displayTitle, subtitle: t.artist) {
                                app.player.play([t]); saveAndClose()
                            }
                        }
                    }
                    if !model.playlists.isEmpty {
                        PaletteHeader("Playlists")
                        ForEach(model.playlists) { p in
                            PaletteRow(art: p.art(.small), icon: "music.note.list", title: p.displayTitle,
                                       subtitle: p.user?.displayName) { app.router.go(.playlist(p)); saveAndClose() }
                        }
                    }
                    if !model.users.isEmpty {
                        PaletteHeader("People")
                        ForEach(model.users) { u in
                            PaletteRow(art: u.avatar(.small), icon: "person", title: u.displayName,
                                       subtitle: u.followersCount.map { "\(compactCount($0)) followers" }, circle: true) {
                                app.router.go(.user(u)); saveAndClose()
                            }
                        }
                    }
                    if model.query.trimmed.count >= 2 {
                        PaletteRow(icon: "magnifyingglass", title: "Search for “\(model.query.trimmed)”") {
                            app.router.search(model.query.trimmed); close()
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 620)
        .background(.regularMaterial)
        .onAppear { focused = true }
        .onExitCommand(perform: close)
    }

    private func primaryAction() {
        if let t = model.tracks.first { app.player.play([t]); saveAndClose() }
        else if let j = jumps.first { app.router.section = j.2; close() }
        else if model.query.trimmed.count >= 2 { app.router.search(model.query.trimmed); close() }
    }
    private func saveAndClose() { app.router.addRecentSearch(model.query); close() }
    private func close() { dismiss() }
}

private struct PaletteHeader: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
    }
}

private struct PaletteRow: View {
    var art: URL? = nil
    var icon: String? = nil
    let title: String
    var subtitle: String? = nil
    var circle = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let art {
                    Artwork(url: art, size: 30, circle: circle, placeholder: icon ?? "music.note")
                        .frame(width: 30, height: 30)
                } else if let icon {
                    Image(systemName: icon).frame(width: 30).foregroundStyle(.secondary)
                }
                Text(title).lineLimit(1)
                if let subtitle { Text(subtitle).foregroundStyle(.secondary).lineLimit(1).font(.callout) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hover ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Sleep timer menu

struct SleepTimerMenu: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let p = app.player
        Menu {
            if p.sleepActive {
                Button("Turn Off Sleep Timer") { p.cancelSleepTimer() }
                Divider()
            }
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { m in
                Button("\(m) minutes") { p.setSleepTimer(minutes: m) }
            }
            Button("End of this track") { p.setSleepEndOfTrack() }
        } label: {
            Image(systemName: p.sleepActive ? "moon.fill" : "moon")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(p.sleepActive ? "Sleep timer on" : "Sleep timer")
    }
}

// MARK: - Full Now Playing

struct NowPlayingFullView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [SCComment] = []
    @State private var loadingComments = false
    @State private var loadedFor: String?

    var body: some View {
        let t = app.player.current
        HStack(spacing: 0) {
            VStack(spacing: 18) {
                Artwork(url: t?.art(.big), radius: 10)
                    .frame(maxWidth: 360, maxHeight: 360)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                VStack(spacing: 4) {
                    Text(t?.displayTitle ?? "Not playing").font(.title2.weight(.bold)).lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let u = t?.user {
                        Button(u.displayName) { app.router.go(.user(u)); dismiss() }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                if let t {
                    HStack(spacing: 20) {
                        Label(compactCount(t.playbackCount), systemImage: "play.fill")
                        Label(compactCount(t.favoritingsCount), systemImage: "heart.fill")
                        Label(compactCount(t.repostsCount), systemImage: "arrow.2.squarepath")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Scrubber(height: 30).frame(maxWidth: 420)
                Transport()
                HStack(spacing: 18) {
                    if let t { LikeButton(track: t, size: 15); DownloadButton(track: t, size: 15) }
                    SleepTimerMenu()
                    IconButton("list.bullet", active: app.router.showQueue, size: 15, help: "Queue") {
                        app.router.showQueue.toggle()
                    }
                }
                Spacer()
            }
            .frame(width: 440)
            .padding(24)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text("Comments").font(.headline).padding(16)
                Divider()
                if loadingComments {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if comments.isEmpty {
                    ContentUnavailableView("No comments", systemImage: "bubble.left")
                        .frame(maxHeight: .infinity)
                } else {
                    List(comments) { c in CommentRow(comment: c) }
                        .listStyle(.plain)
                }
            }
            .frame(width: 340)
        }
        .frame(height: 620)
        .background(.background)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(12)
                .keyboardShortcut(.cancelAction)
        }
        .task(id: t?.id) { await loadComments(t) }
    }

    private func loadComments(_ t: SCTrack?) async {
        guard let t, loadedFor != t.id else { return }
        loadedFor = t.id
        loadingComments = true
        comments = (try? await app.api.comments(for: t)) ?? []
        loadingComments = false
    }
}

struct CommentRow: View {
    @Environment(AppModel.self) private var app
    let comment: SCComment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Artwork(url: comment.user?.avatar(.small), size: 28, circle: true, placeholder: "person.fill")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(comment.user?.displayName ?? "Someone").font(.caption.weight(.semibold)).lineLimit(1)
                    if let at = comment.at {
                        Text(at).font(.caption2.monospacedDigit()).foregroundStyle(.tint)
                            .onTapGesture { if let ms = comment.timestamp { app.player.seek(to: Double(ms) / 1000) } }
                    }
                }
                Text(comment.body ?? "").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
