import AmpText
import Foundation

/// What AmpBench knows about one kind of Positive Grid device: how it is found, how many slots it has, what may
/// be sent to it and what it does on its own.
///
/// Every device gets only what has been checked on it with the user. Listening (subscribing to what the device reports)
/// is separate from sending: a profile without `.send` must not get a single byte, not even a read request. A device
/// not listed here gets a cautious profile that only reads and switches until it is checked.
///
/// A new device joins as a new profile in `all`; the areas read slots and capabilities from the profile and are not
/// rebuilt for it.
public struct DeviceProfile: Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case sparkMini, sparkNEO, reactor50, reactor100, unknownSpark
    }

    /// How AmpBench reaches the device.
    public enum Transport: String, Sendable {
        /// Bluetooth LE with Spark messages (`F0 01 … F7`) on a control service.
        case sparkBLE
        /// A MIDI output the user picks. Not built yet.
        case midi
        /// Nothing goes to the device; it gets text, such as REACTOR's Text to Tone.
        case textOnly
    }

    public struct Capabilities: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Subscribe to what the device reports by itself. Writes nothing.
        public static let listen = Capabilities(rawValue: 1 << 0)
        /// Write anything at all to the device. Without it, the link writes not one byte.
        public static let send = Capabilities(rawValue: 1 << 1)
        /// Read firmware, name, the playing slot and stored presets.
        public static let read = Capabilities(rawValue: 1 << 2)
        /// Switch to a stored slot.
        public static let switchSlot = Capabilities(rawValue: 1 << 3)
        /// Play a whole preset on the temporary place 7F.
        public static let playTemporary = Capabilities(rawValue: 1 << 4)
        /// Change parameters and switch effects on and off while a preset plays.
        public static let liveEdit = Capabilities(rawValue: 1 << 5)
        /// Store a preset in a slot.
        public static let store = Capabilities(rawValue: 1 << 6)
        /// Replace a model with `01 06`.
        public static let modelChange = Capabilities(rawValue: 1 << 7)
        /// The device reports presses of its own buttons.
        public static let buttonEvents = Capabilities(rawValue: 1 << 8)
        /// The device reports its own tuner. With `send` it can also be switched on from here (`01 65`): checked on
        /// the MINI and the NEO on 2026-11-09, both mute their output while it is on.
        public static let tuner = Capabilities(rawValue: 1 << 9)
        /// The device reports a tapped tempo.
        public static let tapTempo = Capabilities(rawValue: 1 << 10)
        /// The device is an audio input over USB that the area Record may record from.
        public static let usbAudio = Capabilities(rawValue: 1 << 11)
        /// The device takes a sound described in words (REACTOR's Text to Tone).
        public static let textToTone = Capabilities(rawValue: 1 << 12)
        /// The device takes a `ReactorSound`: single live commands for amp, knobs and effects, and nothing else.
        /// Without `send`, so it is still never asked, read or given a preset.
        public static let liveSound = Capabilities(rawValue: 1 << 13)
        /// The device answers `02 01 00 <slot>` with a preset in the REACTOR's own format (`ReactorPreset`), and
        /// `02 10` with the playing slot. Studio asks for these after connecting, and for nothing else.
        public static let reactorPresets = Capabilities(rawValue: 1 << 14)
    }

    public var id: Kind
    /// The name the window shows when the device gives none.
    public var displayName: String
    /// The Bluetooth LE service it advertises and talks on.
    public var bleService: String
    /// Starts of the Bluetooth names it advertises, to tell devices apart before anything is read.
    public var bleNamePrefixes: [String]
    /// What it answers to `02 11`, its amp name.
    public var ampNames: [String]
    /// The MIDI output to choose, once MIDI exists. Nil: none.
    public var midiTarget: String?
    public var slotCount: Int
    /// Slots per bank, for a device whose slots come in banks.
    public var bankSize: Int?
    /// Names of the banks in order, in English, such as "Red" and "Green".
    public var englishBankNames: [String]
    /// The banks' names in the app's language.
    public var bankNames: [String] { englishBankNames.map { tr($0) } }
    public var transport: Transport
    public var capabilities: Capabilities
    /// Whether the device keeps a sound on the temporary place when the control connection ends. Nil: not checked,
    /// which counts as "loses it".
    public var keepsTemporaryAfterDisconnect: Bool?
    /// Whether the device acknowledges a parameter change (`04 04`). No Spark checked so far does.
    public var confirmsParameters: Bool
    /// The firmware it was checked with. Nil when never read.
    public var checkedFirmware: String?
    /// Parts of the USB audio name the area Record may record from. Empty: none is known, so none is allowed.
    public var usbAudioNames: [String]
    /// What was checked on the device, in one sentence, in English.
    public var englishChecked: String
    /// What was checked on the device, in the app's language.
    public var checked: String { tr(englishChecked) }
    /// Text fields as they were heard working on this device, stricter than `AmpGuard`'s limits for every device. Nil:
    /// only those. The NEO sits on the ears, so nothing longer than what it played goes to it (docs/STUDIO.md).
    public var checkedText: CheckedText? = nil

    /// The longest texts a device was heard playing, and the fixed fields it had.
    public struct CheckedText: Equatable, Hashable, Sendable {
        public var nameBytes: Int
        public var descriptionBytes: Int
        public var version: String
        public var icon: String
    }

    public func can(_ capability: Capabilities) -> Bool { capabilities.contains(capability) }

    /// True when the device may get any byte at all.
    public var canSend: Bool { can(.send) }

    /// True when ending the connection drops a sound that plays without being stored. Unchecked counts as true.
    public var losesTemporaryOnDisconnect: Bool { keepsTemporaryAfterDisconnect != true }

    /// The slots as numbers from 0, for loops over them.
    public var slots: Range<Int> { 0..<slotCount }

    /// "Slot 3", or with banks "Green 1" for slot 4.
    public func slotName(_ slot: Int) -> String {
        guard let size = bankSize, size > 0, slot >= 0, slot / size < bankNames.count else { return tr("Slot %d", slot + 1) }
        return "\(bankNames[slot / size]) \(slot % size + 1)"
    }

    /// The bank a slot is in, or nil for a device without banks.
    public func bank(of slot: Int) -> Int? {
        guard let size = bankSize, size > 0, slot >= 0 else { return nil }
        return slot / size
    }
}

public extension DeviceProfile {
    /// The control service of every Spark amp and of the Spark NEO.
    static let sparkService = "FFC0"
    /// REACTOR's control service. It speaks Spark frames on the same characteristics FFC1 and FFC2.
    static let reactorService = "FFD0"
    /// The services the Bluetooth search filters on. Nothing else nearby is ever seen.
    static let searchedServices = [sparkService, reactorService]

    /// Checked with the user on 2026-11-07/08: everything AmpBench does.
    static let sparkMini = DeviceProfile(
        id: .sparkMini, displayName: "Spark MINI", bleService: sparkService, bleNamePrefixes: ["Spark MINI"],
        ampNames: ["Spark MINI"], slotCount: 4, englishBankNames: [], transport: .sparkBLE,
        capabilities: [.listen, .send, .read, .switchSlot, .playTemporary, .liveEdit, .store, .modelChange,
                       .buttonEvents, .tuner, .tapTempo, .usbAudio],
        keepsTemporaryAfterDisconnect: nil, confirmsParameters: false, checkedFirmware: "1.11.2.75",
        usbAudioNames: ["spark"],
        englishChecked: "Reading, switching, trying out, live changes, model changes, saving and its own tuner, firmware 1.11.2.75.")

    /// Checked with the user on 2026-11-09 with spark-probe: same protocol and preset format as the MINI. Its
    /// headphones showed no audio device on USB-C, so the area Record cannot record from it.
    static let sparkNEO = DeviceProfile(
        id: .sparkNEO, displayName: "Spark NEO", bleService: sparkService, bleNamePrefixes: ["Spark NEO"],
        ampNames: ["Spark NEO"], slotCount: 4, englishBankNames: [], transport: .sparkBLE,
        capabilities: [.listen, .send, .read, .switchSlot, .playTemporary, .liveEdit, .store, .modelChange,
                       .buttonEvents, .tuner],
        keepsTemporaryAfterDisconnect: false, confirmsParameters: false, checkedFirmware: "1.16.1.60",
        usbAudioNames: [],
        englishChecked: "Reading, switching, trying out, live changes, model changes, saving, the middle button and its own tuner, firmware 1.16.1.60. Disconnecting discards the temporary sound.",
        // Heard on 2026-11-09: factory names of at most 7 bytes and spark-probe's copies "SOLO Test" and
        // "HI GAIN Test" (12 bytes), never a description, version "0.7", icon "icon.png".
        checkedText: CheckedText(nameBytes: 12, descriptionBytes: 0, version: "0.7", icon: "icon.png"))

    /// Checked listen-only on 2026-11-09. On 2026-11-10, with the owner at the device, it answered read requests and
    /// took single live commands, heard by the owner: gain and bass (`01 04`), reverb on and off (`01 15`), reverb
    /// level, and the amp selector (`01 B1`). So it takes a `ReactorSound`, and still nothing else: no `send`.
    static let reactor50 = DeviceProfile(
        id: .reactor50, displayName: "REACTOR 50", bleService: reactorService, bleNamePrefixes: ["Reactor 50"],
        ampNames: [], slotCount: 8, bankSize: 4, englishBankNames: ["Red", "Green"], transport: .sparkBLE,
        capabilities: [.listen, .buttonEvents, .tuner, .tapTempo, .usbAudio, .textToTone, .liveSound,
                       .reactorPresets],
        keepsTemporaryAfterDisconnect: nil, confirmsParameters: false, checkedFirmware: "0.1.4.85",
        // Its USB audio name was not read yet; it joins once read on the device, so nothing is guessed.
        usbAudioNames: [],
        englishChecked: "Read along: knobs, amp choice, Push/Smooth, Heat, effects, TAP, preset, bank and tuner. Sent and heard (2026-11-10): gain, bass, reverb on/off and level, amp choice. No preset.")

    /// Like the REACTOR 50, but never checked.
    static let reactor100: DeviceProfile = {
        var profile = reactor50
        profile.id = .reactor100
        profile.displayName = "REACTOR 100"
        profile.bleNamePrefixes = ["Reactor 100"]
        // Never checked: it is only listened to, whatever the 50 takes.
        profile.capabilities.remove([.liveSound, .reactorPresets])
        profile.checkedFirmware = nil
        profile.englishChecked = "Not checked. Treated like the REACTOR 50: read only, send nothing."
        return profile
    }()

    /// A Spark device nobody has checked yet: it may be read and switched, nothing more.
    static let unknownSpark = DeviceProfile(
        id: .unknownSpark, displayName: "Spark", bleService: sparkService, bleNamePrefixes: ["Spark"],
        ampNames: [], slotCount: 4, englishBankNames: [], transport: .sparkBLE,
        capabilities: [.listen, .send, .read, .switchSlot, .buttonEvents],
        keepsTemporaryAfterDisconnect: nil, confirmsParameters: false, checkedFirmware: nil,
        usbAudioNames: [],
        englishChecked: "Not checked. Reading and switching only, until the device is checked with the user.")

    static let all: [DeviceProfile] = [sparkMini, sparkNEO, reactor50, reactor100, unknownSpark]

    static func profile(_ kind: Kind) -> DeviceProfile {
        all.first { $0.id == kind } ?? unknownSpark
    }

    /// The profile from what a device advertises, before anything is read. The service decides the product line:
    /// FFD0 is a REACTOR, recognised without any request. A Spark device is told apart by its Bluetooth name and is
    /// confirmed by its amp name (`02 11`) once connected.
    static func forAdvertisement(service: String, name: String?) -> DeviceProfile {
        let name = name ?? ""
        if service.uppercased() == reactorService {
            return name.lowercased().hasPrefix("reactor 100") ? reactor100 : reactor50
        }
        return all.first { profile in
            profile.bleService == sparkService && profile.id != .unknownSpark
                && profile.bleNamePrefixes.contains { name.lowercased().hasPrefix($0.lowercased()) }
        } ?? unknownSpark
    }

    /// The profile for the amp name a Spark device answers to `02 11`, such as "Spark NEO". Nil for a name no
    /// profile knows.
    static func forAmpName(_ ampName: String) -> DeviceProfile? {
        let name = ampName.trimmingCharacters(in: .whitespaces).lowercased()
        return all.first { $0.ampNames.contains { $0.lowercased() == name } }
    }

    /// A device's name as it may appear in a log or in the probe's output. REACTOR's Bluetooth name ends in a part its
    /// owner chose; that part is cut off: "Reactor 50 Wohnzimmer" becomes "Reactor 50".
    static func loggableName(_ name: String?) -> String {
        guard let name else { return "?" }
        let lower = name.lowercased()
        for prefix in ["reactor 100", "reactor 50"] where lower.hasPrefix(prefix) {
            return String(name.prefix(prefix.count))
        }
        return name
    }

    /// Parts of USB audio names the area Record may record from, from every profile.
    static var recordableUSBNames: [String] {
        var names: [String] = []
        for name in all.flatMap(\.usbAudioNames) where !names.contains(name) { names.append(name) }
        return names
    }

    /// The largest slot count of any profile, for shortcuts and lists that must hold every device.
    static var largestSlotCount: Int { all.map(\.slotCount).max() ?? 4 }
}
