import AppKit
import SwiftUI
import NTFSMountCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !model.helperReady {
                helperCard
            }
            if model.needsFDA {
                fdaCard
            }

            if model.volumes.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(model.volumes) { volume in
                        VolumeRow(volume: volume)
                    }
                }
            }

            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        model.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.10)))
            }

            Divider()
            options
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 372)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.menuBarSymbol)
                .font(.system(size: 18, weight: .medium))
            VStack(alignment: .leading, spacing: 1) {
                Text("NTFS Mount")
                    .font(.system(size: 14, weight: .semibold))
                Text(model.anyWritable ? "Writable NTFS volume attached" : "NTFS volume manager")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(model.helperReady ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .help(model.helperReady ? "Helper ready" : "Helper not installed")
            Button {
                model.refresh(forceHelperCheck: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
    }

    private var helperCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("One-time helper installation", systemImage: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
            Text("Installs a root-only helper and the ntfs-3g driver. macOS will ask for your administrator password once.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model.installingHelper ? "Installing…" : "Install Helper") {
                    model.installHelper()
                }
                .disabled(model.installingHelper)
                if model.installingHelper {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }

    private var fdaCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Full Disk Access required", systemImage: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text("macOS blocks raw disk access until ntfs-3g is listed under Privacy & Security → Full Disk Access. Add it, then retry.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Full Disk Access") { model.openFDASettings() }
                Button("Reveal ntfs-3g") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Paths.ntfs3g)])
                }
            }
            .font(.system(size: 11))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
            Text("No NTFS volumes detected")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("Mount new drives automatically", isOn: $model.autoMount)
            Toggle("Keep drives writable", isOn: $model.fightBack)
            Toggle("Block disk sleep while mounted", isOn: $model.keepDisksAwake)
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 12))
    }

    private var footer: some View {
        HStack {
            Text("Yukina-safe NTFS write layer")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { model.quit() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
    }
}

private struct VolumeRow: View {
    @EnvironmentObject private var model: AppModel
    let volume: NTFSVolume

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(iconColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.label)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                statusPill
            }

            HStack(spacing: 10) {
                if volume.isWritable {
                    Button("Unmount") { model.unmount(volume) }
                    Button("Eject") { model.eject(volume) }
                } else if volume.state == .readOnly {
                    Button("Make Writable") { model.mount(volume) }
                    Button("Eject") { model.eject(volume) }
                } else {
                    Button("Mount") { model.mount(volume) }
                }
                Spacer()
                if volume.mountPoint != nil {
                    Button("Reveal") { model.reveal(volume) }
                }
                if model.busyDevices.contains(volume.device) {
                    ProgressView().controlSize(.mini)
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .disabled(model.busyDevices.contains(volume.device) || !model.helperReady)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var icon: String {
        switch volume.state {
        case .readWrite: return "externaldrive.fill.badge.checkmark"
        case .readOnly: return "externaldrive.badge.exclamationmark"
        case .unmounted: return "externaldrive"
        }
    }

    private var iconColor: Color {
        switch volume.state {
        case .readWrite: return .green
        case .readOnly: return .orange
        case .unmounted: return .secondary
        }
    }

    private var subtitle: String {
        var parts = [volume.sizeText]
        if let free = volume.freeText { parts.append(free) }
        parts.append(volume.device)
        return parts.joined(separator: " · ")
    }

    private var statusPill: some View {
        Text(pillText)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(pillColor.opacity(0.14)))
            .foregroundStyle(pillColor)
    }

    private var pillText: String {
        switch volume.state {
        case .readWrite: return "READ & WRITE"
        case .readOnly: return "READ ONLY"
        case .unmounted: return "NOT MOUNTED"
        }
    }

    private var pillColor: Color {
        switch volume.state {
        case .readWrite: return .green
        case .readOnly: return .orange
        case .unmounted: return .secondary
        }
    }
}
