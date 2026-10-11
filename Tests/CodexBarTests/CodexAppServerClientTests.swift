import Foundation
import XCTest
@testable import CodexBar

final class CodexAppServerClientTests: XCTestCase {
    func testMissingOptionalResponseHasShortDeadlineAndPreservesRequiredResults() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not clean process fixture: \(error)") }
        }
        let executable = directory.appending(path: "server")
        let script = """
        #!/usr/bin/env python3
        import json, sys, time
        for line in sys.stdin:
            request = json.loads(line)
            identifier = request.get('id')
            if identifier is None:
                continue
            if identifier == 3:
                time.sleep(30)
            else:
                print(json.dumps({'id': identifier, 'result': {'marker': identifier}}), flush=True)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let started = Date()
        let result = try CodexAppServerClient.runProbe(executable: executable, includeTokenUsage: true,
                                                     optionalResponseTimeout: 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let messages = try result.split(separator: 0x0A).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        for identifier in [1, 2] {
            let message = try XCTUnwrap(messages.first { $0["id"] as? Int == identifier })
            XCTAssertEqual((message["result"] as? [String: Any])?["marker"] as? Int, identifier)
        }
        let optional = try XCTUnwrap(messages.first { $0["id"] as? Int == 3 })
        XCTAssertNotNil(optional["error"])
    }
}
