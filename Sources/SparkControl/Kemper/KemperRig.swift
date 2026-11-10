import AmpText
import Foundation

/// One rig of a Kemper Profiler, read from its SysEx messages: the strings (names of rig, amp and cabinet) and the
/// numeric parameters by address page and number. Values are the Kemper's 14-bit numbers, 0 to 16383, with 8192 in
/// the middle for knobs that go both ways.
///
/// Read only. AmpBench never sends anything to a Kemper.
public struct KemperRig: Equatable, Sendable {
    /// String parameter number to text, see `KemperRig.Tag`.
    public var strings: [Int: String]
    /// Address page to (parameter number to value).
    public var pages: [Int: [Int: Int]]

    public init(strings: [Int: String] = [:], pages: [Int: [Int: Int]] = [:]) {
        self.strings = strings
        self.pages = pages
    }

    /// String parameter numbers as they appear in rig files. The Kemper's MIDI documentation lists the amp's strings
    /// six lower (10 for the amp name); the files of OS 2 to 5 use 16 and up, the cabinet's match the documentation.
    public enum Tag {
        public static let rigName = 1
        public static let rigAuthor = 2
        public static let rigComment = 4
        public static let ampName = 16
        public static let ampMaker = 21
        public static let ampModel = 24
        public static let ampChannel = 25
        public static let pickup = 26
        public static let cabName = 32
        public static let cabMaker = 37
        public static let speakerModel = 45
    }

    /// Address pages from the Kemper's MIDI parameter documentation.
    public enum Page {
        public static let rig = 4
        public static let amp = 10
        public static let equalizer = 11
        public static let cabinet = 12
        public static let stompA = 50, stompB = 51, stompC = 52, stompD = 53, stompX = 56, mod = 58
        public static let delay = 60
        public static let reverb = 61
        /// Delay and reverb of OS 2 and 3, before they became effect modules. OS 4 and 5 still write them.
        public static let oldDelay = 74
        public static let oldReverb = 75
    }

    /// The effect modules in signal order: A to D before the amp, then X, MOD, DLY and REV after it.
    public static let modules: [(page: Int, name: String)] = [
        (Page.stompA, "A"), (Page.stompB, "B"), (Page.stompC, "C"), (Page.stompD, "D"),
        (Page.stompX, "X"), (Page.mod, "MOD"), (Page.delay, "DLY"), (Page.reverb, "REV"),
    ]

    public func string(_ tag: Int) -> String? {
        guard let text = strings[tag]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    public func value(_ page: Int, _ parameter: Int) -> Int? { pages[page]?[parameter] }

    public var name: String { string(Tag.rigName) ?? tr("No name") }

    /// Maker, model and name of the profiled amp, as far as the rig names them, for finding a Spark model.
    public var ampDescription: String {
        var parts: [String] = []
        for tag in [Tag.ampMaker, Tag.ampModel, Tag.ampName] {
            if let text = string(tag), !parts.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                parts.append(text)
            }
        }
        return parts.joined(separator: " ")
    }

    /// True for a rig without a real profile: no amp named at all, or the Kemper's own "Crunch Amp" that fills new
    /// performances, whose date field still holds the template text "AmpCreationDateTag".
    public var isPlaceholder: Bool {
        guard string(Tag.ampModel) == nil, string(Tag.ampMaker) == nil else { return false }
        guard let amp = string(Tag.ampName) else { return true }
        return amp == "Crunch Amp" || string(18) == "AmpCreationDateTag"
    }

    /// A knob from 0 to 10, or nil when the rig does not have it.
    public func knob(_ page: Int, _ parameter: Int) -> Double? {
        value(page, parameter).map { Self.tenths(Double($0) / 16383 * 10) }
    }

    /// A knob that goes both ways, −5 to +5 with 0 in the middle, such as the amp's equalizer.
    public func signedKnob(_ page: Int, _ parameter: Int) -> Double? {
        value(page, parameter).map { Self.tenths(Double($0 - 8192) / 8192 * 5) }
    }

    public var gain: Double? { knob(Page.amp, 4) }

    /// The amp's equalizer, −5 to +5: bass, middle, treble, presence.
    public var equalizer: (bass: Double, middle: Double, treble: Double, presence: Double) {
        (signedKnob(Page.equalizer, 4) ?? 0, signedKnob(Page.equalizer, 5) ?? 0,
         signedKnob(Page.equalizer, 6) ?? 0, signedKnob(Page.equalizer, 7) ?? 0)
    }

    /// The rig's tempo when it uses one. The Kemper keeps it as beats per minute times 64.
    public var tempo: Double? {
        guard value(Page.rig, 2) == 1, let raw = value(Page.rig, 0) else { return nil }
        let bpm = (Double(raw) / 64).rounded()
        return (40...250).contains(bpm) ? bpm : nil
    }

    /// An effect module that holds an effect, with what it is and whether it is on.
    public struct Module: Equatable, Sendable {
        public var slot: String
        public var page: Int
        public var type: Int
        public var isOn: Bool
        public var typeName: String { KemperEffectType.name(type) }
    }

    /// The modules that hold an effect, in signal order, on or off.
    public var modules: [Module] {
        Self.modules.compactMap { page, name in
            guard let type = value(page, 0), type != 0 else { return nil }
            return Module(slot: name, page: page, type: type, isOn: value(page, 3) == 1)
        }
    }

    /// The old reverb of OS 2 to 5 (page 75): on, mix and time from 0 to 10.
    public var oldReverb: (isOn: Bool, mix: Double, time: Double)? {
        guard pages[Page.oldReverb] != nil else { return nil }
        let isOn = value(Page.oldReverb, 2) == 1
        return (isOn, knob(Page.oldReverb, 3) ?? 0, knob(Page.oldReverb, 6) ?? 5)
    }

    static func tenths(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}

/// The Kemper's effect types, from Appendix B of its MIDI parameter documentation (version 11.0).
public enum KemperEffectType {
    public static let names: [Int: String] = [
        1: "Wah Wah", 2: "Wah Low Pass", 3: "Wah High Pass", 4: "Wah Vowel Filter", 6: "Wah Phaser", 7: "Wah Flanger",
        8: "Wah Rate Reducer", 9: "Wah Ring Modulator", 10: "Wah Freq Shifter", 11: "Pedal Pitch",
        12: "Wah Formant Shifter", 13: "Pedal Vinyl Stop", 17: "Bit Shaper", 18: "Octa Shaper", 19: "Soft Shaper",
        20: "Hard Shaper", 21: "Wave Shaper", 32: "Kemper Drive", 33: "Green Scream", 34: "Plus DS", 35: "One DS",
        36: "Muffin", 37: "Mouse", 38: "Kemper Fuzz", 39: "Metal DS", 42: "Full OC", 49: "Compressor",
        50: "Auto Swell", 57: "Noise Gate 2:1", 58: "Noise Gate 4:1", 64: "Space", 65: "Vintage Chorus",
        66: "Hyper Chorus", 67: "Air Chorus", 68: "Vibrato", 69: "Rotary Speaker", 70: "Tremolo", 71: "Micro Pitch",
        81: "Phaser", 82: "Phaser Vibe", 83: "Phaser Oneway", 89: "Flanger", 91: "Flanger Oneway",
        97: "Graphic Equalizer", 98: "Studio Equalizer", 99: "Metal Equalizer", 100: "Acoustic Simulator",
        101: "Stereo Widener", 102: "Phase Widener", 103: "Delay Widener", 104: "Double Tracker",
        113: "Treble Booster", 114: "Lead Booster", 115: "Pure Booster", 116: "Wah Pedal Booster", 121: "Loop Mono",
        122: "Loop Stereo", 123: "Loop Distortion", 129: "Transpose", 130: "Chromatic Pitch", 131: "Harmonic Pitch",
        132: "Analog Octaver", 137: "Dual Chromatic", 138: "Dual Harmonic", 139: "Dual Crystal",
        140: "Dual Loop Pitch", 145: "Legacy Delay", 146: "Single Delay", 147: "Dual Delay", 148: "Two Tap Delay",
        149: "Serial TwoTap Delay", 150: "Crystal Delay", 151: "Loop Pitch Delay", 152: "Freq Shifter Delay",
        161: "Rhythm Delay", 162: "Melody Chromatic", 163: "Melody Harmonic", 164: "Quad Delay",
        165: "Quad Chromatic", 166: "Quad Harmonic", 177: "Legacy Reverb", 178: "Natural Reverb", 179: "Easy Reverb",
        180: "Echo Reverb", 181: "Cirrus Reverb", 182: "Formant Reverb", 183: "Ionosphere Reverb",
        193: "Spring Reverb",
    ]

    public static func name(_ type: Int) -> String { names[type] ?? "Effekt \(type)" }
}
