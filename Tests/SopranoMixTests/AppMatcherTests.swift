import AppKit
import Testing
@testable import SopranoMixCore

struct AppMatcherTests {
    private func app(_ key: String, _ name: String) -> AudioApp {
        AudioApp(key: AppKey(rawValue: key), name: name, kind: .app, icon: .symbol("app"),
                 processObjectIDs: [1], pids: [1], isPlaying: true)
    }

    private var apps: [AudioApp] {
        [
            app("com.spotify.client", "Spotify"),
            app("wine:TEKKEN 8", "TEKKEN 8"),
            app("wine:Steam", "Steam"),
            app("com.apple.Safari", "Safari"),
            app("com.apple.SafariTechnologyPreview", "Safari Technology Preview"),
            app("de.cafe.player", "Café Player"),
            app("com.google.Chrome", "Google Chrome"),
            app("com.google.Chrome.beta", "Google Chrome Beta"),
        ]
    }

    @Test("an exact key wins over every name")
    func exactKey() {
        #expect(AppMatcher.match("wine:Steam", in: apps) == .match(app("wine:Steam", "Steam")))
        #expect(AppMatcher.match("com.google.Chrome", in: apps) == .match(app("com.google.Chrome", "Google Chrome")))
    }

    @Test("names match ignoring case and diacritics, an equal name beats prefixes")
    func equalName() {
        #expect(AppMatcher.match("tekken 8", in: apps) == .match(app("wine:TEKKEN 8", "TEKKEN 8")))
        #expect(AppMatcher.match("cafe player", in: apps) == .match(app("de.cafe.player", "Café Player")))
        #expect(AppMatcher.match("SAFARI", in: apps) == .match(app("com.apple.Safari", "Safari")))
        #expect(AppMatcher.match("google chrome", in: apps) == .match(app("com.google.Chrome", "Google Chrome")))
    }

    @Test("a unique prefix matches before substrings")
    func prefix() {
        #expect(AppMatcher.match("spot", in: apps) == .match(app("com.spotify.client", "Spotify")))
        #expect(AppMatcher.match("tek", in: apps) == .match(app("wine:TEKKEN 8", "TEKKEN 8")))
        #expect(AppMatcher.match("st", in: apps) == .match(app("wine:Steam", "Steam")))
    }

    @Test("a unique substring matches last")
    func substring() {
        #expect(AppMatcher.match("technology", in: apps) == .match(app("com.apple.SafariTechnologyPreview", "Safari Technology Preview")))
        #expect(AppMatcher.match("beta", in: apps) == .match(app("com.google.Chrome.beta", "Google Chrome Beta")))
    }

    @Test("several hits on one level are ambiguous, nothing is none")
    func ambiguousAndNone() {
        #expect(AppMatcher.match("saf", in: apps) == .ambiguous([
            app("com.apple.Safari", "Safari"),
            app("com.apple.SafariTechnologyPreview", "Safari Technology Preview"),
        ]))
        #expect(AppMatcher.match("chrome", in: apps) == .ambiguous([
            app("com.google.Chrome", "Google Chrome"),
            app("com.google.Chrome.beta", "Google Chrome Beta"),
        ]))
        #expect(AppMatcher.match("discord", in: apps) == AppMatcher.Result.none)
        #expect(AppMatcher.match("  ", in: apps) == AppMatcher.Result.none)
    }

    @Test("bundle ids, Wine and executable keys look like keys, plain names do not")
    func keyLike() {
        #expect(AppMatcher.isKeyLike("com.spotify.client"))
        #expect(AppMatcher.isKeyLike("wine:TEKKEN 8"))
        #expect(AppMatcher.isKeyLike("exe:afplay"))
        #expect(!AppMatcher.isKeyLike("Spotify"))
        #expect(!AppMatcher.isKeyLike("TEKKEN 8"))
    }
}
