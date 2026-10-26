import AppKit
import Testing
@testable import SopranoMix
@testable import SopranoMixCore

@MainActor
struct PermissionsWindowTests {
    /// The status the window polls; tests flip it between renders.
    @MainActor
    private final class StatusBox {
        var status: PermissionStatus

        init(_ status: PermissionStatus) {
            self.status = status
        }
    }

    private func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private func render(_ status: PermissionStatus) throws -> CGImage {
        let controller = PermissionsWindowController(status: { status }, theme: AppTheme.folioPaper)
        let image = try #require(controller.renderImage())
        #expect(controller.window?.isVisible == false)
        return image
    }

    @Test("the window renders offscreen at its full size for every capture status, each one differently")
    func rendersEveryCaptureStatus() throws {
        let statuses: [CaptureStatus] = [.granted, .denied, .notDetermined, .unknown]
        var renders: [Data] = []
        for capture in statuses {
            let image = try render(PermissionStatus(capture: capture, accessibility: true))
            #expect(image.width >= Int(PermissionsWindowController.contentSize.width))
            #expect(image.height >= Int(PermissionsWindowController.contentSize.height))
            renders.append(try #require(pngData(image)))
        }

        #expect(Set(renders).count == statuses.count)
    }

    @Test("missing Accessibility renders differently from granted Accessibility")
    func rendersAccessibilityStates() throws {
        let granted = try render(PermissionStatus(capture: .granted, accessibility: true))
        let missing = try render(PermissionStatus(capture: .granted, accessibility: false))

        #expect(granted.width == missing.width)
        #expect(granted.height == missing.height)
        #expect(pngData(granted) != pngData(missing))
    }

    @Test("a grant turns the window on the next render and notifies once")
    func renderFollowsStatusChanges() throws {
        let box = StatusBox(PermissionStatus(capture: .notDetermined, accessibility: false))
        let controller = PermissionsWindowController(status: { box.status }, theme: AppTheme.folioPaper)
        var changes: [PermissionStatus] = []
        controller.onStatusChange = { changes.append($0) }

        let before = try #require(controller.renderImage())
        box.status.capture = .granted
        let after = try #require(controller.renderImage())
        let again = try #require(controller.renderImage())

        #expect(pngData(before) != pngData(after))
        #expect(pngData(after) == pngData(again))
        #expect(changes == [PermissionStatus(capture: .granted, accessibility: false)])
    }

    @Test("the Ink theme renders a different window from Paper")
    func rendersInTheGivenTheme() throws {
        let status = PermissionStatus(capture: .denied, accessibility: false)
        let paper = PermissionsWindowController(status: { status }, theme: AppTheme.folioPaper)
        let ink = PermissionsWindowController(status: { status }, theme: AppTheme.folioInk)

        let paperImage = try #require(paper.renderImage())
        let inkImage = try #require(ink.renderImage())

        #expect(pngData(paperImage) != pngData(inkImage))
    }
}
