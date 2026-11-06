import AppKit
import MediaPlayer

/// Media keys, Control Center / lock screen "Now Playing", AirPods controls.
@MainActor final class NowPlaying {
    private var info: [String: Any] = [:]
    private var artworkTrackID: String?

    func configure(_ player: Player, like: @escaping () -> Void) {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in Task { @MainActor in player.resume() }; return .success }
        c.pauseCommand.addTarget { _ in Task { @MainActor in player.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { _ in Task { @MainActor in player.togglePlay() }; return .success }
        c.nextTrackCommand.addTarget { _ in Task { @MainActor in player.next() }; return .success }
        c.previousTrackCommand.addTarget { _ in Task { @MainActor in player.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in player.seek(to: t) }
            return .success
        }
        c.likeCommand.localizedTitle = "Like"
        c.likeCommand.addTarget { _ in Task { @MainActor in like() }; return .success }
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
    }

    func update(track: SCTrack?, position: Double, duration: Double, playing: Bool, speed: Float, liked: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = track else {
            info = [:]
            artworkTrackID = nil
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var i: [String: Any] = [
            MPMediaItemPropertyTitle: t.displayTitle,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(speed) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if artworkTrackID == t.id, let art = info[MPMediaItemPropertyArtwork] { i[MPMediaItemPropertyArtwork] = art }
        info = i
        center.nowPlayingInfo = i
        center.playbackState = playing ? .playing : .paused
        MPRemoteCommandCenter.shared().likeCommand.isActive = liked

        guard artworkTrackID != t.id else { return }
        artworkTrackID = t.id
        guard let url = t.art(.big) else { return }
        Task {
            guard let img = await ImageLoader.shared.image(url), self.artworkTrackID == t.id else { return }
            self.info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info
        }
    }
}
