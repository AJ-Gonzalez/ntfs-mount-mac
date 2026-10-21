import Foundation
import Darwin
import DiskArbitration
import NTFSMountCore

struct HelperError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let logQueue = DispatchQueue(label: "ntfsmount.log")

func logLine(_ message: String) {
    logQueue.sync {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = Paths.log
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        if let size = try? handle.seekToEnd(), size > 2_000_000 {
            try? handle.truncate(atOffset: 0)
        }
        try? handle.write(contentsOf: data)
    }
}

func consoleUser() -> (uid: uid_t, gid: gid_t) {
    var st = stat()
    if stat("/dev/console", &st) == 0, st.st_uid > 0, let pw = getpwuid(st.st_uid) {
        return (st.st_uid, pw.pointee.pw_gid)
    }
    if let pw = getpwuid(getuid()) {
        return (getuid(), pw.pointee.pw_gid)
    }
    return (501, 20)
}

func diskDescription(_ device: String) -> [String: Any]? {
    guard let session = DASessionCreate(kCFAllocatorDefault),
          let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, device),
          let description = DADiskCopyDescription(disk) else {
        return nil
    }
    return description as? [String: Any]
}

func sanitizedLabel(_ raw: String?, device: String) -> String {
    var label = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let forbidden = CharacterSet(charactersIn: "/:\0\n\r\t")
    label = label.components(separatedBy: forbidden).joined(separator: "-")
    if label.isEmpty || label == "." || label == ".." {
        label = "NTFS-\(device)"
    }
    if label.count > 64 {
        label = String(label.prefix(64))
    }
    return label
}

func ntfsVolumeInfo(_ device: String) throws -> (label: String, uuid: String) {
    if let description = diskDescription(device) {
        let content = description["DAMediaContent"] as? String
        let kind = description["DAVolumeKind"] as? String
        let isNTFS = content == "Windows_NTFS" || kind?.lowercased() == "ntfs"
        if isNTFS || content == nil {
            let label = sanitizedLabel(description["DAVolumeName"] as? String, device: device)
            let uuid = (description["DAVolumeUUID"] as? UUID)?.uuidString
                ?? (description["DAVolumeUUID"] as? String)
                ?? device
            if isNTFS {
                return (label, uuid)
            }
        }
    }

    let r = Shell.run("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(device)"], timeout: 15)
    guard r.status == 0,
          let data = r.stdout.data(using: .utf8),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw HelperError("cannot read disk information for \(device)")
    }
    let content = plist["Content"] as? String
    let fsType = (plist["FilesystemType"] as? String)?.lowercased()
    guard content == "Windows_NTFS" || fsType == "ntfs" else {
        throw HelperError("/dev/\(device) is not an NTFS volume")
    }
    let label = sanitizedLabel(plist["VolumeName"] as? String, device: device)
    let uuid = (plist["VolumeUUID"] as? String) ?? device
    return (label, uuid)
}

func canOpenRaw(_ device: String) -> (ok: Bool, errno: Int32) {
    let fd = open("/dev/\(device)", O_RDONLY)
    if fd < 0 {
        return (false, errno)
    }
    close(fd)
    return (true, 0)
}

func mountedPath(for device: String, fallback: String) -> String? {
    if MountTable.info(atPath: fallback)?.isMount == true {
        return fallback
    }
    if let path = MountTable.path(forDevice: device) {
        return path
    }
    return nil
}

func ensureMountPoint(_ path: String) throws {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    if !fm.fileExists(atPath: path, isDirectory: &isDir) {
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
        } catch {
            // /Volumes can be a sealed firmlink on newer macOS releases.
            let dataPath = "/System/Volumes/Data" + path
            try fm.createDirectory(atPath: dataPath, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
        }
    }
    let contents = try fm.contentsOfDirectory(atPath: path)
    guard contents.isEmpty else {
        throw HelperError("mount point \(path) is not empty")
    }
}

func waitForMount(_ path: String, device: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let info = MountTable.info(atPath: path), info.isMount, !info.readOnly {
            return true
        }
        if let line = MountTable.line(forDevice: device), line.contains("\(path) ") {
            return true
        }
        usleep(200_000)
    } while Date() < deadline
    return false
}

func terminateNTFS3G(device: String) {
    let ps = Shell.run("/bin/ps", ["-axo", "pid=,command="], timeout: 10)
    var pids: [pid_t] = []
    for line in ps.stdout.split(separator: "\n") {
        let text = String(line)
        guard text.contains("ntfs-3g"), text.contains("/dev/\(device)") else { continue }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let pidText = trimmed.split(separator: " ").first, let pid = pid_t(pidText) else { continue }
        pids.append(pid)
    }
    for pid in pids {
        kill(pid, SIGTERM)
    }
    if !pids.isEmpty {
        usleep(800_000)
        for pid in pids where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }
}

func unmountInternal(device: String, mountPoint: String) -> Bool {
    var result = Shell.run("/sbin/umount", [mountPoint], timeout: 20)
    if result.status != 0 {
        result = Shell.run("/sbin/umount", ["-f", mountPoint], timeout: 20)
    }
    if result.status != 0 {
        result = Shell.run("/usr/sbin/diskutil", ["unmount", "force", "/dev/\(device)"], timeout: 20)
    }
    terminateNTFS3G(device: device)
    return result.status == 0 || MountTable.line(forDevice: device) == nil
}

func postMount(_ mountPoint: String) {
    _ = Shell.run("/usr/bin/mdutil", ["-i", "off", mountPoint], timeout: 15)
    let eventsDir = mountPoint + "/.fseventsd"
    try? FileManager.default.createDirectory(atPath: eventsDir, withIntermediateDirectories: true)
    let noLog = eventsDir + "/no_log"
    if !FileManager.default.fileExists(atPath: noLog) {
        FileManager.default.createFile(atPath: noLog, contents: Data())
    }
    let probe = mountPoint + "/.ntfsmount-write-test"
    do {
        try Data([0x41]).write(to: URL(fileURLWithPath: probe))
        try FileManager.default.removeItem(atPath: probe)
    } catch {
        logLine("write probe failed at \(mountPoint): \(error)")
    }
}

func mountDevice(_ device: String) -> HelperResponse {
    guard DeviceID.isValid(device) else {
        return HelperResponse(ok: false, error: "invalid device identifier")
    }

    let info: (label: String, uuid: String)
    do {
        info = try ntfsVolumeInfo(device)
    } catch {
        return HelperResponse(ok: false, error: "\(error)")
    }

    let (uid, gid) = consoleUser()
    let mountPoint = "/Volumes/\(info.label)"
    logLine("mount \(device) label=\(info.label) uid=\(uid) gid=\(gid)")

    if let current = MountTable.info(atPath: mountPoint), current.isMount, !current.readOnly {
        return HelperResponse(ok: true, mountPoint: mountPoint, state: "readWrite")
    }

    let raw = canOpenRaw(device)
    if !raw.ok, raw.errno == EPERM {
        return HelperResponse(
            ok: false,
            error: "macOS denied raw disk access. Grant Full Disk Access to \(Paths.ntfs3g).",
            code: EPERM,
            needsFDA: true
        )
    }

    var lastError = "mount failed"
    for attempt in 0..<4 {
        if attempt > 0 {
            usleep(400_000)
        }
        if let existing = mountedPath(for: device, fallback: mountPoint) {
            _ = unmountInternal(device: device, mountPoint: existing)
        }

        let rawAccess = canOpenRaw(device)
        if !rawAccess.ok {
            if rawAccess.errno == EPERM {
                return HelperResponse(ok: false, error: "macOS denied raw disk access.",
                                      code: EPERM, needsFDA: true)
            }
            if rawAccess.errno == EBUSY {
                usleep(300_000)
                continue
            }
            return HelperResponse(ok: false,
                                  error: "cannot open /dev/\(device): \(String(cString: strerror(rawAccess.errno)))",
                                  code: rawAccess.errno)
        }

        do {
            try ensureMountPoint(mountPoint)
        } catch {
            return HelperResponse(ok: false, error: "\(error)")
        }

        let options = "auto_xattr,uid=\(uid),gid=\(gid),umask=0022,volname=\(info.label)"
        let result = Shell.run(Paths.ntfs3g, ["/dev/\(device)", mountPoint, "-o", options], timeout: 30)
        let output = (result.stderr + "\n" + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            logLine("ntfs-3g[\(device)] status=\(result.status): \(output)")
        }

        if result.status == 0, waitForMount(mountPoint, device: device, timeout: 8) {
            postMount(mountPoint)
            return HelperResponse(ok: true, mountPoint: mountPoint, state: "readWrite")
        }

        lastError = output.isEmpty ? "ntfs-3g exited with status \(result.status)" : output
        if output.contains("Resource busy") || output.contains("already mounted") {
            continue
        }
        if output.contains("Operation not permitted") {
            return HelperResponse(ok: false, error: lastError, code: EPERM, needsFDA: true)
        }
        break
    }

    return HelperResponse(ok: false, error: lastError, code: 1)
}

func unmountDevice(_ device: String) -> HelperResponse {
    guard DeviceID.isValid(device) else {
        return HelperResponse(ok: false, error: "invalid device identifier")
    }
    let info = try? ntfsVolumeInfo(device)
    let fallback = "/Volumes/\(info?.label ?? device)"
    guard let mountPoint = mountedPath(for: device, fallback: fallback) else {
        terminateNTFS3G(device: device)
        return HelperResponse(ok: true, state: "unmounted")
    }
    let ok = unmountInternal(device: device, mountPoint: mountPoint)
    if ok {
        return HelperResponse(ok: true, state: "unmounted")
    }
    return HelperResponse(ok: false, error: "could not unmount \(mountPoint); a process is still using it", code: EBUSY)
}

func ejectDevice(_ device: String) -> HelperResponse {
    guard DeviceID.isValid(device), let whole = DeviceID.wholeDisk(for: device) else {
        return HelperResponse(ok: false, error: "invalid device identifier")
    }
    let unmounted = unmountDevice(device)
    if !unmounted.ok {
        return unmounted
    }
    var result = Shell.run("/usr/sbin/diskutil", ["eject", "/dev/\(whole)"], timeout: 30)
    if result.status != 0 {
        result = Shell.run("/usr/sbin/diskutil", ["eject", "/dev/\(device)"], timeout: 30)
    }
    if result.status == 0 {
        return HelperResponse(ok: true, state: "ejected")
    }
    let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
    return HelperResponse(ok: false, error: message.isEmpty ? "eject failed" : message, code: result.status)
}

func ping() -> HelperResponse {
    HelperResponse(
        ok: true,
        state: "ready",
        ntfs3g: FileManager.default.isExecutableFile(atPath: Paths.ntfs3g),
        fuseT: FileManager.default.fileExists(atPath: Paths.fuseTLibrary)
    )
}

func probe(_ device: String) -> HelperResponse {
    guard DeviceID.isValid(device) else {
        return HelperResponse(ok: false, error: "invalid device identifier")
    }
    let raw = canOpenRaw(device)
    if raw.ok {
        return HelperResponse(ok: true, rawAccess: true)
    }
    return HelperResponse(ok: false, error: String(cString: strerror(raw.errno)),
                          code: raw.errno, needsFDA: raw.errno == EPERM, rawAccess: false)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(HelperResponse(ok: false, error: "usage: ntfsmount-helper <ping|mount|unmount|eject|probe> [device]").jsonLine())
    exit(2)
}

let response: HelperResponse
switch command {
case "ping":
    response = ping()
case "mount":
    response = args.count > 1 ? mountDevice(args[1]) : HelperResponse(ok: false, error: "missing device")
case "unmount":
    response = args.count > 1 ? unmountDevice(args[1]) : HelperResponse(ok: false, error: "missing device")
case "eject":
    response = args.count > 1 ? ejectDevice(args[1]) : HelperResponse(ok: false, error: "missing device")
case "probe":
    response = args.count > 1 ? probe(args[1]) : HelperResponse(ok: false, error: "missing device")
default:
    response = HelperResponse(ok: false, error: "unknown command \(command)")
}

print(response.jsonLine())
exit(response.ok ? 0 : 1)
