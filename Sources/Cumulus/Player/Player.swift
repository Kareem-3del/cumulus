import AppKit
import AVFoundation
import Foundation

enum RepeatMode: String, CaseIterable {
    case off, all, one
    var next: RepeatMode { self == .off ? .all : self == .all ? .one : .off }
}

private struct Session: Codable {
    var queue: [SCTrack]
    var index: Int
    var position: Double
}

/// Queue + AVPlayer. All state is main-actor; AVPlayer callbacks hop back to main.
@MainActor @Observable final class Player {
    private(set) var queue: [SCTrack] = []
    private(set) var index: Int?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var waveform: [Float] = []
    private(set) var history: [SCTrack] = []
    private(set) var shuffle = false

    var repeatMode: RepeatMode = .off { didSet { defaults.set(repeatMode.rawValue, forKey: "repeat") } }
    var volume: Float = 0.8 { didSet { av.volume = volume; defaults.set(volume, forKey: "volume") } }
    var muted = false { didSet { av.isMuted = muted } }
    var speed: Float = 1 {
        didSet {
            av.defaultRate = speed
            if av.rate != 0 { av.rate = speed }
            defaults.set(speed, forKey: "speed")
            syncNowPlaying()
        }
    }

    var current: SCTrack? {
        guard let index, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    @ObservationIgnored private let av = AVPlayer()
    @ObservationIgnored private let api: SoundCloudAPI
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let library: Library
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let nowPlaying = NowPlaying()
    /// Returns a local downloaded file for a track, if one should be used instead of streaming.
    @ObservationIgnored var localFile: (SCTrack) -> URL? = { _ in nil }
    @ObservationIgnored private var unshuffled: [SCTrack]?
    @ObservationIgnored private var context: PagedLoader<SCTrack>?
    @ObservationIgnored private var contextConsumed = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var waveTask: Task<Void, Never>?
    @ObservationIgnored private var itemObs: NSKeyValueObservation?
    @ObservationIgnored private var statusObs: NSKeyValueObservation?
    @ObservationIgnored private var endObs: NSObjectProtocol?
    @ObservationIgnored private var timeObs: Any?
    @ObservationIgnored private var itemLoaded = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var extending = false

    // Sleep timer
    private(set) var sleepAt: Date?
    private(set) var sleepEndOfTrack = false
    @ObservationIgnored private var sleepTask: Task<Void, Never>?

    init(api: SoundCloudAPI, settings: AppSettings, library: Library) {
        self.api = api
        self.settings = settings
        self.library = library

        repeatMode = RepeatMode(rawValue: defaults.string(forKey: "repeat") ?? "") ?? .off
        volume = defaults.object(forKey: "volume") as? Float ?? 0.8
        speed = defaults.object(forKey: "speed") as? Float ?? 1
        shuffle = defaults.bool(forKey: "shuffle")
        history = Disk.load([SCTrack].self, "history.json") ?? []

        av.volume = volume
        av.defaultRate = speed
        av.automaticallyWaitsToMinimizeStalling = true

        timeObs = av.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                             queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        statusObs = av.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let s = p.timeControlStatus
            Task { @MainActor in self?.statusChanged(s) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
        nowPlaying.configure(self, like: { [weak self] in
            guard let self, let t = self.current else { return }
            Task { await self.library.toggleLike(t); self.syncNowPlaying() }
        })
    }

    // MARK: Starting playback

    func play(_ tracks: [SCTrack], at i: Int = 0, context: PagedLoader<SCTrack>? = nil) {
        let tracks = tracks.filter { !$0.isBlocked }
        guard !tracks.isEmpty else { Toast.shared.show("Nothing playable here"); return }
        let i = min(max(i, 0), tracks.count - 1)
        self.context = context
        contextConsumed = context?.items.count ?? 0
        failures = 0
        if shuffle {
            var rest = tracks
            let first = rest.remove(at: i)
            queue = [first] + rest.shuffled()
            unshuffled = tracks
            index = 0
        } else {
            queue = tracks
            unshuffled = nil
            index = i
        }
        startCurrent()
    }

    func playShuffled(_ tracks: [SCTrack], context: PagedLoader<SCTrack>? = nil) {
        if !shuffle { shuffle = true; defaults.set(true, forKey: "shuffle") }
        play(tracks, at: Int.random(in: 0..<max(tracks.count, 1)), context: context)
    }

    func startStation(from t: SCTrack) {
        Task {
            let related = (try? await relatedTracks(t)) ?? []
            play([t] + related.filter { $0.id != t.id }, at: 0)
            context = nil
        }
    }

    private func startCurrent(play: Bool = true, at start: Double? = nil) {
        loadTask?.cancel()
        loadTask = nil
        guard let t = current else { stop(); return }

        itemLoaded = false
        av.replaceCurrentItem(with: nil)
        position = start ?? 0
        duration = t.seconds
        isPlaying = play
        isBuffering = play
        loadWaveform(t)
        if play { addToHistory(t) }
        syncNowPlaying()
        saveSession()

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let item = try await self.makeItem(for: t)
                guard !Task.isCancelled, self.current?.id == t.id else { return }
                self.attach(item)
                if let start, start > 1 {
                    _ = await self.av.seek(to: CMTime(seconds: start, preferredTimescale: 600))
                }
                guard !Task.isCancelled else { return }
                if play { self.av.play() }
                self.loadTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.loadTask = nil
                self.fail(t, error)
            }
        }
    }

    private func makeItem(for t: SCTrack) async throws -> AVPlayerItem {
        if let local = localFile(t) {
            return AVPlayerItem(asset: AVURLAsset(url: local))
        }
        var q: [String: String] = [:]
        if let s = t.secretToken { q["secret_token"] = s }
        let streams: SCStreams? = try? await api.get("/tracks/\(t.id)/streams", q)
        var candidates = streams?.candidates(settings.quality) ?? []
        if candidates.isEmpty { candidates = ["\(SoundCloudAPI.base)/tracks/\(t.id)/stream"] }

        var lastError: Error = APIError.noStream
        for c in candidates {
            do {
                let (url, headers) = try await api.playableURL(c)
                let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
                return AVPlayerItem(asset: AVURLAsset(url: url, options: options))
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }

    private func attach(_ item: AVPlayerItem) {
        if let endObs { NotificationCenter.default.removeObserver(endObs) }
        itemObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor in self?.itemStatus(item, status, error) }
        }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                        object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(natural: true) }
        }
        av.replaceCurrentItem(with: item)
        itemLoaded = true
    }

    private func itemStatus(_ item: AVPlayerItem, _ status: AVPlayerItem.Status, _ error: Error?) {
        guard av.currentItem === item else { return }
        switch status {
        case .failed:
            if let t = current { fail(t, error ?? APIError.noStream) }
        case .readyToPlay:
            failures = 0
            let d = item.duration.seconds
            if d.isFinite, d > 0 { duration = d }
            syncNowPlaying()
        default: break
        }
    }

    private func fail(_ t: SCTrack, _ error: Error) {
        failures += 1
        isBuffering = false
        Toast.shared.show("Can't play “\(t.displayTitle)”: \(error.localizedDescription)")
        if failures < 4, let i = index, i + 1 < queue.count {
            index = i + 1
            startCurrent()
        } else {
            isPlaying = false
            failures = 0
            syncNowPlaying()
        }
    }

    // MARK: AVPlayer callbacks

    private func tick(_ time: CMTime) {
        guard itemLoaded else { return }
        let s = time.seconds
        if s.isFinite { position = s }
        if let d = av.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.5 { duration = d }
    }

    private func statusChanged(_ s: AVPlayer.TimeControlStatus) {
        let buffering = s == .waitingToPlayAtSpecifiedRate
        if isBuffering != buffering && itemLoaded { isBuffering = buffering }
        if s == .playing, !isPlaying { isPlaying = true; syncNowPlaying() }
        if s == .paused, itemLoaded, loadTask == nil, isPlaying, av.currentItem != nil {
            // Paused by the system (output device removed, etc.)
            let atEnd = duration > 0 && position >= duration - 1
            if !atEnd { isPlaying = false; syncNowPlaying() }
        }
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : resume() }

    func pause() {
        av.pause()
        isPlaying = false
        isBuffering = false
        syncNowPlaying()
        saveSession()
    }

    func resume() {
        guard current != nil else { return }
        if !itemLoaded && loadTask == nil {
            startCurrent(play: true, at: position)
            return
        }
        av.play()
        isPlaying = true
        syncNowPlaying()
    }

    func seek(to seconds: Double) {
        let s = min(max(seconds, 0), max(duration, 0))
        position = s
        guard itemLoaded else { syncNowPlaying(); return }
        av.seek(to: CMTime(seconds: s, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.syncNowPlaying() }
        }
    }

    func skip(by delta: Double) { seek(to: position + delta) }

    func next() { advance(natural: false) }

    func previous() {
        guard let i = index else { return }
        if position > 3 || i == 0 { seek(to: 0); return }
        index = i - 1
        startCurrent()
    }

    func cycleRepeat() { repeatMode = repeatMode.next }

    func toggleShuffle() {
        shuffle.toggle()
        defaults.set(shuffle, forKey: "shuffle")
        guard let i = index, queue.indices.contains(i) else { return }
        let cur = queue[i]
        if shuffle {
            unshuffled = queue
            var rest = queue
            rest.remove(at: i)
            queue = [cur] + rest.shuffled()
            index = 0
        } else if let original = unshuffled {
            queue = original
            index = original.firstIndex { $0.id == cur.id } ?? 0
            unshuffled = nil
        }
    }

    // MARK: Sleep timer

    var sleepActive: Bool { sleepAt != nil || sleepEndOfTrack }

    func setSleepTimer(minutes: Int) {
        sleepEndOfTrack = false
        sleepAt = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTask?.cancel()
        let fireAt = sleepAt!
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(fireAt.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            self?.fadeAndPause()
        }
        Toast.shared.show("Sleep timer set for \(minutes) min")
    }

    func setSleepEndOfTrack() {
        sleepTask?.cancel()
        sleepAt = nil
        sleepEndOfTrack = true
        Toast.shared.show("Will stop at the end of this track")
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepAt = nil
        sleepEndOfTrack = false
    }

    private func fadeAndPause() {
        cancelSleepTimer()
        pause()
        Toast.shared.show("Paused by sleep timer")
    }

    private func advance(natural: Bool) {
        if natural && sleepEndOfTrack { cancelSleepTimer(); endOfQueue(); Toast.shared.show("Stopped by sleep timer"); return }
        guard let i = index else { return }
        if natural && repeatMode == .one {
            seek(to: 0)
            av.play()
            return
        }
        if i + 1 < queue.count {
            index = i + 1
            startCurrent()
            return
        }
        guard !extending else { return }
        extending = true
        Task {
            defer { extending = false }
            let grew = await extendQueue(allowRelated: repeatMode != .all)
            if grew, let i = index, i + 1 < queue.count {
                index = i + 1
                startCurrent()
            } else if repeatMode == .all, !queue.isEmpty {
                index = 0
                startCurrent()
            } else {
                endOfQueue()
            }
        }
    }

    /// Pulls the next page of whatever list started playback, else related tracks (autoplay).
    private func extendQueue(allowRelated: Bool) async -> Bool {
        if let ctx = context {
            if ctx.items.count <= contextConsumed, ctx.hasMore { await ctx.loadMore() }
            let fresh = Array(ctx.items.dropFirst(contextConsumed)).filter { !$0.isBlocked }
            contextConsumed = ctx.items.count
            if !fresh.isEmpty { append(fresh); return true }
        }
        guard allowRelated, settings.autoplay, let cur = current,
              let related = try? await relatedTracks(cur) else { return false }
        let known = Set(queue.map(\.id))
        let fresh = related.filter { !known.contains($0.id) && !$0.isBlocked }
        guard !fresh.isEmpty else { return false }
        context = nil
        append(fresh)
        return true
    }

    private func endOfQueue() {
        av.pause()
        isPlaying = false
        isBuffering = false
        seek(to: 0)
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        av.replaceCurrentItem(with: nil)
        itemLoaded = false
        queue = []
        index = nil
        isPlaying = false
        isBuffering = false
        position = 0
        duration = 0
        waveform = []
        context = nil
        unshuffled = nil
        syncNowPlaying()
    }

    private func relatedTracks(_ t: SCTrack) async throws -> [SCTrack] {
        let p: Page<TrackItem> = try await api.page("/tracks/\(t.id)/related", [:], limit: 30)
        return p.tracks
    }

    // MARK: Queue editing

    var upNext: [(offset: Int, track: SCTrack)] {
        guard let i = index else { return [] }
        return queue.enumerated().dropFirst(i + 1).map { ($0.offset, $0.element) }
    }

    private func append(_ tracks: [SCTrack]) {
        queue += shuffle ? tracks.shuffled() : tracks
        unshuffled? += tracks
    }

    func playNext(_ tracks: [SCTrack]) {
        guard let i = index else { play(tracks); return }
        queue.insert(contentsOf: tracks, at: i + 1)
        if let cur = current, var u = unshuffled, let ui = u.firstIndex(where: { $0.id == cur.id }) {
            u.insert(contentsOf: tracks, at: ui + 1)
            unshuffled = u
        }
        Toast.shared.show(tracks.count == 1 ? "Playing next" : "\(tracks.count) tracks playing next")
    }

    func addToQueue(_ tracks: [SCTrack]) {
        guard index != nil else { play(tracks); return }
        queue += tracks
        unshuffled? += tracks
        Toast.shared.show(tracks.count == 1 ? "Added to queue" : "\(tracks.count) tracks added to queue")
    }

    func jump(to queueIndex: Int) {
        guard queue.indices.contains(queueIndex) else { return }
        index = queueIndex
        startCurrent()
    }

    func removeFromQueue(_ queueIndex: Int) {
        guard let i = index, queue.indices.contains(queueIndex), queueIndex != i else { return }
        let removed = queue.remove(at: queueIndex)
        if queueIndex < i { index = i - 1 }
        if let ui = unshuffled?.firstIndex(where: { $0.id == removed.id }) { unshuffled?.remove(at: ui) }
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        guard let i = index else { return }
        var up = Array(queue[(i + 1)...])
        up.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...i]) + up
    }

    func clearUpNext() {
        guard let i = index else { return }
        queue = Array(queue[...i])
        unshuffled = nil
        context = nil
    }

    // MARK: History

    private func addToHistory(_ t: SCTrack) {
        history.removeAll { $0.id == t.id }
        history.insert(t, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        Disk.save(history, "history.json")
    }

    func clearHistory() {
        history = []
        Disk.remove("history.json")
    }

    // MARK: Waveform

    private func loadWaveform(_ t: SCTrack) {
        waveTask?.cancel()
        waveform = []
        guard let w = t.waveformUrl, let url = URL(string: w.replacingOccurrences(of: ".png", with: ".json")) else { return }
        waveTask = Task { [weak self] in
            struct W: Decodable { let samples: [Int]; let height: Int? }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let w = try? JSONDecoder().decode(W.self, from: data), !w.samples.isEmpty,
                  !Task.isCancelled, let self, self.current?.id == t.id else { return }
            let peak = Float(max(w.height ?? 0, w.samples.max() ?? 1, 1))
            let bars = 200
            let chunk = max(1, w.samples.count / bars)
            self.waveform = stride(from: 0, to: w.samples.count, by: chunk).map { start in
                let slice = w.samples[start..<min(start + chunk, w.samples.count)]
                return Float(slice.max() ?? 0) / peak
            }
        }
    }

    // MARK: Session restore

    func saveSession() {
        guard settings.resumeSession, let i = index, !queue.isEmpty else { return }
        let lo = max(0, i - 50), hi = min(queue.count, i + 250)
        Disk.save(Session(queue: Array(queue[lo..<hi]), index: i - lo, position: position), "session.json")
    }

    func restoreSession() {
        guard current == nil, let s = Disk.load(Session.self, "session.json"), s.queue.indices.contains(s.index) else { return }
        queue = s.queue
        index = s.index
        position = s.position
        duration = s.queue[s.index].seconds
        isPlaying = false
        loadWaveform(s.queue[s.index])
        syncNowPlaying()
    }

    // MARK: Now Playing

    func syncNowPlaying() {
        nowPlaying.update(track: current, position: position, duration: duration, playing: isPlaying,
                          speed: speed, liked: current.map(library.isLiked) ?? false)
    }
}
