import XCTest
import AppKit
@testable import DroidLink

final class MirrorInputTests: XCTestCase {
    @MainActor func testPointerEventsMapThroughLetterboxingAndRelease() throws {
        _ = NSApplication.shared
        let canvas = MirrorCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        canvas.videoSize = CGSize(width: 720, height: 1280)
        canvas.enabled = true
        var commands: [[String: Any]] = []
        canvas.input = { commands.append($0) }
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 200, y: 400),
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: down)
        canvas.releasePointer()
        XCTAssertEqual(commands.compactMap { $0["action"] as? String }, ["down", "up"])
        XCTAssertEqual(try XCTUnwrap(commands.first?["x"] as? CGFloat), 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(commands.first?["y"] as? CGFloat), 0.5, accuracy: 0.001)
        commands.removeAll()
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 200, y: 795),
            modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: outside)
        XCTAssertTrue(commands.isEmpty)
        canvas.enabled = false
        canvas.mouseDown(with: down)
        XCTAssertTrue(commands.isEmpty)
    }
}
