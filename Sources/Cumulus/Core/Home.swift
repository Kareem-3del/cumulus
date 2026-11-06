import Foundation

struct HomeRow<T: Identifiable & Hashable>: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    var items: [T]
}

/// Builds the "Home" screen: recommendations seeded from the user's own likes, history and follows.
/// The public SoundCloud API has no global charts endpoint, so "popular" is computed by taking the
/// user's top genres, searching them, and sorting by play count.
@MainActor @Observable final class HomeModel {
    private(set) var trackRows: [HomeRow<SCTrack>] = []
    private(set) var playlistRow: HomeRow<SCPlaylist>?
    private(set) var isLoading = false
    private(set) var loaded = false

    @ObservationIgnored private let api: SoundCloudAPI
    @ObservationIgnored private let library: Library
    @ObservationIgnored var recentlyPlayed: () -> [SCTrack] = { [] }

    init(api: SoundCloudAPI, library: Library) {
        self.api = api
        self.library = library
    }

    func loadIfNeeded() async { if !loaded && !isLoading { await load() } }

    func load() async {
        isLoading = true
        defer { isLoading = false; loaded = true }

        // Seeds: recent history first, then recent likes.
        async let likesPage: [SCTrack] = (try? await firstTracks("/me/likes/tracks", limit: 50)) ?? []
        async let feedPage: [SCTrack] = (try? await firstTracks("/me/feed/tracks", limit: 40)) ?? []
        let likes = await likesPage
        let feed = await feedPage
        let recent = recentlyPlayed()

        var rows: [HomeRow<SCTrack>] = []

        // 1. Made for you — related to a few of your recent plays / likes.
        let seeds = Array((recent + likes).prefix(4))
        let related = await relatedPool(from: seeds.isEmpty ? Array(feed.prefix(4)) : seeds)
        if !related.isEmpty {
            rows.append(HomeRow(id: "foryou", title: "Made for You",
                                subtitle: "Based on what you like", items: related))
        }

        // 2. Popular in your top genres.
        let genres = topGenres(from: likes + feed)
        if let g = genres.first {
            if let pop = try? await popular(genre: g), !pop.isEmpty {
                rows.append(HomeRow(id: "pop1", title: "Popular in \(g.capitalized)", items: pop))
            }
        }
        if genres.count > 1, let pop2 = try? await popular(genre: genres[1]), !pop2.isEmpty {
            rows.append(HomeRow(id: "pop2", title: "Popular in \(genres[1].capitalized)", items: pop2))
        }

        // 3. New from people you follow.
        if !feed.isEmpty {
            rows.append(HomeRow(id: "feed", title: "New From Your Follows", items: Array(feed.prefix(20))))
        }

        // 4. Recently played (pinned to the top).
        if !recent.isEmpty {
            rows.insert(HomeRow(id: "recent", title: "Recently Played", items: Array(recent.prefix(20))), at: 0)
        }

        trackRows = rows

        // Playlists you might like — search your top genre.
        if let g = genres.first,
           let page: Page<SCPlaylist> = try? await api.page("/playlists", ["q": g, "show_tracks": "false"], limit: 20) {
            let list = page.collection.filter { ($0.trackCount ?? 0) > 2 }
            if !list.isEmpty {
                playlistRow = HomeRow(id: "pl", title: "Playlists for You",
                                      subtitle: "In \(g.capitalized)", items: Array(list.prefix(16)))
            }
        }
    }

    func reload() async { loaded = false; await load() }

    func clear() {
        trackRows = []
        playlistRow = nil
        loaded = false
        isLoading = false
    }

    // MARK: Builders

    private func firstTracks(_ path: String, limit: Int) async throws -> [SCTrack] {
        let page: Page<TrackItem> = try await api.page(path, [:], limit: limit)
        return page.tracks
    }

    private func relatedPool(from seeds: [SCTrack]) async -> [SCTrack] {
        var out: [SCTrack] = []
        var seen = Set<String>()
        await withTaskGroup(of: [SCTrack].self) { group in
            for s in seeds.prefix(4) {
                group.addTask { [api] in
                    let p: Page<TrackItem>? = try? await api.page("/tracks/\(s.id)/related", [:], limit: 12)
                    return p?.tracks ?? []
                }
            }
            for await tracks in group {
                for t in tracks where !t.isBlocked && seen.insert(t.id).inserted { out.append(t) }
            }
        }
        return out.shuffled()
    }

    private func popular(genre: String) async throws -> [SCTrack] {
        let page: Page<TrackItem> = try await api.page("/tracks", ["q": genre, "genres": genre], limit: 50)
        return page.tracks
            .filter { !$0.isBlocked }
            .sorted { ($0.playbackCount ?? 0) > ($1.playbackCount ?? 0) }
            .prefix(20)
            .map { $0 }
    }

    private func topGenres(from tracks: [SCTrack]) -> [String] {
        var counts: [String: Int] = [:]
        for t in tracks {
            guard let g = t.genre?.trimmed.nilIfEmpty else { continue }
            counts[g, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }
}
