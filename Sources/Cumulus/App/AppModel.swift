import AppKit
import SwiftUI

enum SidebarItem: Hashable {
    case home, feed, search, likes, playlists, likedPlaylists, myTracks, following, downloads, history
    case playlist(String)
}

enum Route: Hashable {
    case playlist(SCPlaylist)
    case user(SCUser)
    case track(SCTrack)
}

struct PlaylistDraft: Identifiable {
    let id = UUID()
    var tracks: [SCTrack]
}

@MainActor @Observable final class Router {
    var section: SidebarItem? = .home
    var path = NavigationPath()
    var showQueue = false
    var showOpenLink = false
    var showPalette = false
    var showNowPlaying = false
    var searchQuery = ""
    var newPlaylist: PlaylistDraft?
    private(set) var recentSearches: [String] = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []

    func go(_ r: Route) { path.append(r) }

    func addRecentSearch(_ q: String) {
        let q = q.trimmed
        guard !q.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        recentSearches.insert(q, at: 0)
        if recentSearches.count > 8 { recentSearches.removeLast(recentSearches.count - 8) }
        UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: "recentSearches")
    }

    /// Runs a query in the main Search screen.
    func search(_ q: String) {
        addRecentSearch(q)
        searchQuery = q
        path = NavigationPath()
        section = .search
    }
}

@MainActor @Observable final class AppModel {
    let settings = AppSettings()
    let auth: AuthManager
    let api: SoundCloudAPI
    let library: Library
    let downloader: Downloader
    let player: Player
    let home: HomeModel
    let router = Router()
    var loginError: String?

    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var keyMonitor: Any?

    init() {
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        auth = AuthManager()
        api = SoundCloudAPI(auth: auth)
        library = Library(api: api)
        downloader = Downloader(api: api, settings: settings)
        player = Player(api: api, settings: settings, library: library)
        home = HomeModel(api: api, library: library)
        home.recentlyPlayed = { [player] in player.history }
        player.localFile = { [downloader, settings] t in
            settings.preferDownloads ? downloader.localURL(t) : nil
        }
        auth.onSessionExpired = { [weak self] in
            self?.signedOut()
            Toast.shared.show("Your SoundCloud session expired. Log in again.")
        }
        installSpaceBar()
    }

    func bootstrap() async {
        guard auth.isLoggedIn, !bootstrapped else { return }
        bootstrapped = true
        if settings.resumeSession { player.restoreSession() }
        await library.loadAccount()
    }

    func login() async {
        loginError = nil
        do {
            try await auth.login()
            library.reset()
            bootstrapped = false
            await bootstrap()
        } catch AuthError.cancelled {
        } catch {
            loginError = error.localizedDescription
        }
    }

    func logout() {
        auth.logout()
        signedOut()
        Disk.remove("session.json")
    }

    private func signedOut() {
        player.stop()
        library.reset()
        home.clear()
        bootstrapped = false
        router.path = NavigationPath()
        router.section = .home
    }

    /// Opens any soundcloud.com (or on.soundcloud.com short) link: plays tracks, navigates to sets and profiles.
    func openLink(_ raw: String) async {
        guard var url = URL(string: raw.trimmed), let host = url.host, host.hasSuffix("soundcloud.com") else {
            Toast.shared.show("That isn't a SoundCloud link")
            return
        }
        if host == "on.soundcloud.com", let (_, resp) = try? await URLSession.shared.data(from: url), let final = resp.url {
            url = final
        }
        do {
            guard let u = api.url("/resolve", ["url": url.absoluteString]) else { return }
            let data = try await api.data("GET", u)
            struct Kind: Decodable { let kind: String? }
            switch try JSON.decoder.decode(Kind.self, from: data).kind {
            case "track":
                player.play([try JSON.decoder.decode(SCTrack.self, from: data)])
            case "playlist", "system-playlist":
                router.go(.playlist(try JSON.decoder.decode(SCPlaylist.self, from: data)))
            case "user":
                router.go(.user(try JSON.decoder.decode(SCUser.self, from: data)))
            default:
                Toast.shared.show("Cumulus can't open that kind of link")
            }
        } catch {
            Toast.shared.show("Couldn't open link: \(error.localizedDescription)")
        }
    }

    func handleURL(_ url: URL) {
        if auth.handleCallback(url) { return }
        if auth.isLoggedIn, url.host?.hasSuffix("soundcloud.com") == true {
            Task { await openLink(url.absoluteString) }
        }
    }

    /// Global keys: Space toggles playback; ⌘K opens the command palette; ⇧⌘F opens Now Playing.
    private func installSpaceBar() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let editing = event.window?.firstResponder is NSText
            return MainActor.assumeIsolated { () -> NSEvent? in
                guard let self, self.auth.isLoggedIn else { return event }
                // ⌘K — command palette (works even while typing in a field)
                if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "k" {
                    self.router.showPalette = true
                    return nil
                }
                // ⇧⌘F — Now Playing
                if mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "f",
                   self.player.current != nil {
                    self.router.showNowPlaying = true
                    return nil
                }
                // Space — play/pause, unless typing
                if event.keyCode == 49, mods.isEmpty, !editing, self.player.current != nil {
                    self.player.togglePlay()
                    return nil
                }
                return event
            }
        }
    }
}
