import AppKit
import Testing
@testable import SopranoMix

@MainActor
struct VolumeHUDTests {
    /// Collects scheduled work so a test runs it when it chooses.
    @MainActor
    private final class ManualScheduler {
        var jobs: [(delay: TimeInterval, work: @MainActor () -> Void)] = []

        func runAll() {
            let due = jobs
            jobs.removeAll()
            for job in due {
                job.work()
            }
        }
    }

    init() {
        VolumeHUD.offscreen = true
    }

    private func makeHUD(_ scheduler: ManualScheduler) -> VolumeHUD {
        VolumeHUD(schedule: { delay, work in scheduler.jobs.append((delay: delay, work: work)) })
    }

    private func model(level: Double, muted: Bool = false) -> VolumeHUDModel {
        VolumeHUDModel(deviceName: "Odyssey G91F", level: level, isMuted: muted, caption: "Software volume")
    }

    @Test("the HUD shows the last model and hides itself 1.2 s after showing")
    func hidesAfterDelay() {
        let scheduler = ManualScheduler()
        let hud = makeHUD(scheduler)

        hud.show(model(level: 0.5), theme: .folioPaper)

        #expect(hud.current == model(level: 0.5))
        #expect(scheduler.jobs.map { $0.delay } == [VolumeHUD.visibleDuration])

        scheduler.runAll()
        #expect(hud.current == nil)
    }

    @Test("a newer show restarts the clock: only its own timer hides the HUD")
    func newerShowRestartsClock() {
        let scheduler = ManualScheduler()
        let hud = makeHUD(scheduler)

        hud.show(model(level: 0.5), theme: .folioPaper)
        hud.show(model(level: 0.5625), theme: .folioInk)
        let first = scheduler.jobs.removeFirst()
        first.work()
        #expect(hud.current == model(level: 0.5625))

        scheduler.runAll()
        #expect(hud.current == nil)
    }

    @Test("the HUD sits at the top right of the visible frame, 8 pt in from both edges")
    func frameAtTopRight() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 949)
        let frame = VolumeHUD.frame(in: visible)
        #expect(frame.size == NSSize(width: 240, height: 56))
        #expect(frame.maxX == CGFloat(1512 - 8))
        #expect(frame.maxY == CGFloat(949 - 8))
    }

    @Test("the HUD renders offscreen once shown, padded for its shadow")
    func rendersOffscreen() throws {
        let scheduler = ManualScheduler()
        let hud = makeHUD(scheduler)
        #expect(hud.renderSnapshot(scale: 2) == nil)

        hud.show(model(level: 0, muted: true), theme: .folioInk)

        let image = try #require(hud.renderSnapshot(scale: 2))
        #expect(image.width > 480)
        #expect(image.height > 112)
    }
}
