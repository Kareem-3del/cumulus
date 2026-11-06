import SwiftUI

struct PlayerBar: View {
    var body: some View {
        HStack(spacing: 20) {
            NowPlayingSummary()
                .frame(minWidth: 180, maxWidth: 320, alignment: .leading)
            VStack(spacing: 2) {
                Transport()
                Scrubber()
            }
            .frame(minWidth: 300, maxWidth: 640)
            .layoutPriority(1)
            ExtraControls()
                .frame(minWidth: 180, maxWidth: 320, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 76)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct NowPlayingSummary: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let t = app.player.current {
            HStack(spacing: 10) {
                Button { app.router.showNowPlaying = true } label: {
                    Artwork(url: t.art(.medium), size: 50, radius: 5)
                }
                .buttonStyle(.plain)
                .help("Open Now Playing (⇧⌘F)")
                VStack(alignment: .leading, spacing: 2) {
                    Button(t.displayTitle) { app.router.go(.track(t)) }
                        .buttonStyle(.plain).font(.callout.weight(.semibold)).lineLimit(1)
                        .help("Open song page")
                    Button(t.artist) { if let u = t.user { app.router.go(.user(u)) } }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                LikeButton(track: t)
                DownloadButton(track: t)
            }
            .contextMenu { TrackMenu(tracks: [t]) }
        } else {
            HStack(spacing: 10) {
                Artwork(url: nil, size: 50, radius: 5)
                Text("Not playing").foregroundStyle(.tertiary)
            }
        }
    }
}

struct Transport: View {
    @Environment(AppModel.self) private var app
    var compact = false

    var body: some View {
        let p = app.player
        HStack(spacing: compact ? 12 : 18) {
            IconButton("shuffle", active: p.shuffle, help: "Shuffle") { p.toggleShuffle() }
            IconButton("backward.fill", size: 15, help: "Previous") { p.previous() }
            PlayButton()
            IconButton("forward.fill", size: 15, help: "Next") { p.next() }
            IconButton(p.repeatMode == .one ? "repeat.1" : "repeat", active: p.repeatMode != .off,
                       help: "Repeat: \(p.repeatMode.rawValue)") { p.cycleRepeat() }
        }
        .disabled(p.current == nil)
    }
}

struct PlayButton: View {
    @Environment(AppModel.self) private var app
    @State private var spin = false

    var body: some View {
        let p = app.player
        Button { p.togglePlay() } label: {
            ZStack {
                Circle().fill(.primary).frame(width: 32, height: 32)
                Image(systemName: p.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .offset(x: p.isPlaying ? 0 : 1)
                if p.isBuffering {
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Brand.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 38, height: 38)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .onAppear {
                            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                        }
                        .onDisappear { spin = false }
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(p.isPlaying ? "Pause (Space)" : "Play (Space)")
    }
}

/// Waveform scrubber (SoundCloud waveform data), falls back to a plain bar.
struct Scrubber: View {
    @Environment(AppModel.self) private var app
    var height: CGFloat = 22
    @State private var drag: Double?
    @State private var hoverX: CGFloat?

    var body: some View {
        let p = app.player
        let dur = p.duration
        let live = dur > 0 ? min(max(p.position / dur, 0), 1) : 0
        let frac = drag ?? live
        HStack(spacing: 8) {
            Text(formatTime(frac * dur))
                .frame(width: 46, alignment: .trailing)
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                Canvas { ctx, size in
                    Self.draw(ctx, size, samples: p.waveform, progress: frac,
                              hover: hoverX.map { Double($0 / w) })
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in drag = min(max(Double(v.location.x / w), 0), 1) }
                        .onEnded { v in
                            let f = min(max(Double(v.location.x / w), 0), 1)
                            drag = nil
                            p.seek(to: f * dur)
                        }
                )
                .onContinuousHover { phase in
                    if case .active(let pt) = phase { hoverX = pt.x } else { hoverX = nil }
                }
                .help(hoverX.map { formatTime(Double($0 / w) * dur) } ?? "")
            }
            .frame(height: height)
            Text(formatTime(dur))
                .frame(width: 46, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .disabled(p.current == nil)
    }

    static func draw(_ ctx: GraphicsContext, _ size: CGSize, samples: [Float], progress: Double, hover: Double?) {
        let played = GraphicsContext.Shading.color(Brand.accent)
        let rest = GraphicsContext.Shading.color(.primary.opacity(0.22))
        let hoverShade = GraphicsContext.Shading.color(Brand.accent.opacity(0.45))
        let cut = size.width * progress

        guard !samples.isEmpty else {
            let y = size.height / 2 - 2
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: 4), cornerRadius: 2), with: rest)
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: cut, height: 4), cornerRadius: 2), with: played)
            return
        }

        let barW: CGFloat = 2, gap: CGFloat = 1
        let count = max(1, Int(size.width / (barW + gap)))
        var a = Path(), b = Path(), h = Path()
        let hoverCut = hover.map { size.width * $0 }
        for i in 0..<count {
            let lo = i * samples.count / count
            let hi = max(lo + 1, (i + 1) * samples.count / count)
            let v = samples[lo..<min(hi, samples.count)].max() ?? 0
            let bh = max(2, CGFloat(v) * size.height)
            let x = CGFloat(i) * (barW + gap)
            let r = CGRect(x: x, y: (size.height - bh) / 2, width: barW, height: bh)
            if x < cut { a.addRect(r) } else if let hc = hoverCut, x < hc { h.addRect(r) } else { b.addRect(r) }
        }
        ctx.fill(b, with: rest)
        ctx.fill(h, with: hoverShade)
        ctx.fill(a, with: played)
    }
}

struct ExtraControls: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var p = app.player
        @Bindable var router = app.router
        HStack(spacing: 8) {
            Menu {
                ForEach([0.5, 0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { s in
                    Toggle(Self.speedLabel(s), isOn: Binding(get: { p.speed == s }, set: { _ in p.speed = s }))
                }
            } label: {
                Text(Self.speedLabel(p.speed)).font(.caption.monospacedDigit().weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playback speed")

            SleepTimerMenu()
            IconButton(volumeIcon(p), help: p.muted ? "Unmute" : "Mute") { p.muted.toggle() }
            Slider(value: $p.volume, in: 0...1)
                .controlSize(.mini)
                .frame(width: 80)
                .help("Volume \(Int(p.volume * 100))%")
            IconButton("list.bullet", active: router.showQueue, help: "Queue") { router.showQueue.toggle() }
        }
    }

    private func volumeIcon(_ p: Player) -> String {
        if p.muted || p.volume == 0 { return "speaker.slash.fill" }
        return p.volume < 0.34 ? "speaker.wave.1.fill" : p.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    static func speedLabel(_ s: Float) -> String {
        s == Float(Int(s)) ? "\(Int(s))×" : "\(String(format: "%g", s))×"
    }
}

// MARK: - Queue

struct QueueView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        let p = app.player
        List {
            if let cur = p.current {
                Section("Now Playing") { QueueRow(track: cur, highlighted: true) }
            }
            Section {
                ForEach(p.upNext, id: \.offset) { item in
                    QueueRow(track: item.track)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { p.jump(to: item.offset) }
                        .contextMenu {
                            Button("Play Now") { p.jump(to: item.offset) }
                            Button("Remove from Queue") { p.removeFromQueue(item.offset) }
                            Divider()
                            TrackMenu(tracks: [item.track])
                        }
                }
                .onMove { p.moveUpNext(from: $0, to: $1) }
                if p.upNext.isEmpty {
                    Text(settings.autoplay ? "Similar tracks play when the queue ends" : "Nothing up next")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Up Next")
                    Spacer()
                    if !p.upNext.isEmpty { Button("Clear") { p.clearUpNext() }.buttonStyle(.link).font(.caption) }
                }
            }
            Section {
                Toggle("Autoplay similar tracks", isOn: $settings.autoplay)
            }
        }
        .navigationTitle("Queue")
    }
}

struct QueueRow: View {
    let track: SCTrack
    var highlighted = false

    var body: some View {
        HStack(spacing: 8) {
            Artwork(url: track.art(.small), size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.displayTitle).font(.callout.weight(highlighted ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(formatTime(track.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Menu bar mini player

struct MiniPlayer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var p = app.player
        VStack(spacing: 12) {
            if let t = p.current {
                HStack(spacing: 12) {
                    Artwork(url: t.art(.medium), size: 64, radius: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.displayTitle).font(.headline).lineLimit(2)
                        Text(t.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    LikeButton(track: t, size: 14)
                }
                Scrubber(height: 26)
                Transport(compact: true)
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $p.volume, in: 0...1).controlSize(.small)
                    Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(app.auth.isLoggedIn ? "Nothing playing" : "Log in to start listening")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }
            Divider()
            HStack {
                Button("Open Cumulus") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 320)
    }
}
