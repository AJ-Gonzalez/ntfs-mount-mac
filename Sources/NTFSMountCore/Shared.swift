import Foundation
import Darwin

public enum Paths {
    public static let helper = "/usr/local/libexec/ntfsmount/ntfsmount-helper"
    public static let ntfs3g = "/usr/local/libexec/ntfsmount/ntfs-3g"
    public static let fuseTLibrary = "/usr/local/lib/libfuse-t.dylib"
    public static let log = "/var/log/ntfsmount.log"
}

public struct HelperResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var code: Int32?
    public var needsFDA: Bool?
    public var mountPoint: String?
    public var state: String?
    public var ntfs3g: Bool?
    public var fuseT: Bool?
    public var rawAccess: Bool?

    public init(
        ok: Bool,
        error: String? = nil,
        code: Int32? = nil,
        needsFDA: Bool? = nil,
        mountPoint: String? = nil,
        state: String? = nil,
        ntfs3g: Bool? = nil,
        fuseT: Bool? = nil,
        rawAccess: Bool? = nil
    ) {
        self.ok = ok
        self.error = error
        self.code = code
        self.needsFDA = needsFDA
        self.mountPoint = mountPoint
        self.state = state
        self.ntfs3g = ntfs3g
        self.fuseT = fuseT
        self.rawAccess = rawAccess
    }

    public func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return #"{"ok":false,"error":"encoding failure"}"# }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct RunResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum Shell {
    @discardableResult
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> RunResult {
        let fileManager = FileManager.default
        let token = UUID().uuidString
        let outURL = fileManager.temporaryDirectory.appendingPathComponent("ntfsmount-out-\(token)")
        let errURL = fileManager.temporaryDirectory.appendingPathComponent("ntfsmount-err-\(token)")
        fileManager.createFile(atPath: outURL.path, contents: nil,
                               attributes: [.posixPermissions: 0o600])
        fileManager.createFile(atPath: errURL.path, contents: nil,
                               attributes: [.posixPermissions: 0o600])
        defer {
            try? fileManager.removeItem(at: outURL)
            try? fileManager.removeItem(at: errURL)
        }

        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return RunResult(status: 127, stdout: "", stderr: "cannot create output files")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = outHandle
        process.standardError = errHandle

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            return RunResult(status: 127, stdout: "", stderr: error.localizedDescription)
        }

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
        }

        try? outHandle.close()
        try? errHandle.close()

        // Regular files, not pipes: ntfs-3g may leave a daemon holding the
        // inherited descriptors open, which would make readDataToEndOfFile hang.
        let outData = (try? Data(contentsOf: outURL)) ?? Data()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        let status: Int32 = timedOut ? 124 : process.terminationStatus
        return RunResult(
            status: status,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}

public struct MountInfo: Sendable {
    public var isMount: Bool
    public var readOnly: Bool
    public var fsType: String
    public var from: String
}

public enum MountTable {
    /// Uses the platform mount table, which also covers FUSE-T/NFS mounts.
    public static func info(atPath path: String) -> MountInfo? {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return nil }

        for index in 0..<Int(count) {
            let entry = buffer[index]
            let mountedOn = withUnsafePointer(to: entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard mountedOn == path else { continue }

            let from = withUnsafePointer(to: entry.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let fsType = withUnsafePointer(to: entry.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
            return MountInfo(
                isMount: true,
                readOnly: (entry.f_flags & UInt32(MNT_RDONLY)) != 0,
                fsType: fsType,
                from: from
            )
        }
        return nil
    }

    public static func space(atPath path: String) -> Int64? {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return nil }

        for index in 0..<Int(count) {
            let entry = buffer[index]
            let mountedOn = withUnsafePointer(to: entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard mountedOn == path else { continue }
            return Int64(entry.f_bavail) * Int64(entry.f_bsize)
        }
        return nil
    }

    public static func lines() -> [String] {
        let result = Shell.run("/sbin/mount", [], timeout: 10)
        return result.stdout.split(separator: "\n").map(String.init)
    }

    public static func line(forDevice device: String) -> String? {
        let needle = "/dev/\(device) on "
        return lines().first { $0.hasPrefix(needle) }
    }

    public static func path(forDevice device: String) -> String? {
        if let line = line(forDevice: device),
           let range = line.range(of: " on ") {
            let rest = line[range.upperBound...]
            if let end = rest.range(of: " (") {
                return String(rest[..<end.lowerBound])
            }
        }
        // FUSE-T reports NFS style sources; match the conventional mountpoint.
        return nil
    }
}

public enum DeviceID {
    /// disk6s1 -> disk6. Rejects anything that is not a partition identifier.
    public static func wholeDisk(for device: String) -> String? {
        guard let range = device.range(of: "s", options: .backwards),
              device.hasPrefix("disk") else { return nil }
        let whole = String(device[..<range.lowerBound])
        return whole == "disk" ? nil : whole
    }

    public static func isValid(_ device: String) -> Bool {
        device.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil
    }
}
