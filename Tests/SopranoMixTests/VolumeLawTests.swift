import AppKit
import Testing
@testable import SopranoMixCore

struct VolumeLawTests {
    @Test("gain follows loudness: half is -10 dB, double +10 dB, 400 percent +20 dB")
    func loudnessLaw() {
        #expect(VolumeLaw.gain(percent: 100) == 1)
        #expect(VolumeLaw.gain(percent: 0) == 0)
        #expect(VolumeLaw.gain(percent: -5) == 0)
        #expect(abs(VolumeLaw.gain(percent: 50) - 0.316_227_77) < 1e-5)
        #expect(abs(VolumeLaw.gain(percent: 200) - 3.162_277_7) < 1e-4)
        #expect(abs(VolumeLaw.gain(percent: 400) - 10) < 1e-4)
        #expect(VolumeLaw.gain(percent: 60) < VolumeLaw.gain(percent: 61))
    }

    @Test("decibels are nil at zero and match the gain elsewhere")
    func decibels() {
        #expect(VolumeLaw.decibels(percent: 0) == nil)
        #expect(abs((VolumeLaw.decibels(percent: 50) ?? 0) + 10) < 1e-9)
        #expect(abs(VolumeLaw.decibels(percent: 100) ?? 1) < 1e-12)
        #expect(abs((VolumeLaw.decibels(percent: 400) ?? 0) - 20) < 1e-9)
    }

    @Test("readouts are rounded whole percent")
    func text() {
        #expect(VolumeLaw.text(percent: 60) == "60 %")
        #expect(VolumeLaw.text(percent: 0) == "0 %")
        #expect(VolumeLaw.text(percent: 249.6) == "250 %")
    }

    @Test("ranges are 0 to 400 for apps and 0 to 100 for outputs")
    func ranges() {
        #expect(VolumeLaw.appRange == 0...400)
        #expect(VolumeLaw.outputRange == 0...100)
    }

    @Test("a step moves one sixteenth on the grid, one sixty-fourth when fine")
    func gridSteps() {
        #expect(VolumeLaw.step(50, up: true, fine: false) == 56.25)
        #expect(VolumeLaw.step(50, up: false, fine: false) == 43.75)
        #expect(VolumeLaw.step(50, up: true, fine: true) == 51.5625)
        #expect(VolumeLaw.step(50, up: false, fine: true) == 48.4375)
    }

    @Test("an off-grid volume snaps to the grid before stepping")
    func snapsFirst() {
        // 60 snaps to 62.5 (10 × 6.25), then moves one step.
        #expect(VolumeLaw.step(60, up: true, fine: false) == 68.75)
        #expect(VolumeLaw.step(60, up: false, fine: false) == 56.25)
        let stepped = VolumeLaw.step(33.3, up: true, fine: true)
        #expect((stepped / 1.5625).rounded() * 1.5625 == stepped)
    }

    @Test("steps clamp at silence and full volume")
    func clamps() {
        #expect(VolumeLaw.step(0, up: false, fine: false) == 0)
        #expect(VolumeLaw.step(100, up: true, fine: false) == 100)
        #expect(VolumeLaw.step(99, up: true, fine: true) == 100)
        #expect(VolumeLaw.step(2, up: false, fine: false) == 0)
    }
}
