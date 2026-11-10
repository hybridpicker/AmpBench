import AmpText
import SparkCore
import SparkDesign
import SwiftUI

/// The area "Tuner": one dark front on the desk. On top the readout, the note large in amber and the deviation
/// and frequency in SF Mono, with lamps for signal, too low, in tune and too high; below it the needle field or the
/// strobe; at the bottom the modules input, tuning, concert pitch and display.
struct TunerView: View {
    @ObservedObject var model: TunerModel

    var body: some View {
        VStack(spacing: 14) {
            Faceplate(radius: Theme.Radius.panel) {
                VStack(spacing: 0) {
                    readout
                        .padding(18)
                    EngravedDivider(.horizontal, inset: 0)
                    controls
                        .padding(.vertical, 12)
                }
            }
            .frame(maxWidth: 1040)
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reading: TunerReadout? { model.readout }

    private var caption: String {
        if model.usesAmp {
            guard let name = model.ampName else {
                return tr("The amp’s tuner is on while this area is in front, and the amp is muted meanwhile. Its readings come over Bluetooth and are coarser than over USB, in whole cents.")
            }
            return tr("The %@ tuner is on while this area is in front, and the amp is muted meanwhile. Its readings come over Bluetooth and are coarser than over USB, in whole cents.", name)
        }
        if model.status == .noInput, model.source != .automatic, let name = model.ampName {
            return tr("Without USB audio the %1$@ tuner can measure: choose “%1$@ tuner” under Input. The amp is then muted while this area is in front.", name)
        }
        return tr("The tuner listens only while this area is in front. It sends nothing to the amp, plays no sound and stores nothing.")
    }

    private var centReading: CentReading? {
        reading.map { CentReading(cents: $0.cents, isInTune: $0.isInTune, isHeld: $0.isHeld) }
    }

    private var textColor: Swatch {
        reading?.isHeld == false ? Theme.device.amber : Theme.device.amberDim
    }

    // MARK: Readout

    private var readout: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                noteDisplay
                valueDisplay
            }
            .frame(height: 172)
            Group {
                if model.showsStrobe {
                    StrobeBand(reading: centReading)
                } else {
                    CentMeter(reading: centReading)
                }
            }
        }
    }

    private var noteDisplay: some View {
        Display(padding: EdgeInsets(top: 10, leading: 18, bottom: 12, trailing: 18)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(reading?.noteName ?? "–")
                        .font(.system(size: 108, weight: .bold))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let reading, reading.knowsOctave {
                        Text("\(reading.note.octave)")
                            .font(Theme.Fonts.mono(30, weight: .semibold))
                            .foregroundStyle(Theme.device.amberDim)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .leading)
                Text(stringLine)
                    .font(Theme.Fonts.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.device.amberDim)
                    .lineLimit(1)
            }
            .frame(width: 236, alignment: .leading)
            .frame(maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Note name"))
        .accessibilityValue(noteSpoken)
    }

    private var stringLine: String {
        guard let reading else { return statusLine }
        guard reading.knowsOctave else { return tr("FROM THE AMP · %@", reading.noteName) }
        let target = "\(reading.noteName)\(reading.note.octave)"
        if let string = reading.string { return tr("STRING %1$d · %2$@", string, target) }
        return model.tuning == .chromatic ? tr("CHROMATIC · %@", target) : tr("NO STRING · %@", target)
    }

    private var noteSpoken: String {
        guard let reading else { return statusLine }
        var parts = [reading.note.spokenName(flats: reading.flats) + (reading.knowsOctave ? " \(reading.note.octave)" : "")]
        if let string = reading.string { parts.append(tr("string %d", string)) }
        if reading.isHeld { parts.append(tr("held")) }
        return parts.joined(separator: ", ")
    }

    private var statusLine: String {
        if model.usesAmp {
            switch model.status {
            case .idle, .opening: return tr("SWITCHING THE TUNER ON …")
            case .listening, .demo: return model.hasSignal ? tr("MEASURING …") : tr("PLAY A STRING")
            case .noInput, .noPermission, .failed: return tr("NO AMP CONNECTED")
            }
        }
        return switch model.status {
        case .idle, .opening: tr("OPENING THE INPUT …")
        case .listening, .demo: model.hasSignal ? tr("LISTENING …") : tr("PLAY A STRING")
        case .noInput: model.inputName == tr("No Spark") ? tr("NO SPARK CONNECTED") : tr("INPUT MISSING")
        case .noPermission: tr("NO MICROPHONE ACCESS")
        case .failed: tr("THE INPUT CANNOT BE OPENED")
        }
    }

    private var valueDisplay: some View {
        Display(padding: EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(reading.map { $0.isFromAmp ? TunerText.wholeCents($0.cents) : TunerText.cents($0.cents) }
                             ?? (model.usesAmp ? "–" : tr("–.–")))
                            .font(Theme.Fonts.mono(56, weight: .semibold))
                            .foregroundStyle(textColor)
                            .lineLimit(1)
                            .fixedSize()
                        Text(tr("CENTS"))
                            .font(Theme.Fonts.lamp(11))
                            .foregroundStyle(Theme.device.amberDim)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(reading.flatMap { $0.knowsOctave ? TunerText.hertz($0.frequency) : nil } ?? tr("–.––"))
                            .font(Theme.Fonts.mono(22, weight: .medium))
                            .foregroundStyle(textColor)
                        Text("HZ")
                            .font(Theme.Fonts.lamp(10))
                            .foregroundStyle(Theme.device.amberDim)
                    }
                    Spacer(minLength: 0)
                    Text(targetLine)
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.device.amberDim)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tr("Deviation and frequency"))
                .accessibilityValue(valueSpoken)
                Spacer(minLength: 8)
                VStack(alignment: .leading, spacing: 12) {
                    Lamp(tr("Signal"), isOn: model.hasSignal, size: 9, textSize: 11)
                    Lamp(tr("Too low"), isOn: isLive && reading?.direction == .low, size: 9, textSize: 11)
                    Lamp(tr("In tune"), tone: .on, isOn: isLive && reading?.isInTune == true, size: 9, textSize: 11)
                    Lamp(tr("Too high"), isOn: isLive && reading?.direction == .high, size: 9, textSize: 11)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var isLive: Bool { reading?.isHeld == false }

    private var targetLine: String {
        guard let reading else {
            return model.usesAmp ? tr("FROM THE AMP · A4 = %@ HZ", TunerText.hertz(model.a4, digits: 1))
                : tr("CONCERT PITCH A4 = %@ HZ", TunerText.hertz(model.a4, digits: 1))
        }
        let target = reading.note.frequency(a4: model.a4)
        let held = reading.isHeld ? " · " + tr("HELD") : ""
        if reading.isFromAmp {
            return (reading.knowsOctave ? tr("TARGET %@ HZ · FROM THE AMP", TunerText.hertz(target)) : tr("FROM THE AMP")) + held
        }
        return tr("TARGET %1$@ HZ · A4 = %2$@ HZ", TunerText.hertz(target), TunerText.hertz(model.a4, digits: 1)) + held
    }

    private var valueSpoken: String {
        guard let reading else { return tr("no tone") }
        let cents = CentReading(cents: reading.cents, isInTune: reading.isInTune, isHeld: reading.isHeld).spoken
        guard reading.knowsOctave else { return cents + ", " + tr("from the amp") }
        return cents + ", " + tr("%@ hertz", TunerText.hertz(reading.frequency))
    }

    // MARK: Modules

    private var controls: some View {
        HStack(alignment: .top, spacing: 0) {
            inputModule
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
            EngravedDivider()
            tuningModule
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
            EngravedDivider()
            pitchModule
                .padding(.horizontal, 18)
            EngravedDivider()
            displayModule
                .padding(.horizontal, 18)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var inputModule: some View {
        FaceplateModule(tr("Input")) {
            Lamp(model.usesAmp ? tr("Measuring") : model.isSharedWithRecording ? tr("Shared") : tr("Listening"), tone: .listening,
                 isOn: model.status == .listening)
                .help(model.usesAmp
                      ? tr("The amp’s tuner is on, the amp is muted.")
                      : model.isSharedWithRecording
                      ? tr("The tuner reads the recording’s input along with it, without changing it.")
                      : tr("The input is open while this area is in front."))
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                DevicePopup(tr("Input"), value: model.inputName) {
                    Button(tr("Automatic (USB audio, otherwise the amp’s tuner)")) { model.choose(.automatic) }
                    Divider()
                    Button(model.deckInputName.map { tr("%@ (as in the deck)", $0) } ?? tr("Spark from the deck")) {
                        model.choose(.deck)
                    }
                    if let name = model.ampName {
                        Divider()
                        Button(tr("%@ tuner (amp muted)", name)) { model.choose(.amp) }
                    } else if model.usesAmp {
                        Divider()
                        Button(tr("The amp’s tuner (none connected)")) {}
                            .disabled(true)
                    }
                    if !model.otherInputs.isEmpty {
                        Divider()
                        ForEach(model.otherInputs) { device in
                            Button(device.name) { model.choose(.other(uid: device.uid)) }
                        }
                    }
                }
                .padding(.top, 6)
                if model.usesAmp {
                    Text(tr("AMP MUTED WHILE IT MEASURES"))
                        .font(Theme.Fonts.lamp(9))
                        .foregroundStyle(Theme.device.lampOffText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(height: 16)
                } else {
                    LEDSegments(color: Theme.device.amber) { index, count in
                        Double(index) < model.level * Double(count) ? 1 : 0
                    }
                    .frame(height: 6)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(DisplayGlass(radius: 5))
                    .accessibilityElement()
                    .accessibilityLabel(tr("Level"))
                    .accessibilityValue(model.hasSignal ? tr("Signal") : tr("no signal"))
                }
            }
        }
    }

    private var tuningModule: some View {
        FaceplateModule(tr("Tuning")) {
            DevicePopup(tr("Tuning"), selection: $model.tuning, options: Tuning.allCases.map { ($0, $0.title) })
                .padding(.top, 6)
            HStack(spacing: 0) {
                if model.tuning.strings.isEmpty {
                    Text(tr("ALL NOTES, WITH NAME AND OCTAVE"))
                        .font(Theme.Fonts.lamp(9.5))
                        .foregroundStyle(Theme.device.lampOffText)
                } else {
                    ForEach(Array(model.tuning.strings.enumerated()), id: \.offset) { index, note in
                        let number = model.tuning.strings.count - index
                        let isFound = reading?.string == number
                        VStack(spacing: 3) {
                            LampDot(isOn: isFound, size: 7)
                            Text(note.name(flats: model.tuning.prefersFlats))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(isFound ? Theme.device.amber : Theme.device.labelDim)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(tr("string %d", number) + ", " + note.spokenName(flats: model.tuning.prefersFlats))
                        .accessibilityAddTraits(isFound ? .isSelected : [])
                    }
                }
            }
            .frame(height: 30)
            .padding(.top, 8)
        }
    }

    private var pitchModule: some View {
        FaceplateModule(tr("Concert pitch")) {
            HStack(spacing: 8) {
                DisplayStepper(tr("Concert pitch A4"), value: $model.a4, in: TunerInterpreter.a4Range, step: 0.1,
                               text: TunerText.hertz(model.a4, digits: 1), unit: "HZ",
                               spokenValue: tr("%@ hertz", TunerText.hertz(model.a4, digits: 1)))
                Button("440") { model.a4 = TunerInterpreter.defaultA4 }
                    .buttonStyle(.hardwareKey(keycap: "⌘0", size: .small))
                    .disabled(model.a4 == TunerInterpreter.defaultA4)
                    .help(tr("Concert pitch 440 Hz (⌘0)"))
                    .accessibilityLabel(tr("Concert pitch 440 hertz"))
            }
            .padding(.top, 6)
            Text(tr("⌘↑ ⌘↓ IN TENTHS OF A HERTZ"))
                .font(Theme.Fonts.lamp(9))
                .foregroundStyle(Theme.device.lampOffText)
                .padding(.top, 9)
                .accessibilityHidden(true)
        }
        .fixedSize()
    }

    private var displayModule: some View {
        FaceplateModule(tr("Display")) {
            Button(tr("Strobe")) { model.showsStrobe.toggle() }
                .buttonStyle(.hardwareKey(model.showsStrobe ? .on : .normal, keycap: "⌘T"))
                .help(tr("Switch between needle and strobe (⌘T)"))
                .accessibilityValue(model.showsStrobe ? tr("on") : tr("off"))
                .padding(.top, 6)
            Text(model.showsStrobe ? tr("STANDS STILL WHEN IN TUNE") : tr("NEEDLE ±50 CENTS"))
                .font(Theme.Fonts.lamp(9))
                .foregroundStyle(Theme.device.lampOffText)
                .padding(.top, 9)
                .accessibilityHidden(true)
        }
        .fixedSize()
    }
}
