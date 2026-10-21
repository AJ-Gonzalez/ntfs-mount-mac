import Foundation
import NTFSMountCore

struct NTFSVolume: Identifiable, Equatable, Sendable {
    enum State: String, Sendable {
        case readWrite
        case readOnly
        case unmounted
    }

    var device: String
    var label: String
    var size: Int64
    var uuid: String
    var wholeDisk: String
    var mountPoint: String?
    var state: State
    var freeSpace: Int64?

    var id: String { device }

    var isWritable: Bool { state == .readWrite }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var freeText: String? {
        guard let freeSpace else { return nil }
        return ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file) + " free"
    }
}

enum DiskEnumerator {
    static func sanitize(_ raw: String?, device: String) -> String {
        var label = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let forbidden = CharacterSet(charactersIn: "/:\0\n\r\t")
        label = label.components(separatedBy: forbidden).joined(separator: "-")
        if label.isEmpty || label == "." || label == ".." {
            label = "NTFS-\(device)"
        }
        return String(label.prefix(64))
    }

    static func diskInfo(_ device: String) -> [String: Any]? {
        let result = Shell.run("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(device)"], timeout: 15)
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return nil
        }
        return plist
    }

    static func enumerate() -> [NTFSVolume] {
        let listing = Shell.run("/usr/sbin/diskutil", ["list", "-plist"], timeout: 20)
        guard listing.status == 0,
              let data = listing.stdout.data(using: .utf8),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }

        var volumes: [NTFSVolume] = []
        for disk in disks {
            let wholeDisk = disk["DeviceIdentifier"] as? String ?? ""
            guard let partitions = disk["Partitions"] as? [[String: Any]] else { continue }
            for partition in partitions {
                let content = (partition["Content"] as? String) ?? ""
                guard content == "Windows_NTFS" || content == "Microsoft Basic Data" else { continue }
                guard let device = partition["DeviceIdentifier"] as? String else { continue }

                var details = partition
                if content != "Windows_NTFS" {
                    guard let info = diskInfo(device), (info["FilesystemType"] as? String)?.lowercased() == "ntfs" else {
                        continue
                    }
                    details = info
                }

                let rawLabel = details["VolumeName"] as? String
                let label = sanitize(rawLabel, device: device)
                let expectedMount = "/Volumes/\(label)"
                let reportedMount = details["MountPoint"] as? String
                let size = (details["Size"] as? NSNumber)?.int64Value
                    ?? (partition["Size"] as? NSNumber)?.int64Value ?? 0
                let uuid = (details["VolumeUUID"] as? String) ?? (partition["VolumeUUID"] as? String) ?? device

                var mountPoint: String?
                var state: NTFSVolume.State = .unmounted

                if let reportedMount, !reportedMount.isEmpty {
                    mountPoint = reportedMount
                    let info = MountTable.info(atPath: reportedMount)
                    state = (info?.readOnly == false) ? .readWrite : .readOnly
                } else if let info = MountTable.info(atPath: expectedMount), info.isMount {
                    mountPoint = expectedMount
                    state = info.readOnly ? .readOnly : .readWrite
                }

                var freeSpace: Int64?
                if let mountPoint {
                    freeSpace = MountTable.space(atPath: mountPoint)
                }

                volumes.append(
                    NTFSVolume(
                        device: device,
                        label: label,
                        size: size,
                        uuid: uuid,
                        wholeDisk: wholeDisk,
                        mountPoint: mountPoint,
                        state: state,
                        freeSpace: freeSpace
                    )
                )
            }
        }
        return volumes.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}
