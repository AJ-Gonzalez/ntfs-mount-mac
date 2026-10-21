import AppKit
import Dispatch
import Foundation
import ServiceManagement
import NTFSMountCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var volumes: [NTFSVolume] = []
    @Published private(set) var helperReady = false
    @Published private(set) var busyDevices: Set<String> = []
    @Published private(set) var installingHelper = false
    @Published var needsFDA = false
    @Published var errorMessage: String?
    @Published var autoMount: Bool {
        didSet { UserDefaults.standard.set(autoMount, forKey: Defaults.autoMount) }
    }
    @Published var fightBack: Bool {
        didSet { UserDefaults.standard.set(fightBack, forKey: Defaults.fightBack) }
    }
    @Published var launchAtLogin: Bool = false

    private enum Defaults {
        static let autoMount = "autoMount"
        static let fightBack = "fightBack"
        static let ignored = "ignoredVolumeUUIDs"
    }

    private var ignoredUUIDs: Set<String>
    private var lastAttempt: [String: Date] = [:]
    private var failureCount: [String: Int] = [:]
    private var refreshInFlight = false
    private var lastHelperCheck = Date.distantPast
    private var monitor: DiskMonitor?
    private var timer: Timer?

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Defaults.autoMount) == nil {
            defaults.set(true, forKey: Defaults.autoMount)
        }
        if defaults.object(forKey: Defaults.fightBack) == nil {
            defaults.set(true, forKey: Defaults.fightBack)
        }
        autoMount = defaults.bool(forKey: Defaults.autoMount)
        fightBack = defaults.bool(forKey: Defaults.fightBack)
        ignoredUUIDs = Set(defaults.stringArray(forKey: Defaults.ignored) ?? [])
        launchAtLogin = SMAppService.mainApp.status == .enabled

        monitor = DiskMonitor(
            onChange: { [weak self] in self?.refresh() },
            onWake: { [weak self] in self?.refresh(forceHelperCheck: true) }
        )
        monitor?.start()

        refresh(forceHelperCheck: true)
        timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    var anyWritable: Bool { volumes.contains(where: \.isWritable) }

    var menuBarSymbol: String {
        anyWritable ? "externaldrive.fill.badge.checkmark" : "externaldrive"
    }

    func refresh(forceHelperCheck: Bool = false) {
        guard !refreshInFlight else { return }
        refreshInFlight = true

        let shouldCheck = forceHelperCheck || Date().timeIntervalSince(lastHelperCheck) > 20
        DispatchQueue.global(qos: .utility).async {
            let enumerated = DiskEnumerator.enumerate()
            let ready = shouldCheck ? Self.checkHelper() : nil
            DispatchQueue.main.async {
                self.refreshInFlight = false
                self.volumes = enumerated
                if let ready {
                    self.helperReady = ready
                    self.lastHelperCheck = Date()
                }
                let present = Set(enumerated.map(\.uuid))
                self.ignoredUUIDs.formIntersection(present)
                self.persistIgnored()
                self.runAutomation()
            }
        }
    }

    nonisolated private static func checkHelper() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Paths.helper) else { return false }
        let result = Shell.run("/usr/bin/sudo", ["-n", Paths.helper, "ping"], timeout: 10)
        return result.status == 0 && result.stdout.contains("\"ok\":true")
    }

    private func runAutomation() {
        guard helperReady, autoMount else { return }
        let now = Date()
        for volume in volumes {
            guard !volume.isWritable, !ignoredUUIDs.contains(volume.uuid) else { continue }
            if volume.state == .readOnly && !fightBack { continue }
            if let last = lastAttempt[volume.device], now.timeIntervalSince(last) < 8 { continue }
            if let failures = failureCount[volume.device], failures >= 3,
               let last = lastAttempt[volume.device], now.timeIntervalSince(last) < 60 { continue }
            mount(volume, automatic: true)
        }
    }

    func mount(_ volume: NTFSVolume, automatic: Bool = false) {
        guard !busyDevices.contains(volume.device) else { return }
        guard helperReady else {
            if !automatic { errorMessage = "Privileged helper is not installed. Click Install Helper." }
            return
        }
        busyDevices.insert(volume.device)
        lastAttempt[volume.device] = Date()

        DispatchQueue.global(qos: .userInitiated).async {
            if volume.state == .readOnly {
                _ = HelperClient.call(["unmount", volume.device], timeout: 30)
                Thread.sleep(forTimeInterval: 0.4)
            }
            let response = HelperClient.call(["mount", volume.device])
            DispatchQueue.main.async {
                self.busyDevices.remove(volume.device)
                self.handle(response, device: volume.device, automatic: automatic)
            }
        }
    }

    func unmount(_ volume: NTFSVolume) {
        guard !busyDevices.contains(volume.device) else { return }
        busyDevices.insert(volume.device)
        DispatchQueue.global(qos: .userInitiated).async {
            let response = HelperClient.call(["unmount", volume.device])
            DispatchQueue.main.async {
                self.busyDevices.remove(volume.device)
                self.ignoredUUIDs.insert(volume.uuid)
                self.persistIgnored()
                self.handle(response, device: volume.device, automatic: false)
            }
        }
    }

    func eject(_ volume: NTFSVolume) {
        guard !busyDevices.contains(volume.device) else { return }
        busyDevices.insert(volume.device)
        ignoredUUIDs.insert(volume.uuid)
        persistIgnored()

        DispatchQueue.global(qos: .userInitiated).async {
            let response = HelperClient.call(["eject", volume.device])
            DispatchQueue.main.async {
                self.busyDevices.remove(volume.device)
                self.handle(response, device: volume.device, automatic: false)
            }
        }
    }

    private func handle(_ response: HelperResponse?, device: String, automatic: Bool) {
        guard let response else {
            errorMessage = "Could not reach the privileged helper. Reinstall it from this menu."
            helperReady = false
            return
        }
        if response.ok {
            failureCount[device] = 0
            needsFDA = false
            if !automatic { errorMessage = nil }
            refresh(forceHelperCheck: false)
            return
        }

        failureCount[device, default: 0] += 1
        if response.needsFDA == true {
            needsFDA = true
        }
        if !automatic {
            errorMessage = response.error ?? "Operation failed"
        } else if response.needsFDA == true {
            errorMessage = response.error
        }
    }

    func reveal(_ volume: NTFSVolume) {
        let path = volume.mountPoint ?? "/Volumes/\(volume.label)"
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openFDASettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
        if let url { NSWorkspace.shared.open(url) }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Paths.ntfs3g)])
    }

    func installHelper() {
        guard !installingHelper else { return }
        guard let resources = Bundle.main.resourceURL else {
            errorMessage = "Application resources are missing."
            return
        }
        installingHelper = true
        errorMessage = nil
        let script = resources.appendingPathComponent("install-helper.sh").path
        let command = "/bin/bash \(shellQuote(script)) \(shellQuote(resources.path))"
        let appleScript = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Shell.run("/usr/bin/osascript", ["-e", appleScript], timeout: 300)
            DispatchQueue.main.async {
                self.installingHelper = false
                if result.status != 0 {
                    let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.errorMessage = message.isEmpty ? "Helper installation failed." : message
                    return
                }
                self.refresh(forceHelperCheck: true)
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func persistIgnored() {
        UserDefaults.standard.set(Array(ignoredUUIDs), forKey: Defaults.ignored)
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func appleScriptEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}
