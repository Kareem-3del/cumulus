import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let home = app.home
        ScrollView {
            if home.isLoading && home.trackRows.isEmpty {
                ProgressView("Building your Home…").frame(maxWidth: .infinity, minHeight: 300)
            } else if home.loaded && home.trackRows.isEmpty && home.playlistRow == nil {
                ContentUnavailableView {
                    Label("Nothing to show yet", systemImage: "house")
                } description: {
                    Text("Like some tracks and follow a few artists, then come back.")
                } actions: {
                    Button("Go to Search") { app.router.section = .search }
                }
                .frame(minHeight: 300)
            } else {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(home.trackRows) { row in
                        TrackRowStrip(row: row)
                    }
                    if let pl = home.playlistRow {
                        PlaylistRowStrip(row: pl)
                    }
                }
                .padding(.vertical, 18)
            }
        }
        .navigationTitle("Home")
        .toolbar {
            Button { Task { await app.home.reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        .task { await home.loadIfNeeded() }
    }
}

private struct RowHeader: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.title3.weight(.bold))
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 20)
    }
}

struct TrackRowStrip: View {
    @Environment(AppModel.self) private var app
    let row: HomeRow<SCTrack>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeader(title: row.title, subtitle: row.subtitle)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(row.items) { t in
                        TrackCard(track: t) {
                            if let i = row.items.firstIndex(of: t) { app.player.play(row.items, at: i) }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct TrackCard: View {
    @Environment(AppModel.self) private var app
    let track: SCTrack
    let play: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Artwork(url: track.art(.medium), size: 148, radius: 6)
                    .shadow(color: .black.opacity(hover ? 0.28 : 0.12), radius: hover ? 9 : 3, y: 2)
                if hover {
                    Button(action: play) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 38, height: 38).background(Circle().fill(Brand.accent))
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain).padding(8).transition(.opacity)
                }
            }
            Button(track.displayTitle) { app.router.go(.track(track)) }
                .buttonStyle(.plain).font(.callout.weight(.semibold)).lineLimit(1).frame(width: 148, alignment: .leading)
            Button(track.artist) { if let u = track.user { app.router.go(.user(u)) } }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 148, alignment: .leading)
        }
        .frame(width: 148)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .contextMenu { TrackMenu(tracks: [track]) }
    }
}

struct PlaylistRowStrip: View {
    let row: HomeRow<SCPlaylist>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.title3.weight(.bold))
                if let s = row.subtitle { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(row.items) { p in
                        PlaylistCard(playlist: p).frame(width: 158)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - Downloads

struct DownloadsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let d = app.downloader
        let active = d.jobs.filter { if case .done = $0.state { return false }; return true }
        let doneTracks = d.jobs.compactMap { job -> SCTrack? in
            if case .done = job.state { return job.track }; return nil
        }
        List {
            if !active.isEmpty {
                Section("In Progress") {
                    ForEach(active) { job in DownloadJobRow(job: job) }
                }
            }
            Section {
                if doneTracks.isEmpty && active.isEmpty {
                    Text("Downloaded tracks appear here and play without streaming. Right-click any track and choose Download.")
                        .foregroundStyle(.secondary).padding(.vertical, 6)
                }
                ForEach(doneTracks) { t in
                    TrackRow(track: t, number: 0)
                        .contextMenu {
                            Button("Play") { app.player.play(doneTracks, at: doneTracks.firstIndex(of: t) ?? 0) }
                            Button("Show in Finder") { System.reveal(app.downloader.localURL(t)) }
                            Divider()
                            Button(role: .destructive) { app.downloader.deleteDownload(t) } label: { Text("Delete Download") }
                        }
                }
            } header: {
                HStack {
                    Text("Downloaded")
                    Spacer()
                    Button("Open Folder") { System.reveal(app.downloader.folder) }.buttonStyle(.link).font(.caption)
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            Button { app.downloader.clearFinished() } label: { Label("Clear Finished", systemImage: "xmark.circle") }
                .disabled(d.jobs.allSatisfy { if case .done = $0.state { return false }; if case .failed = $0.state { return false }; return true })
        }
    }
}

struct DownloadJobRow: View {
    @Environment(AppModel.self) private var app
    let job: DownloadJob

    var body: some View {
        HStack(spacing: 10) {
            Artwork(url: job.track.art(.small), size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.track.displayTitle).font(.callout).lineLimit(1)
                switch job.state {
                case .waiting:
                    Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                case .running(let p):
                    ProgressView(value: p).controlSize(.small)
                case .failed(let e):
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(1)
                case .done:
                    Text("Done").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case .failed = job.state {
                Button("Retry") { app.downloader.download([job.track]) }.buttonStyle(.link).font(.caption)
            }
            Button { app.downloader.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
}
