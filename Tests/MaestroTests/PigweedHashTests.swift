import XCTest
@testable import Maestro

final class PigweedHashTests: XCTestCase {
    func testKnownHashesFromRustTests() {
        // Vectors lifted verbatim from libmaestro/src/pwrpc/id.rs.
        XCTAssertEqual(PigweedHash.hash("maestro_pw.Maestro"), 0x7ede71ea)
        XCTAssertEqual(PigweedHash.hash("GetSoftwareInfo"), 0x7199fa44)
        XCTAssertEqual(PigweedHash.hash("SubscribeToSettingsChanges"), 0x2821adf5)
    }

    func testPathDecomposition() {
        let p = RpcPath("maestro_pw.Maestro/GetSoftwareInfo")
        XCTAssertEqual(p.service, "maestro_pw.Maestro")
        XCTAssertEqual(p.method, "GetSoftwareInfo")
        XCTAssertEqual(p.serviceHash, 0x7ede71ea)
        XCTAssertEqual(p.methodHash, 0x7199fa44)
    }
}
