import SwiftUI

/// Receives cumulus:// URLs (OAuth callback from the browser) directly as Apple Events,
/// which works no matter which SwiftUI scene is open.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onURL: ((URL) -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        MainActor.assumeIsolated { onURL?(url) }
    }
}

@main
struct CumulusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("Cumulus", id: "main") {
            RootView()
                .environment(app)
                .tint(Brand.accent)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { delegate.onURL = { app.handleURL($0) } }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { PlaybackCommands(app: app) }

        Settings {
            SettingsView()
                .environment(app)
                .tint(Brand.accent)
        }

        MenuBarExtra(isInserted: Bindable(app.settings).showMenuBar) {
            MiniPlayer()
                .environment(app)
                .tint(Brand.accent)
        } label: {
            Image(systemName: app.player.isPlaying ? "waveform" : "cloud.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

struct PlaybackCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open SoundCloud Link…") { app.router.showOpenLink = true }
                .keyboardShortcut("o")
                .disabled(!app.auth.isLoggedIn)
        }
        CommandGroup(after: .toolbar) {
            Button("Search Everything…") { app.router.showPalette = true }
                .keyboardShortcut("k")
                .disabled(!app.auth.isLoggedIn)
            Button("Now Playing") { app.router.showNowPlaying = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(app.player.current == nil)
        }
        CommandMenu("Controls") {
            let p = app.player
            Button(p.isPlaying ? "Pause" : "Play") { p.togglePlay() }
                .disabled(p.current == nil)
            Button("Next") { p.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { p.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Skip Forward 15 Seconds") { p.skip(by: 15) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Skip Back 15 Seconds") { p.skip(by: -15) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            Button("Volume Up") { p.volume = min(1, p.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { p.volume = max(0, p.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button(p.muted ? "Unmute" : "Mute") { p.muted.toggle() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button(p.shuffle ? "Turn Shuffle Off" : "Turn Shuffle On") { p.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Repeat: \(p.repeatMode.rawValue.capitalized)") { p.cycleRepeat() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Like Current Track") {
                if let t = p.current { Task { await app.library.toggleLike(t) } }
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(p.current == nil)
            Button("Start Station from Current Track") {
                if let t = p.current { p.startStation(from: t) }
            }
            .disabled(p.current == nil)
            Divider()
            Button(app.router.showQueue ? "Hide Queue" : "Show Queue") { app.router.showQueue.toggle() }
                .keyboardShortcut("u", modifiers: [.command, .option])
        }
    }
}
