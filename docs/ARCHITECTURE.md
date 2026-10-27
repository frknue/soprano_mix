# Soprano Mix architecture

Soprano Mix is a per-app audio mixer for macOS in the Soprano family: a copy of
[SoundSource](https://rogueamoeba.com/soundsource/) (every app playing audio with its own
volume up to 400 %, mute and output device; the system's output, input and sound-effects
devices; level meters; volume keys for outputs without hardware volume) drawn in Soprano's
Folio chrome (Paper light, Ink dark). Swift 6 + programmatic AppKit, SPM, macOS 14.2+,
menu-bar app (no Dock icon). Built on Core Audio process taps: no audio driver, no kernel
extension. Behavior is reimplemented from SoundSource's documented behavior; no
SoundSource code is used.

## Toolchain

Homebrew Swift with the Command Line Tools SDK. Xcode's newer SDK breaks Homebrew Swift,
so always pin `DEVELOPER_DIR`:

```bash
export DEVELOPER_DIR=/Library/Developer/CommandLineTools PATH="/opt/homebrew/opt/swift/bin:$PATH"
swift build
swift test
```

The `ld: warning: building for macOS-14.2 …` link warnings are expected.

## Identity

| What | Value |
|---|---|
| Product | Soprano Mix (`/Applications/Soprano Mix.app`) |
| Bundle id | `com.soprano.mix`; dev build `com.soprano.mix.dev` (`Soprano Mix Dev.app`) |
| Targets | `SopranoMixCore` (library), `SopranoMix` (executable), `SopranoMixTests` |
| Minimum macOS | 14.2 (`AudioHardwareCreateProcessTap`) |
| Settings | `~/.config/soprano-mix/settings.json` (`$XDG_CONFIG_HOME/soprano-mix/` when set); `SOPRANO_MIX_CONFIG` overrides the path |
| CLI port | CFMessagePort `<bundle id>.cli` |
| Info.plist | `NSAudioCaptureUsageDescription` (the System Audio Recording prompt), `LSUIElement` |
| Signing | Soprano's shared "Soprano Local Development" identity, so macOS keeps the System Audio Recording and Accessibility grants across rebuilds |

## How per-app audio works

Core Audio lists every client process (`kAudioHardwarePropertyProcessObjectList`), with
its pid, bundle id and whether it is playing (`kAudioProcessPropertyIsRunningOutput`).
Reading that list needs no permission. Changing an app's audio needs a **route**:

1. A process tap on the app's process objects: `CATapDescription(stereoMixdownOfProcesses:)`,
   `isPrivate = true`, `muteBehavior = .mutedWhenTapped`
   (`AudioHardwareCreateProcessTap`). While Soprano Mix reads the tap, the app's own
   output is silent.
2. A private aggregate device (`AudioHardwareCreateAggregateDevice`) whose main and only
   sub-device is the target output device and whose tap list holds the tap (drift
   compensation on).
3. An IOProc on the aggregate (`AudioDeviceCreateIOProcIDWithBlock`) that copies the
   tapped stereo audio to the output device's first two channels through a `GainStage`
   (gain ramp, limiter above 100 %).

Apps without a non-default setting get **no** route: their audio is untouched, with no
added latency and no permission needed. A route exists exactly while the app has a
non-default setting (volume ≠ 100 %, muted, or another output) and at least one process
object. Taps and private aggregates belong to the Soprano Mix process: when it quits or
crashes, Core Audio destroys them and every app plays normally again.

**Meters** use the same pipeline with `muteBehavior = .unmuted` and no output writes,
only for playing apps without a route, only while the panel is visible and
`panel.meters` is on.

**Software volume** (outputs without hardware volume: HDMI, DisplayPort, some USB DACs):
one master route with a tap on that output's stream 0
(`CATapDescription(excludingProcesses:deviceUID:stream:)`, excluding Soprano Mix's own
process object plus every process that has its own route), muted when tapped and
replayed channel for channel at the software gain. App routes to that device multiply
the software gain into their own gain. Soprano Mix's own process is always excluded, so
its replayed audio is never captured again; when its process object cannot be found the
master route fails instead of being built.

**Permission**: reading a tap needs System Audio Recording (`kTCCServiceAudioCapture`).
A tap read without it delivers silence, which with `.mutedWhenTapped` would silence the
app, so **no route is created unless capture is granted**. The status comes from the
private `TCCAccessPreflight` and the prompt from `TCCAccessRequest` (TCC.framework,
through `dlsym`); without them the status is `unknown` and routes are attempted.

## Modules and ownership

| Path | Module | Contents |
|---|---|---|
| `Sources/SopranoMixCore/` | Core | Pure logic, Foundation + CoreGraphics only, no AppKit, no Core Audio: models, settings, keys, app grouping (CrossOver/Wine included), app list, route planning, volume law, DSP, meters, PE icons, CLI messages and app matching. Everything `public`. |
| `Sources/SopranoMixCore/Vendored/JSONCText.swift` | — | Copied from Soprano by `scripts/sync-soprano-chrome.sh`. **Never edit.** |
| `Sources/SopranoMix/Vendored/` | — | Soprano chrome (Chrome, Theme, NSColor+Hex, AppVersion), copied by the sync script. **Never edit.** |
| `Sources/SopranoMix/System/` | System | The only code that touches Core Audio, taps, aggregates, TCC, CGEventTap, Carbon hotkeys, `proc_pidpath`/`sysctl` and private symbols (plus the System-owned `App/ScanCommand.swift` and `App/SelfTestCommand.swift`). |
| `Sources/SopranoMix/Mixer/` | Mixer | `MixerController` (state, planning, intents, CLI, volume keys) and `MixerModelBuilder`. |
| `Sources/SopranoMix/Panel/` | Panel | The menu-bar panel (`MixPanelWindow`), its rows and controls, the volume HUD. |
| `Sources/SopranoMix/App/`, `Shell/` | Shell | `main.swift`, app delegate (composition root), menu bar, login item, settings file/center, theme center, permissions + window, CLI server/client. (`App/ScanCommand.swift` and `App/SelfTestCommand.swift` belong to System.) |
| `Sources/SopranoMix/Fixtures/` | Fixtures | Fake processes, devices, router, icons and the `snapshot` harness. |

### Contract files

Written first; the shared interfaces every module codes against. Change them only
together with every consumer.

- `Sources/SopranoMixCore/Models.swift` — `AppKey`, `RunningAppInfo`, `AudioProcessFacts`, `AppKind`, `IconSource`, `AppIdentity`, `AudioApp`, `DeviceTransport`, `DeviceRole`, `DeviceScope`, `AudioDevice`, `DeviceSnapshot`, `StereoLevel`, `RouteLevels`, `TapMode`, `RouteSpec`, `MasterRouteSpec`, `RoutePlan`, `VolumeKey`, `VolumeKeyEvent`, `CaptureStatus`.
- `Sources/SopranoMixCore/Keys.swift` — `ModifierSet`, `NamedKey` (+ key codes), `KeySpec` (Soprano Tab's, without `KeyEvent`).
- `Sources/SopranoMixCore/Settings.swift` — every settings type with its default, `ConfigIssue`, `SettingsResolution`.
- `Sources/SopranoMixCore/CLIProtocol.swift` — `CLIRequest`, `CLIApp`, `CLIDevice`, `CLIResponse`.
- `Sources/SopranoMix/System/SystemContracts.swift` — `AudioProcessSource`, `AudioDeviceControlling`, `RouteStatus`, `AudioRouting`, `AppIconProviding`, `EventTapError`, `VolumeKeyTapping`, `PanelHotkeyRegistering`.
- `Sources/SopranoMix/Mixer/MixerContracts.swift` — `DeviceMenuItem`, `SampleRateMenu`, `DeviceSectionModel`, `AppRowStatus`, `AppRowModel`, `PanelBanner`, `MixPanelModel`, `PanelIntent`, `MixPanelPresenting`, `VolumeHUDModel`, `VolumeHUDPresenting`, `MixerEnvironment`.

### File ownership

| Owner | Files |
|---|---|
| Infra | `Package.swift`, `.gitignore`, `LICENSE`, `Support/Info.plist`, `Support/SopranoMix.entitlements`, `scripts/*.sh`, `scripts/render-app-icon.swift`, `Sources/SopranoMix/Resources/`, `Sources/SopranoMix/Vendored/`, `Sources/SopranoMixCore/Vendored/` |
| Core | `Core/KeyParsing.swift`, `Core/SettingsResolver.swift`, `Core/SettingsTemplate.swift`, `Core/SettingsEditor.swift`, `Core/SopranoThemeFile.swift`, `Core/WinePath.swift`, `Core/AudioAppResolver.swift`, `Core/AppListTracker.swift`, `Core/RoutePlanner.swift`, `Core/VolumeLaw.swift`, `Core/GainStage.swift`, `Core/MeterBallistics.swift`, `Core/PEIconExtractor.swift`, `Core/AppMatcher.swift`; tests `KeyParsingTests`, `SettingsResolverTests`, `SettingsTemplateTests`, `SettingsEditorTests`, `SopranoThemeFileTests`, `WinePathTests`, `AudioAppResolverTests`, `AppListTrackerTests`, `RoutePlannerTests`, `VolumeLawTests`, `GainStageTests`, `MeterBallisticsTests`, `PEIconExtractorTests`, `AppMatcherTests` |
| System | `System/PrivateAPIs.swift`, `System/CoreAudioProperties.swift`, `System/ProcessInspector.swift`, `System/LiveAudioProcessSource.swift`, `System/LiveAudioDevices.swift`, `System/LiveAudioRouter.swift`, `System/AudioRoute.swift`, `System/RouteParameters.swift`, `System/LiveAppIconProvider.swift`, `System/VolumeKeyMonitor.swift`, `System/CarbonPanelHotkey.swift`, `System/AlertVolume.swift`, `App/ScanCommand.swift`, `App/SelfTestCommand.swift`; tests `ProcessInspectorTests`, `RouteParametersTests`, `RouteBufferLayoutTests`, `VolumeKeyConversionTests`, `CarbonPanelHotkeyTests` |
| Mixer | `Mixer/MixerController.swift`, `Mixer/MixerModelBuilder.swift`; tests `MixerControllerTests`, `MixerModelBuilderTests`, `MixerSettingsIntegrationTests`, `MixerTestSupport` |
| Panel | `Panel/MixPanelWindow.swift`, `Panel/MixPanelContentView.swift`, `Panel/DeviceSectionView.swift`, `Panel/AppRowView.swift`, `Panel/MixSlider.swift`, `Panel/LevelMeterView.swift`, `Panel/DeviceMenuButton.swift`, `Panel/VolumeHUD.swift`; tests `MixSliderTests`, `MixPanelWindowTests`, `VolumeHUDTests` |
| Fixtures | `Fixtures/FixtureScenarios.swift`, `Fixtures/FixtureProcessSource.swift`, `Fixtures/FixtureDevices.swift`, `Fixtures/RecordingRouter.swift`, `Fixtures/FixtureIcons.swift`, `Fixtures/SnapshotCommand.swift`; tests `FixtureScenarioTests`, `SnapshotCommandTests` |
| App shell | `main.swift`, `App/AppDelegate.swift`, `App/MenuBarController.swift`, `App/MenuBarGlyph.swift`, `App/LoginItem.swift`, `App/CLIServer.swift`, `App/CLIClient.swift`, `Shell/SettingsFile.swift`, `Shell/SettingsCenter.swift`, `Shell/ThemeCenter.swift`, `Shell/Permissions.swift`, `Shell/PermissionsWindowController.swift`; tests `SettingsCenterTests`, `ThemeCenterTests`, `CLIRoundTripTests`, `PermissionsWindowTests`, `MenuBarGlyphTests` |

(`Core/` = `Sources/SopranoMixCore/`, `System/` etc. = `Sources/SopranoMix/…`, tests in
`Tests/SopranoMixTests/<Name>.swift`.)

## Core APIs

Signatures are binding: other modules call them exactly like this. Model types are in
`Models.swift`, settings types in `Settings.swift`.

### Keys (`Keys.swift`, `KeyParsing.swift`)

Soprano Tab's `ModifierSet`, `NamedKey`, `KeySpec` and their `settingsText` parsing,
copied; Mix uses them for `panel.hotkey` only.

```swift
extension ModifierSet {
    public init?(settingsText: String)   // "control+option", "⌃⌥", case-insensitive
    public var settingsText: String { get }
    public var symbols: String { get }   // "⌃⌥⇧⌘", "fn" last
}
extension KeySpec {
    public init?(settingsText: String)
    public var settingsText: String { get }
    public var symbol: String { get }
}
extension PanelHotkey {
    /// "control+option+m": modifiers (at least one of control, option, command) joined
    /// with "+", the last part a `KeySpec`. nil otherwise.
    public init?(settingsText: String)
    public var settingsText: String { get }
    /// "⌃⌥M".
    public var symbols: String { get }
}
```

### Settings (`SettingsResolver.swift`, `SettingsTemplate.swift`, `SettingsEditor.swift`, `SopranoThemeFile.swift`)

```swift
public enum SettingsResolver {
    /// JSONC (comments, trailing commas) → settings over the defaults. A document that is
    /// not a JSON object gives `settings == nil` and one `.error` issue with its line.
    /// Every bad value is a `.warning` and keeps its default; unknown keys warn.
    public static func resolve(text: String, knownThemeIDs: Set<String>) -> SettingsResolution
}
public enum SettingsTemplate {
    /// The commented settings.json written on first launch. Resolves to `.defaults` with
    /// no issues; documents every key with its default and allowed values.
    public static let text: String
}
public enum SettingsEditor {
    /// Sets `value` (Bool, Int, Double, String, [Any], [String: Any], NSNull) at `path`,
    /// creating missing objects and keeping comments and key order (vendored `JSONCText`).
    public static func setting(_ value: Any, at path: [String], in text: String) throws -> String
}
public struct SopranoThemeFile { /* Soprano Tab's, unchanged: theme + appearance of ~/.config/soprano/settings.json */ }
```

settings.json (every key optional):

```jsonc
{
  "theme": "soprano",                  // "soprano" (follow Soprano), "folio" (follow macOS) or a Soprano theme id
  "apps": {                            // per app; written by the panel and the CLI
    // key: the bundle id; "wine:<Name>" for CrossOver/Wine games and programs;
    // "exe:<name>" for programs without a bundle (afplay, mpv)
    "com.spotify.client": { "volume": 60 },
    "wine:TEKKEN 8": { "volume": 35, "muted": false, "output": "default" }
    // volume 0–400 (percent, 100 = unchanged); muted; output = device UID or name, "default" follows the system output
  },
  "outputs": {                         // software volume of outputs without hardware volume
    "Odyssey G91F": { "volume": 50, "muted": false }   // key: device UID or name; volume 0–100
  },
  "panel": { "hotkey": null, "meters": true },          // hotkey e.g. "control+option+m"
  "volumeKeys": { "anyOutput": true, "hud": true },     // volume keys for outputs without hardware volume
  "audio": { "bufferFrames": 256, "limiter": true },    // route IO buffer (32–4096 frames); limiter above 100 %
  "app": { "startAtLogin": true, "menuBarIcon": "outlined" }   // outlined | filled | hidden
}
```

Resolution rules:
- `apps` keys are taken as given (`AppKey(rawValue:)`); an empty key warns and is dropped.
  `volume` is a JSON number clamped to `VolumeLaw.appRange` with a warning; `output` is a
  non-empty string, `"default"` (any case) or `null` meaning nil.
- `outputs` keys are non-empty strings; `volume` clamped to `VolumeLaw.outputRange`.
- `panel.hotkey` is null or a string parsing with `PanelHotkey(settingsText:)`, else
  warning + nil.
- `audio.bufferFrames` is an integer clamped to `AudioEngineSettings.bufferFramesRange`.
- `theme` must be `soprano`, `folio` or a known theme id, else warning + default.
- Integers accept JSON numbers with no fractional part; numbers accept any JSON number;
  booleans only JSON booleans.

### Grouping processes into apps (`WinePath.swift`, `AudioAppResolver.swift`)

```swift
public enum WinePath {
    /// `^[A-Za-z]:\\` — what Wine (CrossOver, Whisky, plain Wine) puts in a process's
    /// argv[0] (and sometimes its executable path).
    public static func isWindowsPath(_ path: String) -> Bool
    /// The app's display name from a Windows executable path, case kept:
    /// …\steamapps\common\<Game>\… → "<Game>";
    /// …\Program Files[ (x86)]\Steam\… → "Steam";
    /// …\Program Files[ (x86)]\<Folder>\… → "<Folder>" (not "Common Files");
    /// …\GOG Games\<Game>\… and …\Epic Games\<Game>\… → "<Game>";
    /// else the file name without ".exe" (any case).
    public static func appName(forWindowsPath path: String) -> String
    /// The macOS path of a Windows path inside a Wine prefix: "C:\a\b.exe" →
    /// "<prefix>/drive_c/a/b.exe"; "Z:\Users\x" → "/Users/x"; other drive letters →
    /// "<prefix>/dosdevices/<letter>:/…" (lowercase letter). nil when not a Windows path.
    public static func macPath(forWindowsPath path: String, prefix: String) -> String?
}

public enum AudioAppResolver {
    /// One process's identity; nil for Soprano Mix itself (`pid == ownPID`).
    public static func identity(for process: AudioProcessFacts, ownPID: Int32) -> AppIdentity?
    /// Every process grouped by identity key, sorted by name
    /// (`localizedStandardCompare`), then key.
    public static func apps(from processes: [AudioProcessFacts], ownPID: Int32) -> [AudioApp]
    /// Friendly names of system processes that play audio, by bundle id or executable name.
    public static let systemNames: [String: String]
}
```

`identity` rules, first match wins:
1. `pid == ownPID` → nil.
2. **Wine**: the first of `arguments.first`, `executablePath` that `WinePath.isWindowsPath`
   → key `.wine(WinePath.appName(…))`, kind `.wine`, icon
   `.windowsExecutable(windowsPath:wineprefix:)`. This rule comes before the bundle rules
   because Wine's loader binary sits inside `CrossOver.app`; a game must not fold into
   CrossOver.
3. **Unbundled program**: `bundleID == nil` and `enclosingApp == nil` → key
   `.executable(name)` with name = last path component of `executablePath` (else of
   `arguments.first`, else `"pid <pid>"`), kind `.executable`, icon `.executable(path:)`.
   Unbundled programs never fold into the app that launched them (`afplay` started from a
   terminal is "afplay", not the terminal).
   Wine processes whose argv cannot be read (`bundleID ==
   com.codeweavers.CrossOver.wineloader`) skip to rule 7 here ("CrossOver (Windows)"),
   so they never fold into the CrossOver launcher.
4. **Responsible app**: `responsible != nil` and `responsible.pid != pid` → that app's
   bundle id, name and icon (`.bundle(path:)` when it has a path, else
   `.runningApp(pid:)`), kind `.app`. Folds browser renderers, WebKit's GPU process,
   Electron helpers and XPC services into their app.
5. **The app itself**: `ownApp != nil` → its bundle id, name, icon, kind `.app`, unless
   the process lives in an `.appex` or `.xpc` bundle inside another app (macOS reports
   app extensions as running apps too): those go on to rule 6. A nested real `.app`
   (Simulator inside Xcode) stays itself.
6. **Inside an app bundle**: `enclosingApp != nil` → that bundle's id, name, icon, kind `.app`.
7. **Bundled system process**: key `.bundle(bundleID)`, name = `systemNames[bundleID]` ??
   `systemNames[executable name]` ?? the executable name ?? `bundleID`, kind `.system`,
   icon `.symbol("speaker.wave.2")` (`"bell"` for System Sounds, `"waveform"` for Siri).

Every name drops invisible bidi formatting marks (U+200E/F, U+061C, U+202A–E,
U+2066–9): WhatsApp's bundle name starts with U+200E, which would otherwise break sorting
and CLI name matching.

`systemNames`: `systemsoundserverd` → "System Sounds", `com.apple.assistantd`,
`com.apple.CoreSpeech`, `com.apple.corespeechd_system` → "Siri",
`com.apple.speech.speechsynthesisd` → "Spoken Content", `com.apple.avconferenced` →
"FaceTime", `com.apple.accessibility.heard` → "Hearing",
`com.codeweavers.CrossOver.wineloader` → "CrossOver (Windows)" (only reached when a Wine
process's argv cannot be read; its executable path is then a temporary copy). Names
served by several processes share one key: Siri's three are `com.apple.assistantd`.

`apps`: group by key. The group's name, kind and icon come from its primary process: the
one whose identity came from rule 5 (the app itself), else the lowest pid.
`processObjectIDs` and `pids` ascending and unique; `isPlaying` = any process
`isRunningOutput`.

### App list (`AppListTracker.swift`)

```swift
public struct AppListTracker: Sendable {
    public init()
    /// The apps the panel lists, alphabetical (`localizedStandardCompare`, then key):
    /// every connected app that is playing, played since it connected, or has a
    /// non-default setting. An app that disconnects is forgotten (it must play again
    /// to be listed after it reconnects, unless it has a setting).
    public mutating func update(apps: [AudioApp], settings: SopranoMixSettings) -> [AudioApp]
    public private(set) var played: Set<AppKey>
}
```

### Route planning (`RoutePlanner.swift`)

```swift
public enum RoutePlanner {
    public static func plan(
        apps: [AudioApp],                 // every connected app, not just the listed ones
        settings: SopranoMixSettings,     // includes the controller's unsaved overrides
        devices: DeviceSnapshot,
        meteredKeys: Set<AppKey>,         // apps showing a meter now (panel visible, meters on)
        canCapture: Bool,
        heldKeys: Set<AppKey> = [],       // apps whose volume change is still in progress
        heldOutputUIDs: Set<String> = []  // outputs whose software volume change is in progress
    ) -> RoutePlan
    /// The software gain of an output: 1 with hardware volume (`outputVolume != nil`),
    /// else `outputs[uid] ?? outputs[name]` through `VolumeLaw.gain`, 0 when muted.
    public static func softwareGain(for device: AudioDevice, settings: SopranoMixSettings) -> Float
}
```

Rules:
- `canCapture == false` or `devices.defaultOutputUID == nil` → empty plan.
- Target device of an app: `devices.output(matching: settings.audio(for: key).output)`
  (UID, then case-insensitive name, among devices with output channels), else the
  default output.
- **Replace route** for an app with ≥ 1 process object when its volume ≠ 100, it is
  muted, or its target ≠ the default output: gain = muted ? 0 :
  `VolumeLaw.gain(percent: volume) × softwareGain(target)`, limiter =
  `settings.audio.limiter && volume > 100`.
- **Meter route** for an app in `meteredKeys` that is playing and has no replace route:
  gain 1, target the default output, no limiter.
- **Master**: when the default output has no hardware volume and its software gain ≠ 1
  → `MasterRouteSpec` on it, gain = its software gain, excluding every process object
  of every replace route.
- **Held**: an app in `heldKeys` keeps its replace route even at default settings (gain
  from its settings, 1 at 100 %), and an output in `heldOutputUIDs` keeps the master route
  at unity, so a drag through 100 % never tears a tap down mid-gesture; the route goes
  once the change is final.
- Every spec carries `settings.audio.bufferFrames`. Routes are sorted by key.

### Volume, DSP, meters (`VolumeLaw.swift`, `GainStage.swift`, `MeterBallistics.swift`)

```swift
public enum VolumeLaw {
    public static let appRange: ClosedRange<Double>      // 0...400
    public static let outputRange: ClosedRange<Double>   // 0...100
    /// Loudness-proportional: 50 % sounds half as loud (−10 dB), 200 % twice (+10 dB),
    /// 400 % +20 dB. gain = (percent / 100) ^ (log2(10) / 2); 0 → 0.
    public static func gain(percent: Double) -> Float
    /// nil at 0.
    public static func decibels(percent: Double) -> Double?
    /// "60 %", "0 %", "250 %" (rounded).
    public static func text(percent: Double) -> String
    /// One volume-key step on the 16-step grid (64 with `fine`), snapping to the grid
    /// first, clamped to `outputRange`.
    public static func step(_ percent: Double, up: Bool, fine: Bool) -> Double
}

public struct GainStage: Sendable {
    /// −0.3 dBFS.
    public static let ceiling: Float
    public init(sampleRate: Double, gain: Float, releaseSeconds: Double = 0.08)
    public private(set) var currentGain: Float
    /// In place on planar stereo; real-time safe (no allocation, no locks). Ramps
    /// linearly from `currentGain` to `targetGain` over the buffer. With `limiter`, a
    /// sample whose |x × g| would exceed `ceiling` pulls the limiter gain down at once;
    /// it recovers exponentially over `releaseSeconds`; output never exceeds `ceiling`.
    /// Returns the output peaks.
    public mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                                 frames: Int, targetGain: Float, limiter: Bool) -> StereoLevel
    /// The input peaks of a planar stereo buffer (for meters before gain).
    public static func peaks(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) -> StereoLevel
}

public enum MeterScale {
    public static let floorDecibels: Double            // −60
    /// 0 at or below the floor, 1 at 0 dBFS and above, linear in dB between.
    public static func position(forAmplitude amplitude: Float) -> Double
}
public struct MeterBallistics: Sendable {
    public init(fallDecibelsPerSecond: Double = 24)
    /// Rises at once to a higher peak, falls at the given rate; returns a `MeterScale` position.
    public mutating func update(peak: Float, elapsed: TimeInterval) -> Double
}
```

### Icons and CLI matching (`PEIconExtractor.swift`, `AppMatcher.swift`)

```swift
public enum PEIconExtractor {
    /// The first RT_GROUP_ICON of a Windows PE (.exe/.dll) assembled as .ico file data
    /// (every image of the group); nil when absent or malformed. Never traps on bad input.
    public static func icoData(fromPE data: Data) -> Data?
}
public enum AppMatcher {
    public enum Result: Equatable, Sendable { case match(AudioApp), none, ambiguous([AudioApp]) }
    /// Exact key; then name equal (case- and diacritic-insensitive); then name prefix;
    /// then name substring. A level with more than one hit is `.ambiguous`.
    public static func match(_ query: String, in apps: [AudioApp]) -> Result
    /// True when `query` looks like a settings key (contains "." or starts with "wine:"
    /// or "exe:"), so the CLI may set it while the app is not running.
    public static func isKeyLike(_ query: String) -> Bool
}
```

## System APIs

```swift
@MainActor final class LiveAudioProcessSource: AudioProcessSource { init() }
@MainActor final class LiveAudioDevices: AudioDeviceControlling { init() }
@MainActor final class LiveAudioRouter: AudioRouting { init() }
@MainActor final class LiveAppIconProvider: AppIconProviding { init() }
@MainActor final class VolumeKeyMonitor: VolumeKeyTapping { init() }
@MainActor final class CarbonPanelHotkey: PanelHotkeyRegistering { init() }
enum AlertVolume { static func get() -> Double?; static func set(_ percent: Double) }   // 0...100
enum PrivateAPIs {
    static func responsiblePID(for pid: pid_t) -> pid_t?           // responsibility_get_pid_responsible_for_pid
    static func audioCapturePreflight() -> CaptureStatus           // TCCAccessPreflight
    static func requestAudioCapture(_ done: @escaping @Sendable (Bool) -> Void) -> Bool  // false: unavailable
}
enum ProcessInspector {   // pure parsing is testable
    static func executablePath(pid: pid_t) -> String?              // proc_pidpath
    static func arguments(pid: pid_t) -> (arguments: [String], environment: [String: String])?  // KERN_PROCARGS2
    static func parseProcArgs(_ data: Data) -> (arguments: [String], environment: [String: String])?
    static func outermostAppBundle(containing path: String) -> String?   // ".app" closest to "/"
}
```

**Process catalog** (`LiveAudioProcessSource`): `kAudioHardwarePropertyProcessObjectList`
plus, per process object, `kAudioProcessPropertyPID`, `…BundleID`, `…IsRunningOutput`,
`…IsRunningInput`; `ProcessInspector` for the executable path, argv and (for Wine
processes only) `WINEPREFIX`; `PrivateAPIs.responsiblePID` → `NSRunningApplication` for
`responsible` (only when it has a bundle id and differs from the pid);
`NSRunningApplication(processIdentifier:)` for `ownApp` (bundle id required); the
outermost `.app` around the executable for `enclosingApp` (its `CFBundleIdentifier`,
display name, path). Listeners: the process list on the system object, and on every
process object (added and removed as objects come and go) `IsRunningOutput`,
`IsRunningInput`, `IsRunning` and `Devices`, each re-reading both running flags. Core
Audio (measured on macOS 27) never notifies `IsRunningOutput`/`IsRunningInput`; it
notifies `IsRunning` and `Devices` when a process starts or stops IO. Listening to the
running flags alone left an app that connects first and plays a moment later "not
playing", so it was listed only after a relaunch. Static facts are cached per (object
id, pid). Changes are coalesced (one `onChange` per main run-loop turn).

**Devices** (`LiveAudioDevices`): `kAudioHardwarePropertyDevices` without hidden devices
(`kAudioDevicePropertyIsHidden`) and without Soprano Mix's own aggregates (UID prefix
`com.soprano.mix.`); per device the UID, name, transport, stream channel counts per
scope, `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (settable → hardware
volume), `kAudioDevicePropertyMute`, `…VirtualMainBalance`, nominal and available sample
rates. Defaults from `kAudioHardwarePropertyDefaultOutputDevice`, `…DefaultInputDevice`,
`…DefaultSystemOutputDevice`. Listeners on the device list, the three defaults and each
device's volume, mute, balance, sample rate and streams; coalesced `onChange`. Setters
write the same properties; failures are logged, never fatal.

**Router** (`LiveAudioRouter`): `apply(_ plan:)` diffs against the live routes by key.
Same target device, mode and buffer size → update in place: gain and limiter through
`RouteParameters` (lock-free for the IO thread), the process list by setting
`kAudioTapPropertyDescription` (rebuild if that fails). Anything else → rebuild: the old
route ramps to gain 0, the new one is built and started, then the old one is torn down,
so the app is never heard unprocessed in between. Routes no longer planned are stopped
and destroyed (IOProc stop, destroy IOProc, destroy aggregate, destroy tap, in that
order). A failed route whose configuration is unchanged only takes new parameters; it is
rebuilt when its configuration changes or on a plan change at least 2 s after its last
attempt. Each plan runs as one batch on one serial queue off the main actor, ordered so
no process is ever unprocessed: master changes that only shrink its excluded set,
removals, app builds and updates, then master changes that grow it. Statuses
(`starting`, `running`, `failed(reason)`) publish back on the main actor. The
aggregate's IO buffer is set to `bufferFrames`; only the tap's input stream(s) are
enabled for the IOProc (`kAudioDevicePropertyIOProcStreamUsage`), so the output
device's own microphone is never opened. Listeners on the aggregate's stream
configuration and the tap's format rebuild the route when the layout really changes;
until then the IOProc renders silence rather than read a wrong buffer.

**IOProc** (`AudioRoute`): real-time safe — no allocation, no locks except
`os_unfair_lock_trylock`, no Objective-C or Swift runtime calls that may allocate. Per
cycle: read the tap stream(s) (the aggregate's last input buffers; interleaved or planar
Float32 per `kAudioTapPropertyFormat`) into preallocated planar scratch, run
`GainStage.process`, write L/R to the output device's first two channels (mono output:
(L+R)/2; other channels zeroed). Meter mode writes nothing. Records input and output
peaks (max since the last `takeLevels`).

**Master** route: a tap on the output's stream 0 (see "Software volume"), copied channel
for channel with a ramped gain (no limiter: the gain never exceeds 1); its own process
object is found with `kAudioHardwarePropertyTranslatePIDToProcessObject` for `getpid()`.

**Icons** (`LiveAppIconProvider`): `.bundle` → `NSWorkspace.icon(forFile:)`;
`.runningApp` → `NSRunningApplication.icon`; `.windowsExecutable` → the exe's icon via
`PEIconExtractor` (path from `WinePath.macPath` with the process's `WINEPREFIX`, else the
first existing match in every bottle of CrossOver's `BottleDir` preference (bottles may
live on another volume), of `~/Library/Application Support/CrossOver/Bottles/*` and of
`~/.wine`), else CrossOver's app icon, else the generic application icon; `.executable`
→ `NSWorkspace.icon(forFile:)`, else the generic executable icon; `.symbol` → the SF
Symbol as a template image, which the panel draws on a `glyphTile` square. Cached by key.

**Volume keys** (`VolumeKeyMonitor`): a `CGEventTap` (session, head, default) for
`NX_SYSDEFINED` (type 14) events; subtype 8 with key codes `NX_KEYTYPE_SOUND_UP` (0),
`…_DOWN` (1), `…_MUTE` (7) → `VolumeKeyEvent` (down/up, repeat, `fine` = option+shift
held); the handler returning true consumes the event. Re-enables itself after a timeout.
`start` throws `EventTapError.accessibilityDenied` without Accessibility.

**Hotkey** (`CarbonPanelHotkey`): one Carbon `RegisterEventHotKey` (no Accessibility needed);
character keys resolve to key codes on the current layout, re-registered when the input
source changes (Soprano Cast's `CarbonHotkeys`, reduced to one combo).

## Mixer

```swift
@MainActor final class MixerController {
    init(processes: AudioProcessSource, devices: AudioDeviceControlling, router: AudioRouting,
         icons: AppIconProviding, panel: MixPanelPresenting, hud: VolumeHUDPresenting,
         environment: MixerEnvironment)
    func start()
    private(set) var apps: [AudioApp]          // connected
    private(set) var listedApps: [AudioApp]    // what the panel shows
    private(set) var plan: RoutePlan
    var isPanelVisible: Bool { get }
    func togglePanel(anchor: NSRect?)
    func showPanel(anchor: NSRect?)
    func hidePanel()
    func handle(_ intent: PanelIntent)
    /// True consumes the key.
    func handleVolumeKey(_ event: VolumeKeyEvent) -> Bool
    func handle(_ request: CLIRequest) -> CLIResponse
    func settingsDidChange()
    func permissionDidChange()
    /// Writes every pending change now (quit).
    func flushPendingSettings()
    /// One meter frame now (the snapshot harness; the panel's 30 Hz timer otherwise).
    func tickMeters()
}
enum MixerModelBuilder {
    static func model(listedApps: [AudioApp], settings: SopranoMixSettings, devices: DeviceSnapshot,
                      statuses: [AppKey: RouteStatus], capture: CaptureStatus,
                      settingsIssueCount: Int, alertVolume: Double?,
                      icons: (AudioApp) -> NSImage) -> MixPanelModel
}
```

Controller behavior:
- `start()`: subscribes to `processes.onChange`, `devices.onChange`,
  `router.onStatusChange`, `panel.onIntent`, `panel.onVisibilityChange`; starts the
  source and devices; first refresh.
- **Refresh** (any change): `apps = AudioAppResolver.apps(from:ownPID:)`;
  `listedApps = tracker.update(apps:settings:)`; `plan = RoutePlanner.plan(…)` with the
  effective settings (file settings plus unsaved overrides), `meteredKeys` = listed
  playing apps while the panel is visible and `panel.meters`, and `canCapture` =
  `environment.captureStatus().allowsRoutes`; `router.apply(plan)`
  only when the plan changed; when visible, `panel.update(model:theme:)`.
- **Overrides**: an intent changes an in-memory override at once (re-plan, gain applied
  within one IO cycle), and persists through `environment.writeSetting` when `final`
  (mouse up, menu choice, key up, CLI) or 0.5 s after the last change. A failed write
  (settings.json does not parse) stays pending and is retried after the next settings
  change. After every write, overrides the file now satisfies are dropped (a no-op write
  fires no settings change). `flushPendingSettings()` writes everything pending at once
  (quit).
- **Held routes**: a volume change made by a gesture still in progress (a drag before
  mouse up, a volume key still down) holds its route: the app is in `heldKeys`, the
  output in `heldOutputUIDs`, independent of when the debounced write lands, so a drag
  resting at 100 % keeps its tap. A final change, the key's release, or the panel closing
  (a drag whose mouse up never came) releases the hold.
- **Intents**: `setAppVolume` → `apps.<key>.volume` (rounded to integer percent);
  `toggleAppMute` → `apps.<key>.muted`; `setAppOutput` → `apps.<key>.output` (UID, or
  "default"); `setDefaultDevice` → `devices.setDefaultDevice`; `setDeviceVolume` →
  hardware volume through `devices.setVolume`, or the software volume
  (`outputs.<name>.volume`) for outputs without hardware volume; `toggleDeviceMute`
  likewise; `setBalance`; `setSampleRate`; `setDeviceVolume(.soundEffects, …)` →
  `environment.setAlertVolume`; `requestCapture` → `environment.requestCapture`, then
  refresh; `openSettings` → `environment.openSettingsFile()`; `showAppMenu` →
  `environment.showAppMenu(anchor)`. The first intent that needs a route while capture
  is not determined requests capture first.
- **Meters**: while visible, a 30 Hz timer (`environment.scheduleRepeating`) takes
  `router.takeLevels()`, runs one `MeterBallistics` per key and calls
  `panel.updateLevels`.
- **Volume keys**: false unless `volumeKeys.anyOutput`, the default output has no
  hardware volume and capture allows routes (without System Audio Recording the key goes
  to macOS; while not determined it asks once). Then down events change its software
  volume (`VolumeLaw.step`, mute toggles), re-plan, persist after 0.5 s, show the HUD
  when `volumeKeys.hud`; up events of consumed keys are consumed too and release the hold.
- **CLI**: `list` → every listed app as `CLIApp`; `devices` → every device; `setVolume`,
  `setMuted` (nil toggles), `setOutput` → `AppMatcher.match` over connected apps (a
  key-like query without a match sets that key); errors "No app matches '<q>'." and
  "'<q>' matches <names>." ; `show`/`hide` the panel.

Model text: section titles "Output", "Input", "Sound effects"; device menu items are
every device with that scope, the default first marked selected; app output menus start
with "System output (<default name>)"; readouts `VolumeLaw.text`; the empty text
"Nothing is playing"; the capture banner "Allow System Audio Recording to change app
volumes." with "Allow" (not determined) or "Open Settings" (denied).

## Shell

Entry points other modules call (binding):

```swift
// Each runs before NSApplication starts and returns the process exit code.
@MainActor enum SnapshotCommand { static func run(arguments: [String]) -> Int32 }   // Fixtures
@MainActor enum ScanCommand { static func run(arguments: [String]) -> Int32 }       // System
@MainActor enum SelfTestCommand { static func run(arguments: [String]) -> Int32 }   // System
enum CLIClient { static func run(arguments: [String]) -> Int32 }                    // Shell
// `arguments` excludes the executable: ["snapshot", "--out", "/tmp/mix.png"].

@MainActor final class MixPanelWindow: MixPanelPresenting { init() }               // Panel
@MainActor final class VolumeHUD: VolumeHUDPresenting { init() }                   // Panel
struct PermissionStatus: Equatable { var capture: CaptureStatus; var accessibility: Bool }
@MainActor final class PermissionsWindowController {                               // Shell
    /// `theme` nil follows `ThemeCenter.shared`; the harness passes one.
    init(status: @escaping @MainActor () -> PermissionStatus, theme: AppTheme? = nil)
    var onStatusChange: (@MainActor (PermissionStatus) -> Void)?
    func show()
    func renderImage() -> CGImage?
}
@MainActor final class ThemeCenter {                                               // Shell
    static let shared: ThemeCenter
    var theme: AppTheme { get }
}
// The harness resolves themes itself, like Soprano Tab's:
// AppTheme.theme(for: id == "soprano" ? AppTheme.folioId : id, appearance: .light).
```

- `main.swift`: before `NSApplication` starts, `snapshot` → `SnapshotCommand.run`,
  `scan` → `ScanCommand.run`, `selftest` → `SelfTestCommand.run`; `list`, `devices`,
  `set`, `mute`, `unmute`, `output`, `show`, `hide`, `help`, `--help` →
  `CLIClient.run(arguments:)`; all exit. Otherwise the GUI: `.accessory` activation
  policy, `AppDelegate`.
- `AppDelegate` (composition root): quit if another Soprano Mix runs (installed or dev:
  any `com.soprano.mix*` bundle id; two instances would route every app twice);
  `SettingsCenter.shared.start()`; `ThemeCenter.shared.start()`; the live system objects;
  `MixPanelWindow`, `VolumeHUD`; `MixerController(...).start()`; `VolumeKeyMonitor`
  while `volumeKeys.anyOutput` and Accessibility is granted (polled every 2 s while
  missing, never prompting on its own); `CarbonPanelHotkey` from `panel.hotkey`;
  `MenuBarController`; `LoginItem.sync`; `CLIServer.start()`. Settings changes re-apply
  the controller, hotkey, volume keys, menu bar and login item.
  `applicationWillTerminate` → `controller.flushPendingSettings()`, then
  `router.stopAll()`. Only `com.soprano.mix` registers the login item. Capture status and
  the alert volume are cached (polled every 2 s, updated after a request or a write), so
  a slider drag never runs TCC or AppleScript per tick. First launch with capture not
  determined opens the permissions window (once, `UserDefaults` key
  `didRequestPermissions`). Reopening the app opens the panel.
- `SettingsFile`, `SettingsCenter`, `ThemeCenter`, `LoginItem`: Soprano Tab's, renamed
  (`SOPRANO_MIX_CONFIG`, `soprano-mix`), `SettingsCenter.write(_:at:)` debounced by the
  controller.
- `MenuBarController`: an `NSStatusItem` with the Folio 16 pt template glyph
  (`MenuBarGlyph`): three vertical fader tracks (1.5 pt round strokes) with a short
  horizontal cap on each at different heights; `filled` fills the caps as rounded bars.
  Left click toggles the panel (anchor = the button's screen frame); right click or
  control-click shows the app menu: "Open settings.json…" (⌘,), a disabled
  "settings.json: N warnings" line while issues exist, "Permissions…", "Launch at
  Login" (checkmark; writes `app.startAtLogin`), "About Soprano Mix" (`AppVersion`),
  "Quit Soprano Mix" (⌘Q). Hidden while `menuBarIcon == .hidden` (the hotkey or reopening
  the app opens the panel).
- `Permissions`: `captureStatus` (`PrivateAPIs.audioCapturePreflight`),
  `requestCapture`, `isAccessibilityTrusted`, `requestAccessibility()`,
  `openSettings(for:)` (`…?Privacy_AudioCapture`, `…?Privacy_Accessibility`).
- `PermissionsWindowController(status:)` with `PermissionStatus { capture: CaptureStatus;
  accessibility: Bool }`: Soprano Tab's window: New York headline "Permissions", rows
  "System audio recording" ("Change app volumes, mute apps and send them to other
  outputs. Required.") and "Accessibility" ("Volume keys for outputs without hardware
  volume, like HDMI and DisplayPort. Optional."), each with a `ChromeStatusMark` and a
  `ChromeButton` ("Allow" while capture is not determined, else "Open System Settings").
  `renderImage() -> CGImage?` for the harness.
- `CLIServer(controller:)` / `CLIClient`: Soprano Tab's transport. Commands:
  `SopranoMix list`, `devices`, `set <app> <0-400>`, `mute <app>`, `unmute <app>`,
  `output <app> <device|default>`, `show`, `hide`. Prints the response JSON (pretty,
  sorted keys), exit 0; errors to stderr, exit 1; "Soprano Mix is not running." when the
  port is missing. Bundle id `Bundle.main.bundleIdentifier ?? "com.soprano.mix"`.
- `ScanCommand` (`SopranoMix scan [--all]`): no app needed, no tap, no permission:
  prints the connected apps as the resolver groups them (key, name, kind, playing, pids,
  and per process the bundle id, executable path, argv[0], responsible app) plus the
  devices. `--all` also lists apps that are connected but not playing now. The tool for "why is my app not
  listed".
- `SelfTestCommand` (`SopranoMix selftest [--gain <x>] [--seconds <n>] [--silent]`): the
  live pipeline check. Writes a 440 Hz −12 dBFS tone to a temporary WAV, plays it with
  `/usr/bin/afplay`, waits for its process object to run output, routes it through
  `LiveAudioRouter` at the gain (default 0.5) on the default output (`--silent`: gain 0),
  and reports JSON: capture status, input and output peaks, expected output peak, the
  route's added latency (aggregate safety offset + buffer + device latency, in ms), pass
  or fail. Plays sound unless `--silent`; triggers the System Audio Recording prompt for
  the app that ran it. Never run by tests.

## Fixtures and the snapshot harness

```swift
enum FixtureScenario: String, CaseIterable { case standard, game, crowded, quiet }
@MainActor final class FixtureProcessSource: AudioProcessSource {
    init(scenario: FixtureScenario)
    var processes: [AudioProcessFacts] { get set }   // setting fires onChange
}
@MainActor final class FixtureDevices: AudioDeviceControlling {
    init(scenario: FixtureScenario)
    var snapshot: DeviceSnapshot { get set }          // setters apply to it, fire onChange
}
@MainActor final class RecordingRouter: AudioRouting {
    private(set) var applied: [RoutePlan]
    var levels: [AppKey: RouteLevels]                  // returned by takeLevels
}
@MainActor final class FixtureIcons: AppIconProviding { init() }
```

Scenarios (process facts go through the real `AudioAppResolver`):
- `standard` — outputs MacBook Pro Speakers (built-in, default, hardware volume 62 %,
  balance), Furkan's AirPods Pro (Bluetooth), Odyssey G91F (DisplayPort, no hardware
  volume); inputs MacBook Pro Microphone (default), Logitech StreamCam (USB). Apps:
  Spotify (playing; setting 60 %), Safari (playing through its WebKit GPU process),
  Discord (two helper processes, playing; setting output AirPods), TEKKEN 8 (Wine
  process `C:\Program Files (x86)\Steam\steamapps\common\TEKKEN 8\Polaris\Binaries\Win64\Polaris-Win64-Shipping.exe`,
  playing; setting 35 %), Music (connected, not playing; setting muted), System Sounds
  (not playing, no setting → not listed), and Soprano Mix itself (excluded).
- `game` — default output Odyssey G91F with software volume 50 %; Steam (Wine,
  `steamwebhelper.exe`), TEKKEN 8 (Wine, playing, 35 %), Discord (playing).
- `crowded` — 14 playing apps (the panel scrolls).
- `quiet` — devices only, nothing connected: the empty state.

`SopranoMix snapshot --out <png> [--scenario standard|game|crowded|quiet] [--theme <id>]
[--settings <jsonc>] [--capture granted|notDetermined|denied] [--levels]
[--actions "<action> …"] [--hud] [--onboarding [--permissions capture=granted|notDetermined|denied,accessibility=granted|missing]]
[--report <json>]` runs the real `MixerController`, `MixPanelWindow` and `VolumeHUD` on
fixtures with an immediate scheduler, offscreen, no Dock icon, no persisted state, no
permission. Actions, applied in order through `controller.handle(_:)` /
`handleVolumeKey`: `volume:<app>=<pct>`, `mute:<app>`, `output:<app>=<device|default>`,
`device:<output|input|effects>=<device>`, `devvolume:<output|input|effects>=<pct>`,
`keyUp`, `keyDown`, `keyMute` (`<app>` through `AppMatcher`, `<device>` by UID, name,
unique prefix or unique substring; quote names with spaces: `output:Discord="AirPods"`).
`--help` prints the usage. `--levels` feeds
fixed levels (one app near clipping). `--hud` renders the HUD after the actions instead
of the panel. `--report` writes JSON: listed apps (key, name, volume, muted, output,
playing), the last plan (routes with key, mode, gain, device, process ids; master), the
settings writes, the HUD state. Themes resolve against a light system appearance and
never read Soprano's settings: default, `folio` and `folio-paper` render Paper,
`--theme folio-ink` renders Ink. Agents verify UI with it and `read` the PNG; they never
launch the GUI.

## Visual design

Folio (Soprano `docs/design/2026-10-21-calm-family/b/direction.md`, branch
`design/calm-family`), from the vendored `Chrome.swift` and `Theme.swift` only. The
accent marks only keyboard focus: the focused slider's knob ring and the caret. Every
window's appearance comes from its theme.

- **Panel** (`MixPanelWindow`): borderless `NSPanel` (non-activating, becomes key so
  sliders take arrow keys), level `.popUpMenu`, `[.canJoinAllSpaces, .fullScreenAuxiliary,
  .transient]`; 380 wide; `raised`, 1 pt `borderSubtle`, radius 10 (popover), e2 shadow
  (`shadowE2`; the offscreen render draws it). Opens 4 pt below the status item,
  right-aligned to it, clamped to the screen's visible frame; height fits the content up
  to 80 % of the visible height, the app list scrolls beyond. Closes on Escape, a click
  outside, or the status item.
- **Layout** (padding 12 top and bottom, 16 sides): the three device sections, a 1 pt
  `borderSubtle` rule with 12 pt above and below, the apps header, the app rows, the
  footer.
- **Device section**: header row 24: eyebrow ("OUTPUT", `ChromeFont.eyebrow`, muted),
  a "SOFTWARE" outline `ChromeChip` after it when the volume is software, the sample
  rate right-aligned as a plain popup (`ChromeFont.count`, muted, "48 kHz", chevron).
  Device row 28: `DeviceMenuButton` — full width, `raised`, `borderStrong` edge, radius
  6: transport SF Symbol (12 pt muted), device name (`ChromeFont.row` ink), chevron;
  opens an `NSMenu` of the devices (selected one checked). Level row 24: mute
  `ChromeIconButton` (speaker.wave.2 / speaker.slash, mic / mic.slash, bell / bell.slash;
  toggled-on pill while muted), `MixSlider` (0–100), readout 40 wide right-aligned
  (`ChromeFont.count`, muted). Output with balance: a 20 pt row "Balance" (meta, muted)
  and a centre-detent `MixSlider` (L–R) 120 wide. Sections 8 apart. Input shows no
  balance; sound effects shows the alert volume.
- **Apps header** 28: eyebrow "APPS" and " · N" (`ChromeFont.count`, muted).
- **App row** 52: 24 pt app icon at x 16, centred. Line 1 (y 8, 18 high) from x 48:
  name (`ChromeFont.row`; ink, muted when muted or not playing); trailing: a muted
  outline `ChromeChip` with the output device name when not following the system output,
  the output `DeviceMenuButton` in its compact form (24 × 24 `ChromeIconButton` with
  the target's transport symbol, menu on click), the mute `ChromeIconButton`. Line 2
  (y 30, 16 high): `MixSlider` (0–400) from x 48 to the readout; readout 44 wide
  (`ChromeFont.count`, muted); `LevelMeterView` 2 pt high, 2 pt under the slider track,
  track-wide. A failed route shows a danger diamond `ChromeStatusMark` before the name
  and its reason as the tooltip. Hover: `ChromeRowBackgroundView` `.hover`.
- **MixSlider**: 16 pt hit height; track 4 pt, radius 2, `bgOverlay` with a 1 pt
  `borderStrong` edge; value fill `textPrimary` (muted rows `textMuted`); knob 12 pt
  circle, `bgRaised` with a 1 pt `borderStrong` edge and a soft e2 shadow; keyboard
  focus adds a 2 pt `focusMark` ring 2 pt outside the knob. App sliders map 0–100 % to
  the first two thirds of the track and 100–400 % to the last third, with a 1 × 8 pt
  `textMuted` tick at 100 %, a ±3 % detent there, and the fill beyond it in `yellow`
  (boost). Arrow keys ±1 %, shift ±10 %; drag sends non-final values, mouse up the final
  one; double-click resets to 100 % (apps), the centre (balance). VoiceOver: slider role,
  value "60 percent".
- **LevelMeterView**: `textMuted` at 70 % alpha up to the position; the segment at or
  above −1 dBFS in `danger`. No meter for not-playing rows.
- **Empty**: "Nothing is playing" in New York Italic 17 (`ChromeFont.empty`) muted,
  centred in 80 pt.
- **Capture banner** (instead of nothing, above the apps header): `needsInput`
  `ChromeStatusMark`, the text in `ChromeFont.label` ink, an `.ink` `ChromeButton`
  ("Allow" / "Open Settings"), on `needsInputWash`, radius 6.
- **Footer** 28: left, "settings.json · N warnings" (meta, `yellow`) while issues exist;
  right, a gear `ChromeIconButton` showing the app menu.
- **Volume HUD** (`VolumeHUD`): borderless panel, 240 × 56, `raised`, 1 pt
  `borderSubtle`, radius 10, e2 shadow; top-right of the main screen, 8 pt below the menu
  bar and 8 pt from the right edge; speaker symbol (13 pt, ink; speaker.slash when
  muted), device name (`ChromeFont.label` ink) and "Software volume" (meta, muted); a
  4 pt track as in `MixSlider` without knob showing the level. Stays 1.2 s after the last
  key, fades out over 200 ms (instant under Reduce Motion). Ignores the mouse.
- **App icon**: the Folio squircle with three vertical fader tracks and a cap on each at
  different heights, the middle cap in sienna (exactly one sienna element), rendered by
  `scripts/render-app-icon.swift mix`.

## Tests

swift-testing (`import Testing`, `@Test`, `#expect`), one `struct …Tests` per file,
sentence-style names. Test files `import AppKit` (never `Foundation`: its
`_Testing_Foundation` overlay breaks the build) plus `@testable import SopranoMix` /
`SopranoMixCore`; main-actor tests are `@MainActor`. Tests never touch real audio
devices, taps, settings, permissions or the user's defaults; settings tests inject the
file URL, system tests cover only the pure parts. Test behavior consumers see
(boundaries, precedence, transitions, invariants), not wiring.

## Not copied from SoundSource

Soprano family conventions replace these: the preferences window (settings.json, live
reloaded, opened from the menu), Sparkle updates and crash reports (install with
`scripts/install.sh`), the license and trial, UI languages other than English. Effects,
AirPlay, output groups, per-app input and the Devices window are listed in
`docs/ROADMAP.md`.
