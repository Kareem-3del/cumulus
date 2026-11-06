import Foundation

// MARK: - JSON

enum JSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}

// MARK: - Artwork sizes (SoundCloud CDN suffixes)

enum ArtSize: String {
    case small = "large"        // 100x100
    case medium = "t300x300"
    case big = "t500x500"
}

func scArtwork(_ s: String?, _ size: ArtSize) -> URL? {
    guard let s, !s.isEmpty else { return nil }
    return URL(string: s.replacingOccurrences(of: "-large.", with: "-\(size.rawValue)."))
}

// MARK: - User

struct SCUser: Codable, Hashable, Identifiable {
    var rawID: Int?
    var urn: String?
    var username: String?
    var fullName: String?
    var avatarUrl: String?
    var permalinkUrl: String?
    var city: String?
    var country: String?
    var description: String?
    var followersCount: Int?
    var followingsCount: Int?
    var trackCount: Int?
    var playlistCount: Int?
    var publicFavoritesCount: Int?

    enum CodingKeys: String, CodingKey {
        case rawID = "id", urn, username, fullName, avatarUrl, permalinkUrl, city, country,
             description, followersCount, followingsCount, trackCount, playlistCount, publicFavoritesCount
    }

    var id: String { urn ?? "soundcloud:users:\(rawID ?? 0)" }
    var displayName: String { username?.nilIfEmpty ?? fullName?.nilIfEmpty ?? "Unknown" }
    func avatar(_ size: ArtSize) -> URL? { scArtwork(avatarUrl, size) }
}

// MARK: - Track

struct SCTrack: Codable, Hashable, Identifiable {
    var rawID: Int?
    var urn: String?
    var kind: String?
    var title: String?
    var user: SCUser?
    var artworkUrl: String?
    var waveformUrl: String?
    var permalinkUrl: String?
    var duration: Int?
    var genre: String?
    var tagList: String?
    var description: String?
    var createdAt: String?
    var playbackCount: Int?
    var favoritingsCount: Int?
    var repostsCount: Int?
    var commentCount: Int?
    var userFavorite: Bool?
    var streamable: Bool?
    var access: String?
    var metadataArtist: String?
    var secretToken: String?

    enum CodingKeys: String, CodingKey {
        case rawID = "id", urn, kind, title, user, artworkUrl, waveformUrl, permalinkUrl, duration, genre,
             tagList, description, createdAt, playbackCount, favoritingsCount, repostsCount, commentCount,
             userFavorite, streamable, access, metadataArtist, secretToken
    }

    var id: String { urn ?? "soundcloud:tracks:\(rawID ?? 0)" }
    var displayTitle: String { title?.nilIfEmpty ?? "Untitled" }
    var artist: String { user?.displayName ?? "" }
    var seconds: Double { Double(duration ?? 0) / 1000 }
    var isPreview: Bool { access == "preview" }
    var isBlocked: Bool { access == "blocked" }
    func art(_ size: ArtSize) -> URL? { scArtwork(artworkUrl?.nilIfEmpty ?? user?.avatarUrl, size) }
}

// MARK: - Playlist

struct SCPlaylist: Codable, Hashable, Identifiable {
    var rawID: Int?
    var urn: String?
    var kind: String?
    var title: String?
    var user: SCUser?
    var artworkUrl: String?
    var permalinkUrl: String?
    var trackCount: Int?
    var duration: Int?
    var tracks: [SCTrack]?
    var sharing: String?
    var playlistType: String?
    var setType: String?
    var likesCount: Int?
    var description: String?
    var secretToken: String?

    enum CodingKeys: String, CodingKey {
        case rawID = "id", urn, kind, title, user, artworkUrl, permalinkUrl, trackCount, duration, tracks,
             sharing, playlistType, setType, likesCount, description, secretToken
    }

    var id: String { urn ?? "soundcloud:playlists:\(rawID ?? 0)" }
    var displayTitle: String { title?.nilIfEmpty ?? "Untitled" }
    var isAlbum: Bool { (setType ?? playlistType ?? "").lowercased().contains("album") }
    var isPrivate: Bool { sharing == "private" }
    func art(_ size: ArtSize) -> URL? {
        scArtwork(artworkUrl?.nilIfEmpty ?? tracks?.first?.artworkUrl ?? user?.avatarUrl, size)
    }
}

// MARK: - Comment

struct SCComment: Codable, Hashable, Identifiable {
    var rawID: Int?
    var body: String?
    var timestamp: Int?      // position in the track (ms), nil for a general comment
    var createdAt: String?
    var user: SCUser?

    enum CodingKeys: String, CodingKey {
        case rawID = "id", body, timestamp, createdAt, user
    }
    var id: Int { rawID ?? Int.random(in: Int.min...(-1)) }
    var at: String? { timestamp.map { formatTime(Double($0) / 1000) } }
}

// MARK: - Streams

struct SCStreams: Decodable {
    var httpMp3128Url: String?
    var hlsMp3128Url: String?
    var hlsAac160Url: String?
    var hlsAac96Url: String?
    var previewMp3128Url: String?

    func candidates(_ q: StreamQuality) -> [String] {
        let order: [String?] = switch q {
        case .high: [hlsAac160Url, httpMp3128Url, hlsMp3128Url, hlsAac96Url]
        case .standard: [httpMp3128Url, hlsMp3128Url, hlsAac160Url, hlsAac96Url]
        case .saver: [hlsAac96Url, hlsMp3128Url, httpMp3128Url, hlsAac160Url]
        }
        return (order + [previewMp3128Url]).compactMap { $0?.nilIfEmpty }
    }
}

// MARK: - Paging

struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) { value = try? T(from: decoder) }
}

struct Page<T: Decodable>: Decodable {
    var collection: [T]
    var nextHref: String?

    enum CodingKeys: String, CodingKey { case collection, nextHref }

    init(from decoder: Decoder) throws {
        if let arr = try? decoder.singleValueContainer().decode([Lossy<T>].self) {
            collection = arr.compactMap(\.value)
            nextHref = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = (try c.decodeIfPresent([Lossy<T>].self, forKey: .collection) ?? []).compactMap(\.value)
        nextHref = try c.decodeIfPresent(String.self, forKey: .nextHref)?.nilIfEmpty
    }
}

/// A track list entry. Feed endpoints wrap tracks as activities (`origin`); others return tracks directly.
struct TrackItem: Decodable {
    let track: SCTrack?

    enum Keys: String, CodingKey { case origin, type }

    init(from decoder: Decoder) {
        var t: SCTrack?
        if let c = try? decoder.container(keyedBy: Keys.self), c.contains(.origin) {
            let type = (try? c.decode(String.self, forKey: .type)) ?? ""
            t = type.hasPrefix("playlist") ? nil : (try? c.decode(SCTrack.self, forKey: .origin))
        } else {
            t = try? SCTrack(from: decoder)
        }
        if let k = t?.kind, k != "track" { t = nil }
        if t?.urn == nil && t?.rawID == nil { t = nil }
        track = t
    }
}

extension Page where T == TrackItem {
    var tracks: [SCTrack] { collection.compactMap(\.track) }
}

// MARK: - Helpers

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

func formatTime(_ s: Double) -> String {
    guard s.isFinite, s > 0 else { return "0:00" }
    let t = Int(s.rounded(.down))
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

func formatDuration(_ ms: Int?) -> String {
    let s = Double(ms ?? 0) / 1000
    let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
    return h > 0 ? "\(h) hr \(m) min" : "\(max(m, 1)) min"
}

func compactCount(_ n: Int?) -> String {
    (n ?? 0).formatted(.number.notation(.compactName))
}
