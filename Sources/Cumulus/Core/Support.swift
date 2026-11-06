import AppKit
import Foundation
import Security
import SwiftUI

// MARK: - Brand

enum Brand {
    static let accent = Color(red: 1.0, green: 0.38, blue: 0.05)
}

// MARK: - Settings

enum StreamQuality: String, CaseIterable, Identifiable {
    case high, standard, saver
    var id: String { rawValue }
    var label: String {
        switch self {
        case .high: "High (AAC 160 kbps)"
        case .standard: "Standard (MP3 128 kbps)"
        case .saver: "Data saver (AAC 96 kbps)"
        }
    }
}

@MainActor @Observable final class AppSettings {
    @ObservationIgnored private let d = UserDefaults.standard

    var quality: StreamQuality { didSet { d.set(quality.rawValue, forKey: "quality") } }
    var autoplay: Bool { didSet { d.set(autoplay, forKey: "autoplay") } }
    var showMenuBar: Bool { didSet { d.set(showMenuBar, forKey: "showMenuBar") } }
    var resumeSession: Bool { didSet { d.set(resumeSession, forKey: "resumeSession") } }
    var preferDownloads: Bool { didSet { d.set(preferDownloads, forKey: "preferDownloads") } }
    var downloadFolderPath: String? { didSet { d.set(downloadFolderPath, forKey: "downloadFolderPath") } }

    init() {
        let d = UserDefaults.standard
        quality = StreamQuality(rawValue: d.string(forKey: "quality") ?? "") ?? .high
        autoplay = d.object(forKey: "autoplay") as? Bool ?? true
        showMenuBar = d.object(forKey: "showMenuBar") as? Bool ?? true
        resumeSession = d.object(forKey: "resumeSession") as? Bool ?? true
        preferDownloads = d.object(forKey: "preferDownloads") as? Bool ?? true
        downloadFolderPath = d.string(forKey: "downloadFolderPath")
    }
}

// MARK: - Keychain

enum Keychain {
    static let service = "com.kareem.cumulus"

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func save<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let q = base(key)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func delete(_ key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }
}

// MARK: - Disk (Application Support/Cumulus)

enum Disk {
    static let dir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cumulus", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSON.encoder.encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSON.decoder.decode(T.self, from: data)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}

// MARK: - Toast

@MainActor @Observable final class Toast {
    static let shared = Toast()
    private(set) var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func show(_ m: String) {
        message = m
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

// MARK: - Image cache

@MainActor final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<NSImage?, Never>] = [:]

    init() { cache.countLimit = 500 }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> NSImage? {
        if let img = cached(url) { return img }
        if let t = inflight[url] { return await t.value }
        let t = Task<NSImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        inflight[url] = t
        let img = await t.value
        inflight[url] = nil
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }

    func clear() {
        cache.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
    }
}

// MARK: - System helpers

@MainActor enum System {
    static func copy(_ s: String?) {
        guard let s else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        Toast.shared.show("Link copied")
    }

    static func open(_ s: String?) {
        guard let s, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ url: URL?) {
        guard let url else { return }
        if url.hasDirectoryPath {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
