import XCTest
@testable import DroidLink

final class HandsFreeClientTests: XCTestCase {
    func testWorkerFailureClearsAudioStateWithoutTerminatingParent() async throws {
        // No Bluetooth hardware or phone call: simulate a worker that reports state, then fails.
        let client = HandsFreeClient(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c",
            "printf '{\"connected\":true,\"sco\":true}\\n'; sleep 0.2; exit 7"])
        client.connect(address: "test")
        let deadline = Date().addingTimeInterval(5)
        while client.snapshot.1.error == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(client.snapshot.1.connected)
        XCTAssertFalse(client.snapshot.1.sco)
        XCTAssertNotNil(client.snapshot.1.error)
        client.command("stop") // Writing after the worker exits must be harmless.
        client.disconnect()
    }
}
