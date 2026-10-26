import AppKit
import Testing
@testable import SopranoMixCore

struct AppListTrackerTests {
    private func app(_ key: String, _ name: String, playing: Bool) -> AudioApp {
        AudioApp(key: AppKey(rawValue: key), name: name, kind: .app, icon: .symbol("app"),
                 processObjectIDs: [1], pids: [1], isPlaying: playing)
    }

    @Test("only playing apps, apps that played and apps with a setting are listed, alphabetically")
    func listedApps() {
        var tracker = AppListTracker()
        var settings = SopranoMixSettings()
        settings.apps[AppKey(rawValue: "com.apple.Music")] = AppAudioSettings(muted: true)
        settings.apps[AppKey(rawValue: "com.default.entry")] = AppAudioSettings()

        let apps = [
            app("com.spotify.client", "Spotify", playing: true),
            app("com.apple.Music", "Music", playing: false),
            app("com.default.entry", "Default Entry", playing: false),
            app("com.apple.systemsoundserverd", "System Sounds", playing: false),
            app("wine:TEKKEN 8", "TEKKEN 8", playing: true),
            app("com.apple.Safari", "safari", playing: true),
        ]
        let listed = tracker.update(apps: apps, settings: settings)
        #expect(listed.map(\.name) == ["Music", "safari", "Spotify", "TEKKEN 8"])
    }

    @Test("an app stays listed after it stops playing while it stays connected")
    func playedStaysListed() {
        var tracker = AppListTracker()
        _ = tracker.update(apps: [app("a.b", "A", playing: true)], settings: .defaults)
        let paused = tracker.update(apps: [app("a.b", "A", playing: false)], settings: .defaults)
        #expect(paused.map(\.key.rawValue) == ["a.b"])
        #expect(tracker.played == [AppKey(rawValue: "a.b")])
    }

    @Test("a disconnected app is forgotten and must play again to be listed")
    func disconnectForgets() {
        var tracker = AppListTracker()
        _ = tracker.update(apps: [app("a.b", "A", playing: true)], settings: .defaults)
        _ = tracker.update(apps: [], settings: .defaults)
        #expect(tracker.played.isEmpty)
        let reconnected = tracker.update(apps: [app("a.b", "A", playing: false)], settings: .defaults)
        #expect(reconnected.isEmpty)
        let playingAgain = tracker.update(apps: [app("a.b", "A", playing: true)], settings: .defaults)
        #expect(playingAgain.count == 1)
    }

    @Test("an app with a setting is listed after reconnecting without playing")
    func settingKeepsListed() {
        var tracker = AppListTracker()
        var settings = SopranoMixSettings()
        settings.apps[.wine("TEKKEN 8")] = AppAudioSettings(volume: 35)
        _ = tracker.update(apps: [], settings: settings)
        let listed = tracker.update(apps: [app("wine:TEKKEN 8", "TEKKEN 8", playing: false)], settings: settings)
        #expect(listed.map(\.key) == [.wine("TEKKEN 8")])
    }
}
