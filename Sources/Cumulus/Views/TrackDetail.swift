import SwiftUI

/// A page for a single song: artwork, info, actions, then recommended / related songs.
struct TrackDetailView: View {
    @Environment(AppModel.self) private var app
    let track: SCTrack
    @State private var related: PagedLoader<SCTrack>?
    @State private var full: SCTrack?
    @State private var topComments: [SCComment] = []

    private var t: SCTrack { full ?? track }

    var body: some View {
        Group {
            if let related {
                TrackList(tracks: related.items, loader: related, emptyText: "No related songs found") {
                    header
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(t.displayTitle)
        .task(id: track.id) {
            if related == nil { related = app.api.trackLoader("/tracks/\(track.id)/related") }
            await related?.loadIfNeeded()
            if full == nil { full = try? await app.api.get("/tracks/\(track.id)") }
            if topComments.isEmpty { topComments = Array(((try? await app.api.comments(for: track, limit: 20)) ?? []).prefix(6)) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom, spacing: 20) {
                Artwork(url: t.art(.big), size: 200, radius: 10)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Song").font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                    Text(t.displayTitle).font(.largeTitle.weight(.bold)).lineLimit(3)
                    HStack(spacing: 8) {
                        if let u = t.user {
                            Button { app.router.go(.user(u)) } label: {
                                HStack(spacing: 6) {
                                    Artwork(url: u.avatar(.small), size: 22, circle: true, placeholder: "person.fill")
                                    Text(u.displayName).fontWeight(.medium)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if let g = t.genre?.trimmed.nilIfEmpty {
                            Text("· \(g)").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    HStack(spacing: 18) {
                        Label(compactCount(t.playbackCount), systemImage: "play.fill")
                        Label(compactCount(t.favoritingsCount), systemImage: "heart.fill")
                        Label(compactCount(t.repostsCount), systemImage: "arrow.2.squarepath")
                        Text(formatTime(t.seconds))
                    }
                    .font(.caption).foregroundStyle(.secondary)

                    actions.padding(.top, 4)
                }
                Spacer(minLength: 0)
            }

            if let desc = t.description?.trimmed.nilIfEmpty {
                Text(desc).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(5).fixedSize(horizontal: false, vertical: true)
            }

            if !topComments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Top Comments").font(.headline)
                    ForEach(topComments) { CommentRow(comment: $0) }
                }
                .padding(14)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }

            Text("Related Songs").font(.title3.weight(.bold)).padding(.top, 2)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 2)
    }

    private var actions: some View {
        let isCurrent = app.player.current?.id == t.id
        let liked = app.library.isLiked(t)
        return HStack(spacing: 10) {
            Button {
                if isCurrent { app.player.togglePlay() }
                else { app.player.play([t] + (related?.items ?? []), at: 0, context: related) }
            } label: {
                Label(isCurrent && app.player.isPlaying ? "Pause" : "Play",
                      systemImage: isCurrent && app.player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(minWidth: 64)
            }
            .buttonStyle(.borderedProminent)

            Button { app.player.startStation(from: t) } label: { Label("Station", systemImage: "dot.radiowaves.left.and.right") }

            Button { Task { await app.library.toggleLike(t) } } label: {
                Image(systemName: liked ? "heart.fill" : "heart").foregroundStyle(liked ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            DownloadButton(track: t, size: 15)
            Menu { TrackMenu(tracks: [t]) } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden).fixedSize()
        }
        .controlSize(.large)
    }
}
