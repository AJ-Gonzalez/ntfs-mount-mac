import XCTest
@testable import NTFSMountCore

final class FailureClassifierTests: XCTestCase {
    func testMFTMirrorMismatchIsFilesystemNotUSB() {
        let output = """
        $MFTMirr does not match $MFT (record 0).
        Failed to mount '/dev/disk6s1': Input/output error
        NTFS is either inconsistent, or there is a hardware fault, or it's a
        SoftRAID/FakeRAID hardware. In the first case run chkdsk /f on Windows
        then reboot into Windows twice. The usage of the /f parameter is very
        important!
        """
        let result = FailureClassifier.classify(output)
        XCTAssertEqual(result.kind, .filesystem)
        XCTAssertTrue(result.message.contains("$MFTMirr does not match $MFT"))
        XCTAssertTrue(result.message.lowercased().contains("chkdsk"))
        XCTAssertFalse(result.message.lowercased().contains("usb"))
    }

    func testBootsectorReadFailureIsUSB() {
        let output = """
        Error reading bootsector: Input/output error
        Failed to mount '/dev/disk6s1': Input/output error
        NTFS is either inconsistent, or there is a hardware fault, or it's a
        SoftRAID/FakeRAID hardware. In the first case run chkdsk /f on Windows
        """
        let result = FailureClassifier.classify(output)
        XCTAssertEqual(result.kind, .usb)
        XCTAssertTrue(result.message.lowercased().contains("replug"))
    }

    func testBusyVolume() {
        let output = """
        Failed to mount '/dev/disk6s1': Resource busy
        Mount is denied because the NTFS volume is already exclusively opened.
        """
        XCTAssertEqual(FailureClassifier.classify(output).kind, .busy)
    }

    func testPermissionFailureWinsOverIoText() {
        let output = "Error opening '/dev/disk6s1': Operation not permitted"
        let result = FailureClassifier.classify(output)
        XCTAssertEqual(result.kind, .permission)
    }

    func testUnknownFailureKeepsRawText() {
        let output = "ntfs-3g: something odd happened"
        let result = FailureClassifier.classify(output)
        XCTAssertEqual(result.kind, .unknown)
        XCTAssertEqual(result.message, output)
    }
}
