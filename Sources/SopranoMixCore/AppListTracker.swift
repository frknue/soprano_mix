import Foundation

/// Which connected apps the panel lists. Core Audio keeps a process object for every app
/// that ever opened audio, so only apps that play, played since they connected, or have
/// a setting are shown.
public struct AppListTracker: Sendable {
    public init() {}

    /// Connected apps that played since they connected.
    public private(set) var played: Set<AppKey> = []

    /// The apps the panel lists, alphabetical (`localizedStandardCompare`, then key):
    /// every connected app that is playing, played since it connected, or has a
    /// non-default setting. An app that disconnects is forgotten (it must play again
    /// to be listed after it reconnects, unless it has a setting).
    public mutating func update(apps: [AudioApp], settings: SopranoMixSettings) -> [AudioApp] {
        let connected = Set(apps.map(\.key))
        played.formIntersection(connected)
        played.formUnion(apps.filter(\.isPlaying).map(\.key))
        return apps
            .filter { played.contains($0.key) || !settings.audio(for: $0.key).isDefault }
            .sorted(by: AudioAppResolver.isOrderedBefore)
    }
}
