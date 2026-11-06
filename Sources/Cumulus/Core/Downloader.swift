import AVFoundation
import Foundation

enum DownloadState: Equatable {
    case waiting, running(Double), done, failed(String)
}

struct DownloadJob: Identifiable {
    let id: String
    let track: SCTrack
    var state: DownloadState
}

/// Downloads tracks to a folder on disk. Progressive MP3 streams are saved directly;
/// HLS-only tracks are remuxed to .m4a with AVAssetExportSession.
@MainActor @Observable final class Downloader {
    private(set) var jobs: [DownloadJob] = []
    private(set) var index: [String: String] = [:]   // trackID -> filename
    @ObservationIgnored private let api: SoundCloudAPI
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var running = Set<String>()

    init(api: SoundCloudAPI, settings: AppSettings) {
        self.api = api
        self.settings = settings
        index = Disk.load([String: String].self, "downloads.json") ?? [:]
        pruneMissing()
    }

    var folder: URL {
        if let path = settings.downloadFolderPath, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cumulus", isDirectory: true)
    }

    func isDownloaded(_ t: SCTrack) -> Bool { localURL(t) != nil }

    func localURL(_ t: SCTrack) -> URL? {
        guard let name = index[t.id] else { return nil }
        let u = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func state(_ t: SCTrack) -> DownloadState? { jobs.first { $0.id == t.id }?.state }

    // MARK: Queueing

    func download(_ tracks: [SCTrack]) {
        let fresh = tracks.filter { !$0.isBlocked && !isDownloaded($0) && !running.contains($0.id) }
        guard !fresh.isEmpty else {
            if tracks.count == 1 { Toast.shared.show("Already downloaded") }
            return
        }
        for t in fresh {
            running.insert(t.id)
            upsert(t.id, DownloadJob(id: t.id, track: t, state: .waiting))
            Task { await run(t) }
        }
        Toast.shared.show(fresh.count == 1 ? "Downloading…" : "Downloading \(fresh.count) tracks…")
    }

    func cancel(_ id: String) {
        running.remove(id)
        jobs.removeAll { $0.id == id }
    }

    func clearFinished() {
        jobs.removeAll { if case .done = $0.state { return true }; if case .failed = $0.state { return true }; return false }
    }

    func deleteDownload(_ t: SCTrack) {
        if let name = index[t.id] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        index[t.id] = nil
        Disk.save(index, "downloads.json")
        jobs.removeAll { $0.id == t.id }
    }

    // MARK: Running

    private func run(_ t: SCTrack) async {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (url, headers, ext, progressive) = try await api.resolveDownload(t, quality: settings.quality)
            let name = filename(for: t, ext: ext)
            let dest = folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)

            if progressive {
                try await downloadProgressive(from: url, headers: headers, to: dest, id: t.id)
            } else {
                try await exportHLS(from: url, headers: headers, to: dest, id: t.id)
            }
            guard running.contains(t.id) else { try? FileManager.default.removeItem(at: dest); return }

            index[t.id] = name
            Disk.save(index, "downloads.json")
            running.remove(t.id)
            upsert(t.id, DownloadJob(id: t.id, track: t, state: .done))
        } catch {
            running.remove(t.id)
            if !(error is CancellationError) {
                upsert(t.id, DownloadJob(id: t.id, track: t, state: .failed(error.localizedDescription)))
                Toast.shared.show("Couldn't download “\(t.displayTitle)”: \(error.localizedDescription)")
            }
        }
    }

    private func downloadProgressive(from url: URL, headers: [String: String], to dest: URL, id: String) async throws {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let total = resp.expectedContentLength
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        var buffer = Data(); buffer.reserveCapacity(1 << 16)
        var written: Int64 = 0, lastReport = Date.distantPast
        for try await byte in bytes {
            guard running.contains(id) else { throw CancellationError() }
            buffer.append(byte)
            if buffer.count >= (1 << 16) {
                try handle.write(contentsOf: buffer); written += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if total > 0, Date().timeIntervalSince(lastReport) > 0.2 {
                    lastReport = Date()
                    setProgress(id, Double(written) / Double(total))
                }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
    }

    private func exportHLS(from url: URL, headers: [String: String], to dest: URL, id: String) async throws {
        let options: [String: Any] = headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw APIError.noStream
        }
        export.outputURL = dest
        export.outputFileType = .m4a
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                let p = export.progress
                await MainActor.run { self?.setProgress(id, Double(p)) }
            }
        }
        await export.export()
        poll.cancel()
        if export.status != .completed {
            throw export.error ?? APIError.noStream
        }
    }

    // MARK: Helpers

    private func setProgress(_ id: String, _ p: Double) {
        guard running.contains(id), let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = .running(min(max(p, 0), 1))
    }

    private func upsert(_ id: String, _ job: DownloadJob) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i] = job } else { jobs.append(job) }
    }

    private func filename(for t: SCTrack, ext: String) -> String {
        let raw = "\(t.artist) - \(t.displayTitle)".trimmed
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "_")
        let base = String(cleaned.prefix(120)).trimmed.nilIfEmpty ?? "track-\(t.rawID ?? 0)"
        var name = "\(base).\(ext)"
        var n = 2
        while index.values.contains(name) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            if index[t.id] == name { break }
            name = "\(base) (\(n)).\(ext)"; n += 1
        }
        return name
    }

    private func pruneMissing() {
        for (id, name) in index where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            index[id] = nil
        }
        Disk.save(index, "downloads.json")
    }
}
