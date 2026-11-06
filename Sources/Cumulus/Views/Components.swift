import SwiftUI

struct Artwork: View {
    let url: URL?
    var size: CGFloat? = nil
    var radius: CGFloat = 4
    var circle = false
    var placeholder = "music.note"
    @State private var image: NSImage?

    var body: some View {
        let shown = image ?? url.flatMap { ImageLoader.shared.cached($0) }
        ZStack {
            Rectangle().fill(.quaternary)
            if let shown {
                Image(nsImage: shown).resizable().scaledToFill()
            } else {
                Image(systemName: placeholder)
                    .font(.system(size: (size ?? 120) * 0.3))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
        .task(id: url) {
            guard let url else { image = nil; return }
            image = ImageLoader.shared.cached(url)
            if image == nil { image = await ImageLoader.shared.image(url) }
        }
    }
}

struct IconButton: View {
    let systemName: String
    var active = false
    var size: CGFloat = 13
    var help: String = ""
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    init(_ systemName: String, active: Bool = false, size: CGFloat = 13, help: String = "", action: @escaping () -> Void) {
        self.systemName = systemName
        self.active = active
        self.size = size
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 14, height: size + 14)
                .contentShape(Rectangle())
                .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(hover ? .primary : .secondary))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help.isEmpty ? systemName : help)
    }
}

struct LikeButton: View {
    @Environment(AppModel.self) private var app
    let track: SCTrack
    var size: CGFloat = 12

    var body: some View {
        let liked = app.library.isLiked(track)
        IconButton(liked ? "heart.fill" : "heart", active: liked, size: size, help: liked ? "Unlike" : "Like") {
            Task { await app.library.toggleLike(track) }
        }
    }
}

struct DownloadButton: View {
    @Environment(AppModel.self) private var app
    let track: SCTrack
    var size: CGFloat = 12

    var body: some View {
        let d = app.downloader
        switch d.state(track) {
        case .running(let p):
            ProgressView(value: p).progressViewStyle(.circular).controlSize(.small)
                .frame(width: size + 14, height: size + 14)
                .help("Downloading \(Int(p * 100))%")
        case .waiting:
            ProgressView().controlSize(.small).frame(width: size + 14, height: size + 14)
        default:
            if d.isDownloaded(track) {
                IconButton("arrow.down.circle.fill", active: true, size: size, help: "Downloaded — click to delete") {
                    d.deleteDownload(track)
                }
            } else {
                IconButton("arrow.down.circle", size: size, help: "Download") { d.download([track]) }
            }
        }
    }
}

struct ToastView: View {
    var body: some View {
        if let m = Toast.shared.message {
            Text(m)
                .font(.callout)
                .lineLimit(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 12)
        }
    }
}

struct StatusFooter<T: Identifiable & Hashable>: View {
    let loader: PagedLoader<T>
    var emptyText = "Nothing here yet"

    var body: some View {
        Group {
            if loader.isLoading {
                ProgressView().controlSize(.small)
            } else if let e = loader.error {
                VStack(spacing: 6) {
                    Text(e).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { Task { loader.items.isEmpty ? await loader.reload() : await loader.loadMore() } }
                }
            } else if loader.loaded && loader.items.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

/// Simple wrapping chip row.
struct FlowChips: View {
    let items: [String]
    let tap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button { tap(item) } label: {
                    Text(item).lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.bold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
    }
}
