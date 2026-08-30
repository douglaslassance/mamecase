import Combine
import Foundation
import IOKit
import IOKit.hid

/// A game controller as reported by IOKit's HID manager.
struct GameControllerDevice: Hashable, Identifiable, Sendable {
    let vendorID: Int
    let productID: Int
    let name: String

    /// Canonical identity used inside `ControllerProfileStore` keys.
    /// Vendor and product IDs only. The product string is for display,
    /// since it varies in whitespace and suffixes between firmware
    /// revisions of the same adapter.
    var id: String { String(format: "%04x:%04x", vendorID, productID) }
}

/// Watches which gamepads are plugged in, so the controller-profile
/// picker can key off the hardware actually present.
///
/// IOKit rather than the GameController framework, for two reasons.
/// `GCController` only adopts devices matching a known gamepad profile,
/// which skips bare USB adapters presenting as a plain two-axis
/// joystick (an original SNES pad on a RetroPort is exactly that).
/// IOKit also sees the same device set MAME's SDL backend does, so the
/// names shown here match the ones MAME lists in its own input menu.
///
/// Only device *properties* are read. We never call `IOHIDDeviceOpen`,
/// so this triggers no Input Monitoring permission prompt.
///
/// A singleton because the HID manager is a process-global resource,
/// and because `Library` resolves profiles at launch time without
/// having a view's environment to hand.
@MainActor
final class ControllerDetector: ObservableObject {
    static let shared = ControllerDetector()

    /// Connected pads, sorted by identity so the ordering is canonical
    /// and independent of the order things were plugged in.
    @Published private(set) var connected: [GameControllerDevice] = []

    private var manager: IOHIDManager?

    private init() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        // Re-enumerate wholesale on any change rather than tracking adds
        // and removals incrementally. The device count is tiny and a full
        // rescan cannot drift out of sync with reality.
        let callback: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            let detector = Unmanaged<ControllerDetector>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in detector.refresh() }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, callback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, callback, context)
        IOHIDManagerScheduleWithRunLoop(manager,
                                        CFRunLoopGetMain(),
                                        CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        self.manager = manager
        refresh()
    }

    private func refresh() {
        guard let manager else { return }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        var found: [GameControllerDevice] = []
        for device in devices {
            guard let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
                  let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int
            else { continue }
            let raw = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            found.append(GameControllerDevice(vendorID: vendor,
                                              productID: product,
                                              name: raw.isEmpty ? "Unknown controller" : raw))
        }
        // A pad exposing several HID interfaces enumerates once per
        // interface but is one controller to the user, so collapse by id.
        var seen = Set<String>()
        let unique = found
            .sorted { $0.id < $1.id }
            .filter { seen.insert($0.id).inserted }
        if unique != connected { connected = unique }
    }
}
