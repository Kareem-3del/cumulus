import Foundation

enum LibraryError: LocalizedError {
    case unsafeEdit
    var errorDescription: String? {
        "Couldn't read every track in this playlist, so it wasn't changed (this protects tracks that are unavailable in your region)."
    }
}

/// The signed-in user's account state: likes, follows, reposts, playlists and the cached section loaders.
@MainActor @Observable final class Library {
    @ObservationIgnored let api: SoundCloudAPI

    private(set) var me: SCUser?
    private(set) var myPlaylists: [SCPlaylist] = []
    private(set) var likedTrackIDs = Set<String>()
    private(set) var likedPlaylistIDs = Set<String>()
    private(set) var followingIDs = Set<String>()
    private(set) var repostedIDs = Set<String>()
    @ObservationIgnored private var unlikedIDs = Set<String>()

    private(set) var feed: PagedLoader<SCTrack>
    private(set) var likes: PagedLoader<SCTrack>
    private(set) var myTracks: PagedLoader<SCTrack>
    private(set) var playlists: PagedLoader<SCPlaylist>
    private(set) var likedPlaylists: PagedLoader<SCPlaylist>
    private(set) var followings: PagedLoader<SCUser>

    init(api: SoundCloudAPI) {
        self.api = api
        feed = api.trackLoader("/me/feed/tracks")
        likes = api.trackLoader("/me/likes/tracks")
        myTracks = api.trackLoader("/me/tracks")
        playlists = api.loader("/me/playlists", ["show_tracks": "false"])
        likedPlaylists = api.loader("/me/likes/playlists")
        followings = api.loader("/me/followings")
    }

    func reset() {
        me = nil
        myPlaylists = []
        likedTrackIDs = []
        likedPlaylistIDs = []
        followingIDs = []
        repostedIDs = []
        unlikedIDs = []
        feed = api.trackLoader("/me/feed/tracks")
        likes = api.trackLoader("/me/likes/tracks")
        myTracks = api.trackLoader("/me/tracks")
        playlists = api.loader("/me/playlists", ["show_tracks": "false"])
        likedPlaylists = api.loader("/me/likes/playlists")
        followings = api.loader("/me/followings")
    }

    // MARK: Account bootstrap

    func loadAccount() async {
        do {
            me = try await api.get("/me")
        } catch {
            Toast.shared.show("Couldn't load your profile: \(error.localizedDescription)")
        }
        Task { await refreshMyPlaylists() }
        Task { likedTrackIDs.formUnion(await collectIDs("/me/likes/tracks", TrackItem.self) { $0.track?.id }) }
        Task { likedPlaylistIDs.formUnion(await collectIDs("/me/likes/playlists", SCPlaylist.self) { $0.id }) }
        Task { followingIDs.formUnion(await collectIDs("/me/followings", SCUser.self) { $0.id }) }
    }

    func refreshMyPlaylists() async {
        var out: [SCPlaylist] = []
        do {
            var page: Page<SCPlaylist> = try await api.page("/me/playlists", ["show_tracks": "false"], limit: 200)
            out = page.collection
            var n = 0
            while let next = page.nextHref, n < 10 {
                page = try await api.next(next)
                out += page.collection
                n += 1
            }
            myPlaylists = out
        } catch {
            if myPlaylists.isEmpty { myPlaylists = out }
        }
    }

    /// Walks a paged endpoint (200 per page, capped) and returns the ids, for heart/follow state.
    private func collectIDs<T: Decodable>(_ path: String, _ type: T.Type, maxPages: Int = 25,
                                          id: (T) -> String?) async -> Set<String> {
        var ids = Set<String>()
        do {
            var page: Page<T> = try await api.page(path, [:], limit: 200)
            ids.formUnion(page.collection.compactMap(id))
            var n = 0
            while let next = page.nextHref, n < maxPages, !page.collection.isEmpty {
                page = try await api.next(next)
                ids.formUnion(page.collection.compactMap(id))
                n += 1
            }
        } catch {}
        return ids
    }

    // MARK: Likes

    func isLiked(_ t: SCTrack) -> Bool {
        !unlikedIDs.contains(t.id) && (likedTrackIDs.contains(t.id) || t.userFavorite == true)
    }

    func toggleLike(_ t: SCTrack) async {
        let was = isLiked(t)
        setLiked(t.id, !was)
        do {
            try await api.send(was ? "DELETE" : "POST", "/likes/tracks/\(t.id)")
            if was { likes.remove(ids: [t.id]) } else { likes.prepend(t) }
        } catch {
            setLiked(t.id, was)
            Toast.shared.show("Couldn't \(was ? "unlike" : "like") track: \(error.localizedDescription)")
        }
    }

    private func setLiked(_ id: String, _ v: Bool) {
        if v { likedTrackIDs.insert(id); unlikedIDs.remove(id) } else { likedTrackIDs.remove(id); unlikedIDs.insert(id) }
    }

    func isLiked(_ p: SCPlaylist) -> Bool { likedPlaylistIDs.contains(p.id) }

    func toggleLike(_ p: SCPlaylist) async {
        let was = isLiked(p)
        if was { likedPlaylistIDs.remove(p.id) } else { likedPlaylistIDs.insert(p.id) }
        do {
            try await api.send(was ? "DELETE" : "POST", "/likes/playlists/\(p.id)")
            if was { likedPlaylists.remove(ids: [p.id]) } else { likedPlaylists.prepend(p) }
        } catch {
            if was { likedPlaylistIDs.insert(p.id) } else { likedPlaylistIDs.remove(p.id) }
            Toast.shared.show("Couldn't update playlist like: \(error.localizedDescription)")
        }
    }

    // MARK: Reposts

    func isReposted(_ t: SCTrack) -> Bool { repostedIDs.contains(t.id) }

    func toggleRepost(_ t: SCTrack) async {
        let was = isReposted(t)
        if was { repostedIDs.remove(t.id) } else { repostedIDs.insert(t.id) }
        do {
            try await api.send(was ? "DELETE" : "POST", "/reposts/tracks/\(t.id)")
            Toast.shared.show(was ? "Repost removed" : "Reposted")
        } catch {
            if was { repostedIDs.insert(t.id) } else { repostedIDs.remove(t.id) }
            Toast.shared.show("Couldn't repost: \(error.localizedDescription)")
        }
    }

    // MARK: Follows

    func isFollowing(_ u: SCUser) -> Bool { followingIDs.contains(u.id) }

    func toggleFollow(_ u: SCUser) async {
        let was = isFollowing(u)
        if was { followingIDs.remove(u.id) } else { followingIDs.insert(u.id) }
        do {
            try await api.send(was ? "DELETE" : "PUT", "/me/followings/\(u.id)")
            if was { followings.remove(ids: [u.id]) } else { followings.prepend(u) }
        } catch {
            if was { followingIDs.insert(u.id) } else { followingIDs.remove(u.id) }
            Toast.shared.show("Couldn't update follow: \(error.localizedDescription)")
        }
    }

    // MARK: Playlists

    func owns(_ p: SCPlaylist) -> Bool {
        guard let me else { return false }
        return p.user?.id == me.id
    }

    func allTracks(of p: SCPlaylist, includeUnplayable: Bool = false, max: Int = 2000) async throws -> [SCTrack] {
        var q: [String: String] = [:]
        if let s = p.secretToken { q["secret_token"] = s }
        if includeUnplayable { q["access"] = "playable,preview,blocked" }
        var page: Page<TrackItem> = try await api.page("/playlists/\(p.id)/tracks", q, limit: 200)
        var out = page.tracks
        while let next = page.nextHref, out.count < max, !page.collection.isEmpty {
            page = try await api.next(next)
            out += page.tracks
        }
        return out
    }

    func add(_ tracks: [SCTrack], to p: SCPlaylist) async {
        do {
            let current = try await safeTrackList(p)
            let new = tracks.filter { t in !current.contains { $0.id == t.id } }
            guard !new.isEmpty else { Toast.shared.show("Already in “\(p.displayTitle)”"); return }
            try await replaceTracks(p, current + new)
            Toast.shared.show("Added to “\(p.displayTitle)”")
            await refreshMyPlaylists()
        } catch {
            Toast.shared.show("Couldn't add to playlist: \(error.localizedDescription)")
        }
    }

    func remove(_ tracks: [SCTrack], from p: SCPlaylist) async -> Bool {
        do {
            let ids = Set(tracks.map(\.id))
            let current = try await safeTrackList(p)
            try await replaceTracks(p, current.filter { !ids.contains($0.id) })
            Toast.shared.show("Removed from “\(p.displayTitle)”")
            await refreshMyPlaylists()
            return true
        } catch {
            Toast.shared.show("Couldn't remove: \(error.localizedDescription)")
            return false
        }
    }

    func createPlaylist(title: String, isPrivate: Bool, tracks: [SCTrack]) async {
        let body: [String: Any] = ["playlist": [
            "title": title,
            "sharing": isPrivate ? "private" : "public",
            "tracks": tracks.map(Self.ref),
        ]]
        do {
            let _: SCPlaylist = try await api.sendDecoding("POST", "/playlists", json: body)
            Toast.shared.show("Created “\(title)”")
            await refreshMyPlaylists()
            Task { await playlists.reload() }
        } catch {
            Toast.shared.show("Couldn't create playlist: \(error.localizedDescription)")
        }
    }

    func deletePlaylist(_ p: SCPlaylist) async -> Bool {
        do {
            try await api.send("DELETE", "/playlists/\(p.id)")
            myPlaylists.removeAll { $0.id == p.id }
            playlists.remove(ids: [p.id])
            Toast.shared.show("Deleted “\(p.displayTitle)”")
            return true
        } catch {
            Toast.shared.show("Couldn't delete playlist: \(error.localizedDescription)")
            return false
        }
    }

    /// PUT replaces the whole track list, so refuse unless we read every track the server says it has.
    private func safeTrackList(_ p: SCPlaylist) async throws -> [SCTrack] {
        let fresh: SCPlaylist = try await api.get("/playlists/\(p.id)", ["show_tracks": "false"])
        let tracks = try await allTracks(of: fresh, includeUnplayable: true, max: 5000)
        if let expected = fresh.trackCount, expected != tracks.count { throw LibraryError.unsafeEdit }
        return tracks
    }

    private func replaceTracks(_ p: SCPlaylist, _ tracks: [SCTrack]) async throws {
        try await api.send("PUT", "/playlists/\(p.id)", json: ["playlist": ["tracks": tracks.map(Self.ref)]])
    }

    private static func ref(_ t: SCTrack) -> [String: Any] {
        var d: [String: Any] = [:]
        if let id = t.rawID { d["id"] = id }
        if let urn = t.urn { d["urn"] = urn }
        return d
    }
}
