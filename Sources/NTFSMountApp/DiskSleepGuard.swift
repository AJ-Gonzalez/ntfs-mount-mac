import Foundation
import IOKit.pwr_mgt

/// Holds a PreventDiskIdle power assertion while an NTFS volume is mounted.
/// Cheap USB bridges frequently fail to resume from disk sleep on macOS 26,
/// which surfaces as "Error reading bootsector: Input/output error".
final class DiskSleepGuard {
    private var assertionID: IOPMAssertionID = 0
    private var systemSleepID: IOPMAssertionID = 0
    private var active = false

    func setActive(_ shouldBeActive: Bool) {
        guard shouldBeActive != active else { return }

        if shouldBeActive {
            let reason = "NTFS volume is mounted" as CFString
            _ = IOPMAssertionCreateWithName(
                kIOPMAssertPreventDiskIdle as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &assertionID
            )
            _ = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &systemSleepID
            )
            active = true
        } else {
            IOPMAssertionRelease(assertionID)
            IOPMAssertionRelease(systemSleepID)
            assertionID = 0
            systemSleepID = 0
            active = false
        }
    }
}
