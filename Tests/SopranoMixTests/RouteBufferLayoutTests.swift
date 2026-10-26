import AppKit
import Testing
@testable import SopranoMix

struct RouteBufferLayoutTests {
    @Test func anInterleavedStereoTapIsTheOnlyInputOfAnOutputOnlyDevice() throws {
        let layout = try #require(RouteBufferLayout(inputBufferChannels: [2], outputBufferChannels: [2], tapChannelCount: 2))
        #expect(layout.tapChannels == [
            RouteChannel(buffer: 0, offset: 0, stride: 2),
            RouteChannel(buffer: 0, offset: 1, stride: 2),
        ])
    }

    @Test func theTapComesAfterTheOutputDevicesOwnInputStreams() throws {
        let layout = try #require(RouteBufferLayout(inputBufferChannels: [2, 2], outputBufferChannels: [2], tapChannelCount: 2))
        #expect(layout.tapChannels == [
            RouteChannel(buffer: 1, offset: 0, stride: 2),
            RouteChannel(buffer: 1, offset: 1, stride: 2),
        ])
    }

    @Test func aPlanarTapUsesTheLastBuffersOneChannelEach() throws {
        let layout = try #require(RouteBufferLayout(inputBufferChannels: [4, 1, 1], outputBufferChannels: [2], tapChannelCount: 2))
        #expect(layout.tapChannels == [
            RouteChannel(buffer: 1, offset: 0, stride: 1),
            RouteChannel(buffer: 2, offset: 0, stride: 1),
        ])
    }

    @Test func outputChannelsRunAcrossEveryOutputStreamInOrder() throws {
        let layout = try #require(RouteBufferLayout(inputBufferChannels: [2], outputBufferChannels: [2, 6], tapChannelCount: 2))
        #expect(layout.outputChannels.count == 8)
        #expect(layout.outputChannels[1] == RouteChannel(buffer: 0, offset: 1, stride: 2))
        #expect(layout.outputChannels[2] == RouteChannel(buffer: 1, offset: 0, stride: 6))
        #expect(layout.outputChannels[7] == RouteChannel(buffer: 1, offset: 5, stride: 6))
    }

    @Test func emptyStreamsAreSkipped() throws {
        let layout = try #require(RouteBufferLayout(inputBufferChannels: [0, 2], outputBufferChannels: [0, 1], tapChannelCount: 2))
        #expect(layout.tapChannels.first == RouteChannel(buffer: 1, offset: 0, stride: 2))
        #expect(layout.outputChannels == [RouteChannel(buffer: 1, offset: 0, stride: 1)])
    }

    @Test func aMonoOutputDeviceHasOneOutputChannel() throws {
        let layout = try #require(RouteBufferLayout(inputBufferChannels: [2], outputBufferChannels: [1], tapChannelCount: 2))
        #expect(layout.outputChannels == [RouteChannel(buffer: 0, offset: 0, stride: 1)])
    }

    @Test func aMultichannelTapKeepsItsChannelOrder() throws {
        let layout = try #require(RouteBufferLayout(inputBufferChannels: [6], outputBufferChannels: [6], tapChannelCount: 6))
        #expect(layout.tapChannels.map(\.offset) == [0, 1, 2, 3, 4, 5])
        #expect(layout.tapChannels.allSatisfy { $0.buffer == 0 && $0.stride == 6 })
    }

    @Test func thereIsNoLayoutWhenTheInputsHoldFewerChannelsThanTheTap() {
        #expect(RouteBufferLayout(inputBufferChannels: [1], outputBufferChannels: [2], tapChannelCount: 2) == nil)
        #expect(RouteBufferLayout(inputBufferChannels: [], outputBufferChannels: [2], tapChannelCount: 2) == nil)
    }

    @Test func thereIsNoLayoutForATapWithoutChannels() {
        #expect(RouteBufferLayout(inputBufferChannels: [2], outputBufferChannels: [2], tapChannelCount: 0) == nil)
    }
}
