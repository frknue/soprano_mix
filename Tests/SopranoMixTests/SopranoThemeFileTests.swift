import AppKit
import Testing
@testable import SopranoMixCore

struct SopranoThemeFileTests {
    private let known: Set<String> = ["folio", "folio-paper", "folio-ink", "nord"]

    @Test("Soprano's theme and appearance are read from JSONC, comments and trailing commas included")
    func readsBothKeys() {
        let text = """
        // Soprano settings
        {
          "theme": "nord", /* pinned */
          "appearance": "dark",
          "fontSize": 13,
        }
        """
        #expect(SopranoThemeFile.parse(text: text, knownThemeIDs: known) == SopranoThemeFile(themeID: "nord", appearance: .dark))
    }

    @Test("Missing keys give folio and the system appearance")
    func missingKeysGiveDefaults() {
        #expect(SopranoThemeFile.parse(text: "{}", knownThemeIDs: known) == SopranoThemeFile(themeID: "folio", appearance: .system))
        #expect(SopranoThemeFile.parse(text: #"{ "appearance": "light" }"#, knownThemeIDs: known).themeID == "folio")
    }

    @Test("An unknown theme id, a bad appearance or a broken document falls back per key")
    func badValuesFallBack() {
        let unknown = SopranoThemeFile.parse(text: #"{ "theme": "mission-control", "appearance": "dusk" }"#, knownThemeIDs: known)
        #expect(unknown == SopranoThemeFile())
        let wrongTypes = SopranoThemeFile.parse(text: #"{ "theme": 3, "appearance": { "mode": "dark" } }"#, knownThemeIDs: known)
        #expect(wrongTypes == SopranoThemeFile())
        #expect(SopranoThemeFile.parse(text: #"{ "theme": "#, knownThemeIDs: known) == SopranoThemeFile())
    }
}
