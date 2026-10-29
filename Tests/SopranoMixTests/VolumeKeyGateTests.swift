import Testing
@testable import SopranoMixCore

/// macOS repeats a volume key it saw go down until it sees it come up: every press must
/// reach macOS whole or not at all, even when interception flips mid-press.
struct VolumeKeyGateTests {
    private enum Step {
        case down, repeated, up
        case intercept(Bool)
    }

    /// Whether the gate consumed each key event, in order.
    private func decisions(intercepts: Bool, _ steps: [Step]) -> [Bool] {
        var gate = VolumeKeyGate(intercepts: intercepts)
        var consumed: [Bool] = []
        for step in steps {
            switch step {
            case .down: consumed.append(gate.consumes(VolumeKeyEvent(key: .up, isDown: true)))
            case .repeated: consumed.append(gate.consumes(VolumeKeyEvent(key: .up, isDown: true, isRepeat: true)))
            case .up: consumed.append(gate.consumes(VolumeKeyEvent(key: .up, isDown: false)))
            case let .intercept(on): gate.intercepts = on
            }
        }
        return consumed
    }

    @Test("a press macOS saw go down reaches macOS until its up, when interception starts mid-press")
    func passedPressStaysPassed() {
        #expect(decisions(intercepts: false, [.down, .intercept(true), .repeated, .up, .down])
            == [false, false, false, true])
    }

    @Test("a consumed press stays consumed until its up, when interception stops mid-press")
    func consumedPressStaysConsumed() {
        #expect(decisions(intercepts: true, [.down, .intercept(false), .repeated, .up, .down])
            == [true, true, true, false])
    }

    @Test("an up without a known down goes to macOS")
    func strayUpPasses() {
        #expect(decisions(intercepts: true, [.up]) == [false])
    }

    @Test("a new press after a lost up is decided afresh")
    func newPressAfterLostUp() {
        #expect(decisions(intercepts: true, [.down, .intercept(false), .down, .up]) == [true, false, false])
    }
}
