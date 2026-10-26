import AppKit
import Testing
@testable import SopranoMix
@testable import SopranoMixCore

struct VolumeKeyConversionTests {
    /// `data1` of an aux-control event: key code, key state (0xA down, 0xB up), repeat bit.
    private func data1(keyCode: Int, state: Int, isRepeat: Bool = false) -> Int {
        (keyCode << 16) | (state << 8) | (isRepeat ? 1 : 0)
    }

    @Test("volume up, down and mute key presses map to their keys")
    func keys() {
        #expect(VolumeKeyConversion.event(data1: data1(keyCode: 0, state: 0xA), flags: [])
            == VolumeKeyEvent(key: .up, isDown: true))
        #expect(VolumeKeyConversion.event(data1: data1(keyCode: 1, state: 0xA), flags: [])
            == VolumeKeyEvent(key: .down, isDown: true))
        #expect(VolumeKeyConversion.event(data1: data1(keyCode: 7, state: 0xA), flags: [])
            == VolumeKeyEvent(key: .mute, isDown: true))
    }

    @Test("state 0xB is a release and the low bit marks a repeat")
    func releaseAndRepeat() {
        #expect(VolumeKeyConversion.event(data1: data1(keyCode: 0, state: 0xB), flags: [])
            == VolumeKeyEvent(key: .up, isDown: false))
        #expect(VolumeKeyConversion.event(data1: data1(keyCode: 1, state: 0xA, isRepeat: true), flags: [])
            == VolumeKeyEvent(key: .down, isDown: true, isRepeat: true))
    }

    @Test("fine steps need option and shift together")
    func fine() {
        let down = data1(keyCode: 0, state: 0xA)
        #expect(VolumeKeyConversion.event(data1: down, flags: [.maskAlternate, .maskShift])?.fine == true)
        #expect(VolumeKeyConversion.event(data1: down, flags: [.maskAlternate])?.fine == false)
        #expect(VolumeKeyConversion.event(data1: down, flags: [.maskShift])?.fine == false)
        #expect(VolumeKeyConversion.event(data1: down, flags: [.maskAlternate, .maskShift, .maskCommand])?.fine == true)
    }

    @Test("brightness, media keys and unknown key states are not volume keys")
    func otherKeys() {
        // Brightness up/down (2, 3), the codes next to mute (6, 8), play (16), next/previous (19, 20).
        for keyCode in [2, 3, 6, 8, 16, 19, 20] {
            #expect(VolumeKeyConversion.event(data1: data1(keyCode: keyCode, state: 0xA), flags: []) == nil)
        }
        #expect(VolumeKeyConversion.event(data1: data1(keyCode: 0, state: 0x0), flags: []) == nil)
        #expect(VolumeKeyConversion.event(data1: data1(keyCode: 0, state: 0xC), flags: []) == nil)
    }
}
