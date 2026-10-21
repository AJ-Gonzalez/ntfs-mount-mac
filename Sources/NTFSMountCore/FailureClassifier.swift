import Foundation

public enum FailureKind: String, Sendable {
    case filesystem
    case usb
    case permission
    case busy
    case notNTFS
    case unknown
}

public struct ClassifiedFailure: Sendable {
    public let kind: FailureKind
    public let message: String

    public init(kind: FailureKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public enum FailureClassifier {
    /// ntfs-3g emits long boilerplate for every failure. Classify the actual
    /// cause first so the UI never turns an NTFS metadata error into a USB hint.
    public static func classify(_ raw: String, needsFDA: Bool = false) -> ClassifiedFailure {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        if needsFDA || lower.contains("operation not permitted") {
            return ClassifiedFailure(
                kind: .permission,
                message: "macOS denied raw disk access. Grant Full Disk Access to ntfs-3g, then retry."
            )
        }

        if lower.contains("not an ntfs volume") {
            return ClassifiedFailure(kind: .notNTFS, message: "This volume is not NTFS.")
        }

        let isBootsectorReadFailure = lower.contains("error reading bootsector")
        let isMetadataMismatch = lower.contains("$mftmirr")
            || lower.contains("$mft")
            || lower.contains("mft record")
            || lower.contains("mftmirr")

        if isMetadataMismatch {
            return ClassifiedFailure(
                kind: .filesystem,
                message: "NTFS metadata is inconsistent: \(summary(text)). Not mounted to protect the volume — repair it on Windows with chkdsk /f."
            )
        }

        if lower.contains("inconsistent") && !isBootsectorReadFailure {
            return ClassifiedFailure(
                kind: .filesystem,
                message: "NTFS metadata is inconsistent: \(summary(text)). Not mounted to protect the volume — repair it on Windows with chkdsk /f."
            )
        }

        if isBootsectorReadFailure || lower.contains("input/output error") || lower.contains("i/o error") {
            return ClassifiedFailure(
                kind: .usb,
                message: "USB bridge stopped responding while reading the volume. Replug the drive; if it recurs, replace the cable or enclosure."
            )
        }

        if lower.contains("resource busy")
            || lower.contains("already mounted")
            || lower.contains("exclusively opened") {
            return ClassifiedFailure(
                kind: .busy,
                message: "The volume is busy. Close applications using it and try again."
            )
        }

        return ClassifiedFailure(
            kind: .unknown,
            message: text.isEmpty ? "Mount failed." : text
        )
    }

    private static func summary(_ text: String) -> String {
        let boilerplate = [
            "NTFS is either inconsistent",
            "SoftRAID",
            "then reboot",
            "The usage of",
            "important!",
            "it and mount",
            "for more details",
            "Please see",
        ]
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && !boilerplate.contains(where: { line.hasPrefix($0) })
            }
        let taken = lines.prefix(2).joined(separator: " ")
        return taken.isEmpty ? "filesystem consistency failure" : taken
    }
}
