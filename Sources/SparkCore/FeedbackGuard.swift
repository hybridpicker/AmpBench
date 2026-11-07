import Foundation

/// The device facts the feedback check needs. Independent of Core Audio so it can be tested with any combination.
public struct DeviceIdentity: Hashable, Sendable {
    public let uid: String
    public let modelUID: String
    public let name: String
    public let isBuiltIn: Bool

    public init(uid: String, modelUID: String, name: String, isBuiltIn: Bool) {
        self.uid = uid
        self.modelUID = modelUID
        self.name = name
        self.isBuiltIn = isBuiltIn
    }

    /// The amp reports output and input as two devices, so a shared name is also treated as the same hardware.
    var normalizedName: String { name.lowercased().trimmingCharacters(in: .whitespaces) }
    var isSpark: Bool { normalizedName.contains("spark") }
    var isSpeaker: Bool {
        isBuiltIn && (normalizedName.contains("speaker") || normalizedName.contains("lautsprecher"))
    }
    var isMicrophone: Bool {
        isBuiltIn && (normalizedName.contains("microphone") || normalizedName.contains("mikrofon"))
    }
}

public enum FeedbackRisk: Equatable, Sendable {
    case none
    /// Output and input are the same hardware, so output could end up in the recording.
    case sameHardware
    /// Speakers can reach the microphone through the air.
    case acoustic
}

/// Decides whether sound may go to an output while an input is being recorded.
///
/// Nothing here assumes how the amp behaves. Output to the same hardware stays blocked until a measurement on that
/// exact pair of devices has shown that output does not arrive at the input.
public enum FeedbackGuard {
    public static func pairKey(input: DeviceIdentity, output: DeviceIdentity) -> String {
        "\(input.uid)|\(output.uid)"
    }

    public static func assess(input: DeviceIdentity?, output: DeviceIdentity?,
                              measuredClean: Set<String> = []) -> FeedbackRisk {
        guard let input, let output else { return .none }
        if measuredClean.contains(pairKey(input: input, output: output)) { return .none }
        if input.uid == output.uid && !input.uid.isEmpty { return .sameHardware }
        if !input.modelUID.isEmpty && input.modelUID == output.modelUID && !input.isBuiltIn { return .sameHardware }
        if input.normalizedName == output.normalizedName { return .sameHardware }
        if input.isSpark && output.isSpark { return .sameHardware }
        if input.isMicrophone && output.isSpeaker { return .acoustic }
        return .none
    }

    public static func explanation(_ risk: FeedbackRisk) -> String? {
        switch risk {
        case .none:
            return nil
        case .sameHardware:
            return "Ausgabe und Eingang sind dasselbe Gerät. Der Ton könnte in der Aufnahme landen, deshalb ist die Ausgabe dort während einer Aufnahme gesperrt."
        case .acoustic:
            return "Der Lautsprecher würde vom Mikrofon mit aufgenommen. Wähle während der Aufnahme Kopfhörer."
        }
    }

    /// A device for the click that is safe for this input, preferring the current system output.
    public static func safeOutput(for input: DeviceIdentity?, among outputs: [OutputDevice],
                                  preferred: OutputDevice?, measuredClean: Set<String> = []) -> OutputDevice? {
        func isSafe(_ output: OutputDevice) -> Bool {
            assess(input: input, output: output.identity, measuredClean: measuredClean) == .none
        }
        if let preferred, isSafe(preferred) { return preferred }
        return outputs.first { $0.identity.isBuiltIn && isSafe($0) } ?? outputs.first(where: isSafe)
    }
}
