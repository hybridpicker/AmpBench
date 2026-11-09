import CoreAudio
import Foundation

/// Decides which devices may be opened as an input at all.
///
/// The capture engine checks this before it touches a device, so no feature can record from anything else. The app
/// only records from a Spark amp on USB. Without one, it records nothing and never falls back to the microphone.
public struct InputPolicy: Sendable {
    /// The private device the tests create and destroy to simulate a pulled cable.
    public static let testDeviceName = "SparkRecorder Test Device"

    private let rule: @Sendable (_ name: String, _ transport: UInt32) -> Bool

    private init(rule: @escaping @Sendable (_ name: String, _ transport: UInt32) -> Bool) {
        self.rule = rule
    }

    public func allows(name: String, transport: UInt32) -> Bool {
        rule(name, transport)
    }

    public func allows(_ device: InputDevice) -> Bool {
        allows(name: device.name, transport: device.transport)
    }

    /// A USB device with "Spark" in its name. The manufacturer cannot be used, because the Spark Mini reports its USB
    /// chip's maker instead of Positive Grid.
    public static let sparkOnly = usbDevices(named: ["spark"])

    /// A USB device whose name contains one of `parts`, ignoring case. Spark Studio passes the USB audio names of its
    /// device profiles (SparkControl's `DeviceProfile.usbAudioNames`), each read from the device, never guessed.
    public static func usbDevices(named parts: [String]) -> InputPolicy {
        let parts = parts.filter { !$0.isEmpty }
        return InputPolicy { name, transport in
            transport == kAudioDeviceTransportTypeUSB
                && parts.contains { name.range(of: $0, options: .caseInsensitive) != nil }
        }
    }

    /// Virtual test devices only, so tests can never hear a real input, not even the amp.
    public static let testDevices = InputPolicy { name, transport in
        (transport == kAudioDeviceTransportTypeVirtual && name.contains("BlackHole")) || isTestAggregate(name, transport)
    }

    /// Only the test device that can come and go, standing in for a single amp.
    public static let testAggregateOnly = InputPolicy { name, transport in
        isTestAggregate(name, transport)
    }

    /// Any device, for a listener that only reads, such as the tuner on an input that is not a Spark. Never used for
    /// recording: the recorder's engine always has `sparkOnly` or a test policy.
    public static let listenOnly = InputPolicy { _, _ in true }

    /// No device at all, standing in for "no amp connected".
    public static let nothing = InputPolicy { _, _ in false }

    private static func isTestAggregate(_ name: String, _ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeAggregate && name == testDeviceName
    }
}
