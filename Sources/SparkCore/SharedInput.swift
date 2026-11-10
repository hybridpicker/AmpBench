import AmpText
import Foundation

/// An input that belongs to someone else, such as the recorder's, which a listener like the tuner may read along with.
///
/// The owner keeps its one audio unit. Sharing never changes, restarts or ends a running recording or retro buffer:
/// it opens the input only when it is closed, and closes it again only when nothing else needs it.
@MainActor
public protocol SharedInput: AnyObject {
    /// The device the owner listens to, if one is chosen.
    var device: InputDevice? { get }
    /// True while a recording, the retro buffer or the level check keep the input open anyway.
    var isHeldOpen: Bool { get }
    /// False when only the owner's devices may be heard at all, such as with a test library.
    var allowsOtherInputs: Bool { get }
    /// Starts writing the input into `tap`, opening it if needed.
    func share(with tap: AudioTap) async throws
    /// Stops writing into `tap`, and closes the input if nothing else needs it.
    func stopSharing(with tap: AudioTap)
    func isSharing(with tap: AudioTap) -> Bool
    /// True for a device the owner may use. The tuner never opens such a device beside the owner, because two units
    /// on one device could change its rate under a running recording.
    func owns(_ device: InputDevice) -> Bool
}

/// Why sharing an input did not start.
public enum SharedInputError: LocalizedError, Equatable {
    case noDevice
    case noPermission

    public var errorDescription: String? {
        switch self {
        case .noDevice: tr("No Spark connected.")
        case .noPermission:
            tr("Microphone access is missing. Allow it in System Settings → Privacy & Security → Microphone.")
        }
    }
}
