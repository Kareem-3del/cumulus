import Foundation

enum APIError: LocalizedError {
    case http(Int, String)
    case badURL
    case noStream

    var errorDescription: String? {
        switch self {
        case .http(let code, _):
            switch code {
            case 401: "Not authorized (401)."
            case 403: "SoundCloud doesn't allow this (403)."
            case 404: "Not found (404)."
            case 429: "SoundCloud rate limit reached (429). Try again later."
            default: "SoundCloud returned an error (\(code))."
            }
        case .badURL: "Invalid URL."
        case .noStream: "No playable stream for this track."
        }
    }
}

/// Thin client for api.soundcloud.com. Adds the OAuth header, refreshes once on 401.
@MainActor final class SoundCloudAPI {
    static let base = "https://api.soundcloud.com"
    let auth: AuthManager

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["Accept": "application/json; charset=utf-8"]
        return URLSession(configuration: c)
    }()
    private let noRedirect = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)

    init(auth: AuthManager) { self.auth = auth }

    func url(_ path: String, _ query: [String: String] = [:]) -> URL? {
        guard var comps = URLComponents(string: path.hasPrefix("http") ? path : Self.base + path) else { return nil }
        if !query.isEmpty {
            comps.queryItems = (comps.queryItems ?? []) + query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return comps.url
    }

    func data(_ method: String, _ url: URL, body: Data? = nil) async throws -> Data {
        var retried = false
        while true {
            let token = try await auth.validToken()
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && !retried {
                retried = true
                try await auth.refresh()
                continue
            }
            guard (200..<300).contains(status) else {
                throw APIError.http(status, String(data: data, encoding: .utf8) ?? "")
            }
            return data
        }
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        guard let u = url(path, query) else { throw APIError.badURL }
        return try JSON.decoder.decode(T.self, from: try await data("GET", u))
    }

    func page<T: Decodable>(_ path: String, _ query: [String: String] = [:], limit: Int = 50) async throws -> Page<T> {
        var q = query
        q["linked_partitioning"] = "true"
        q["limit"] = "\(limit)"
        return try await get(path, q)
    }

    func next<T: Decodable>(_ href: String) async throws -> Page<T> {
        try await get(href)
    }

    func send(_ method: String, _ path: String, json: Any? = nil) async throws {
        guard let u = url(path) else { throw APIError.badURL }
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        _ = try await data(method, u, body: body)
    }

    func sendDecoding<T: Decodable>(_ method: String, _ path: String, json: Any) async throws -> T {
        guard let u = url(path) else { throw APIError.badURL }
        let d = try await data(method, u, body: try JSONSerialization.data(withJSONObject: json))
        return try JSON.decoder.decode(T.self, from: d)
    }

    // MARK: Comments & search

    func comments(for t: SCTrack, limit: Int = 60) async throws -> [SCComment] {
        let p: Page<SCComment> = try await page("/tracks/\(t.id)/comments", [:], limit: limit)
        return p.collection
    }

    /// Quick multi-type search for the command palette (a few of each).
    func quickSearch(_ q: String) async -> (tracks: [SCTrack], playlists: [SCPlaylist], users: [SCUser]) {
        async let t: Page<TrackItem>? = try? page("/tracks", ["q": q], limit: 6)
        async let p: Page<SCPlaylist>? = try? page("/playlists", ["q": q, "show_tracks": "false"], limit: 4)
        async let u: Page<SCUser>? = try? page("/users", ["q": q], limit: 4)
        return (await t?.tracks ?? [], await p?.collection ?? [], await u?.collection ?? [])
    }

    // MARK: Streams

    /// Turns a stream URL into something AVPlayer can open. API-hosted URLs redirect to a signed
    /// CDN URL; we follow that one hop ourselves so the OAuth header never reaches the CDN.
    func playableURL(_ s: String) async throws -> (URL, [String: String]) {
        guard let url = URL(string: s) else { throw APIError.badURL }
        guard url.host?.hasSuffix("api.soundcloud.com") == true else { return (url, [:]) }

        var retried = false
        while true {
            let token = try await auth.validToken()
            var req = URLRequest(url: url)
            req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            let (data, resp) = try await noRedirect.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw APIError.noStream }

            switch http.statusCode {
            case 300..<400:
                if let loc = http.value(forHTTPHeaderField: "Location"),
                   let target = URL(string: loc, relativeTo: url)?.absoluteURL {
                    return (target, [:])
                }
                throw APIError.noStream
            case 401 where !retried:
                retried = true
                try await auth.refresh()
                continue
            case 200..<300:
                struct U: Decodable { let url: String? }
                if let u = try? JSONDecoder().decode(U.self, from: data).url, let target = URL(string: u) {
                    return (target, [:])
                }
                return (url, ["Authorization": "OAuth \(token)"])
            default:
                throw APIError.http(http.statusCode, "")
            }
        }
    }

    /// Resolves a downloadable URL for a track: progressive MP3 if the stream offers one, else HLS.
    func resolveDownload(_ t: SCTrack, quality: StreamQuality) async throws -> (url: URL, headers: [String: String], ext: String, progressive: Bool) {
        var q: [String: String] = [:]
        if let s = t.secretToken { q["secret_token"] = s }
        let streams: SCStreams = try await get("/tracks/\(t.id)/streams", q)
        if let prog = streams.httpMp3128Url?.nilIfEmpty {
            let (url, headers) = try await playableURL(prog)
            return (url, headers, "mp3", true)
        }
        let hls = [streams.hlsAac160Url, streams.hlsMp3128Url, streams.hlsAac96Url, streams.previewMp3128Url]
            .compactMap { $0?.nilIfEmpty }
        guard let first = hls.first else { throw APIError.noStream }
        let (url, headers) = try await playableURL(first)
        return (url, headers, "m4a", false)
    }

    // MARK: Loaders

    func trackLoader(_ path: String, _ query: [String: String] = [:]) -> PagedLoader<SCTrack> {
        PagedLoader(
            first: { let p: Page<TrackItem> = try await self.page(path, query); return (p.tracks, p.nextHref) },
            next: { href in let p: Page<TrackItem> = try await self.next(href); return (p.tracks, p.nextHref) }
        )
    }

    func loader<T: Decodable & Identifiable & Hashable>(_ path: String, _ query: [String: String] = [:],
                                                      as: T.Type = T.self) -> PagedLoader<T> {
        PagedLoader(
            first: { let p: Page<T> = try await self.page(path, query); return (p.collection, p.nextHref) },
            next: { href in let p: Page<T> = try await self.next(href); return (p.collection, p.nextHref) }
        )
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Paged loader

@MainActor @Observable final class PagedLoader<T: Identifiable & Hashable> {
    private(set) var items: [T] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loaded = false
    private(set) var hasMore = false

    @ObservationIgnored private var nextHref: String?
    @ObservationIgnored private var seen = Set<T.ID>()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let fetchFirst: () async throws -> ([T], String?)
    @ObservationIgnored private let fetchNext: (String) async throws -> ([T], String?)

    init(first: @escaping () async throws -> ([T], String?), next: @escaping (String) async throws -> ([T], String?)) {
        fetchFirst = first
        fetchNext = next
    }

    func loadIfNeeded() async {
        if !loaded && !isLoading { await reload() }
    }

    func reload() async {
        generation += 1
        let g = generation
        isLoading = true
        error = nil
        do {
            let (new, next) = try await fetchFirst()
            guard g == generation else { return }
            items = []
            seen = []
            append(new)
            nextHref = next
            hasMore = next != nil
            loaded = true
        } catch {
            if g == generation, !Self.isCancel(error) { self.error = error.localizedDescription }
        }
        if g == generation { isLoading = false }
    }

    func loadMore() async {
        guard let href = nextHref, !isLoading else { return }
        let g = generation
        isLoading = true
        do {
            let (new, next) = try await fetchNext(href)
            guard g == generation else { return }
            append(new)
            nextHref = next
            hasMore = next != nil && !new.isEmpty
        } catch {
            if g == generation, !Self.isCancel(error) { self.error = error.localizedDescription }
        }
        if g == generation { isLoading = false }
    }

    func loadAll(maxPages: Int = 40) async {
        await loadIfNeeded()
        var pages = 0
        while hasMore && pages < maxPages && error == nil {
            await loadMore()
            pages += 1
        }
    }

    func prepend(_ item: T) {
        guard loaded, seen.insert(item.id).inserted else { return }
        items.insert(item, at: 0)
    }

    func remove(ids: Set<T.ID>) {
        items.removeAll { ids.contains($0.id) }
        seen.subtract(ids)
    }

    private func append(_ new: [T]) {
        for x in new where seen.insert(x.id).inserted { items.append(x) }
    }

    private static func isCancel(_ e: Error) -> Bool {
        e is CancellationError || (e as? URLError)?.code == .cancelled
    }
}
