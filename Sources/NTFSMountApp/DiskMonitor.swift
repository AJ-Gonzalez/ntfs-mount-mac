import AppKit
import DiskArbitration
import Foundation

final class DiskMonitor {
    private let onChange: () -> Void
    private let onWake: () -> Void
    private var session: DASession?
    private var wakeObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "com.aliciajadzia.ntfsmount.diskarbitration")
    private var pendingRefresh: DispatchWorkItem?

    init(onChange: @escaping () -> Void, onWake: @escaping () -> Void) {
        self.onChange = onChange
        self.onWake = onWake
    }

    func start() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        DASessionSetDispatchQueue(session, queue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { _, context in
            guard let context else { return }
            Unmanaged<DiskMonitor>.fromOpaque(context).takeUnretainedValue().scheduleRefresh()
        }, context)

        DARegisterDiskDisappearedCallback(session, nil, { _, context in
            guard let context else { return }
            Unmanaged<DiskMonitor>.fromOpaque(context).takeUnretainedValue().scheduleRefresh()
        }, context)

        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { _, _, context in
            guard let context else { return }
            Unmanaged<DiskMonitor>.fromOpaque(context).takeUnretainedValue().scheduleRefresh()
        }, context)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onWake()
        }
    }

    private func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onChange() }
            self.pendingRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
