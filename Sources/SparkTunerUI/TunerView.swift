import SparkCore
import SparkDesign
import SwiftUI

/// The area "Stimmgerät": one dark front on the desk. On top the readout, the note large in amber and the deviation
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
            let name = model.ampName ?? "Verstärkers"
            return "Das Stimmgerät des \(name) ist an, solange dieser Bereich vorn ist, und der Verstärker ist dabei stumm. Seine Werte kommen über Bluetooth und sind gröber als über USB, auf ganze Cent."
        }
        if model.status == .noInput, model.source != .automatic, let name = model.ampName {
            return "Ohne USB-Ton misst das Stimmgerät des \(name): im Eingang „Stimmgerät des \(name)“ wählen. Der Verstärker ist dann stumm, solange dieser Bereich vorn ist."
        }
        return "Das Stimmgerät hört nur, solange dieser Bereich vorn ist. Es sendet nichts an den Verstärker, gibt keinen Ton aus und speichert nichts."
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
        .accessibilityLabel("Note")
        .accessibilityValue(noteSpoken)
    }

    private var stringLine: String {
        guard let reading else { return statusLine }
        guard reading.knowsOctave else { return "VOM VERSTÄRKER · \(reading.noteName)" }
        let target = "\(reading.noteName)\(reading.note.octave)"
        if let string = reading.string { return "\(string). SAITE · \(target)" }
        return model.tuning == .chromatic ? "CHROMATISCH · \(target)" : "KEINE SAITE · \(target)"
    }

    private var noteSpoken: String {
        guard let reading else { return statusLine }
        var parts = [reading.note.spokenName(flats: reading.flats) + (reading.knowsOctave ? " \(reading.note.octave)" : "")]
        if let string = reading.string { parts.append("\(string). Saite") }
        if reading.isHeld { parts.append("gehalten") }
        return parts.joined(separator: ", ")
    }

    private var statusLine: String {
        if model.usesAmp {
            switch model.status {
            case .idle, .opening: return "SCHALTE DAS STIMMGERÄT EIN …"
            case .listening, .demo: return model.hasSignal ? "MISST …" : "SPIELE EINE SAITE"
            case .noInput, .noPermission, .failed: return "KEIN VERSTÄRKER VERBUNDEN"
            }
        }
        return switch model.status {
        case .idle, .opening: "ÖFFNE DEN EINGANG …"
        case .listening, .demo: model.hasSignal ? "HÖRE ZU …" : "SPIELE EINE SAITE"
        case .noInput: model.inputName == "Kein Spark" ? "KEIN SPARK VERBUNDEN" : "EINGANG FEHLT"
        case .noPermission: "MIKROFONZUGRIFF FEHLT"
        case .failed: "EINGANG LÄSST SICH NICHT ÖFFNEN"
        }
    }

    private var valueDisplay: some View {
        Display(padding: EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(reading.map { $0.isFromAmp ? TunerText.wholeCents($0.cents) : TunerText.cents($0.cents) }
                             ?? (model.usesAmp ? "–" : "–,–"))
                            .font(Theme.Fonts.mono(56, weight: .semibold))
                            .foregroundStyle(textColor)
                            .lineLimit(1)
                            .fixedSize()
                        Text("CENT")
                            .font(Theme.Fonts.lamp(11))
                            .foregroundStyle(Theme.device.amberDim)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(reading.flatMap { $0.knowsOctave ? TunerText.hertz($0.frequency) : nil } ?? "–,––")
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
                .accessibilityLabel("Abweichung und Frequenz")
                .accessibilityValue(valueSpoken)
                Spacer(minLength: 8)
                VStack(alignment: .leading, spacing: 12) {
                    Lamp("Signal", isOn: model.hasSignal, size: 9, textSize: 11)
                    Lamp("Zu tief", isOn: isLive && reading?.direction == .low, size: 9, textSize: 11)
                    Lamp("Gestimmt", tone: .on, isOn: isLive && reading?.isInTune == true, size: 9, textSize: 11)
                    Lamp("Zu hoch", isOn: isLive && reading?.direction == .high, size: 9, textSize: 11)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var isLive: Bool { reading?.isHeld == false }

    private var targetLine: String {
        guard let reading else {
            return model.usesAmp ? "VOM VERSTÄRKER · A4 = \(TunerText.hertz(model.a4, digits: 1)) HZ"
                : "KAMMERTON A4 = \(TunerText.hertz(model.a4, digits: 1)) HZ"
        }
        let target = reading.note.frequency(a4: model.a4)
        let held = reading.isHeld ? " · GEHALTEN" : ""
        if reading.isFromAmp {
            return reading.knowsOctave ? "ZIEL \(TunerText.hertz(target)) HZ · VOM VERSTÄRKER\(held)" : "VOM VERSTÄRKER\(held)"
        }
        return "ZIEL \(TunerText.hertz(target)) HZ · A4 = \(TunerText.hertz(model.a4, digits: 1)) HZ\(held)"
    }

    private var valueSpoken: String {
        guard let reading else { return "kein Ton" }
        let cents = CentReading(cents: reading.cents, isInTune: reading.isInTune, isHeld: reading.isHeld).spoken
        guard reading.knowsOctave else { return cents + ", vom Verstärker" }
        return "\(cents), \(TunerText.hertz(reading.frequency)) Hertz"
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
        FaceplateModule("Eingang") {
            Lamp(model.usesAmp ? "Misst" : model.isSharedWithRecording ? "Geteilt" : "Hört", tone: .listening,
                 isOn: model.status == .listening)
                .help(model.usesAmp
                      ? "Das Stimmgerät des Verstärkers ist an, der Verstärker ist stumm."
                      : model.isSharedWithRecording
                      ? "Das Stimmgerät liest den Eingang der Aufnahme mit, ohne ihn zu verändern."
                      : "Der Eingang ist offen, solange dieser Bereich vorn ist.")
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                DevicePopup("Eingang", value: model.inputName) {
                    Button("Automatisch (USB-Ton, sonst Stimmgerät des Verstärkers)") { model.choose(.automatic) }
                    Divider()
                    Button(model.deckInputName.map { "\($0) (wie im Deck)" } ?? "Spark aus dem Deck") {
                        model.choose(.deck)
                    }
                    if let name = model.ampName {
                        Divider()
                        Button("Stimmgerät des \(name) (Verstärker stumm)") { model.choose(.amp) }
                    } else if model.usesAmp {
                        Divider()
                        Button("Stimmgerät des Verstärkers (keiner verbunden)") {}
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
                    Text("VERSTÄRKER STUMM, SOLANGE ES MISST")
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
                    .accessibilityLabel("Pegel")
                    .accessibilityValue(model.hasSignal ? "Signal" : "kein Signal")
                }
            }
        }
    }

    private var tuningModule: some View {
        FaceplateModule("Stimmung") {
            DevicePopup("Stimmung", selection: $model.tuning, options: Tuning.allCases.map { ($0, $0.title) })
                .padding(.top, 6)
            HStack(spacing: 0) {
                if model.tuning.strings.isEmpty {
                    Text("ALLE TÖNE, MIT NAME UND OKTAVE")
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
                        .accessibilityLabel("\(number). Saite, \(note.spokenName(flats: model.tuning.prefersFlats))")
                        .accessibilityAddTraits(isFound ? .isSelected : [])
                    }
                }
            }
            .frame(height: 30)
            .padding(.top, 8)
        }
    }

    private var pitchModule: some View {
        FaceplateModule("Kammerton") {
            HStack(spacing: 8) {
                DisplayStepper("Kammerton A4", value: $model.a4, in: TunerInterpreter.a4Range, step: 0.1,
                               text: TunerText.hertz(model.a4, digits: 1), unit: "HZ",
                               spokenValue: "\(TunerText.hertz(model.a4, digits: 1)) Hertz")
                Button("440") { model.a4 = TunerInterpreter.defaultA4 }
                    .buttonStyle(.hardwareKey(keycap: "⌘0", size: .small))
                    .disabled(model.a4 == TunerInterpreter.defaultA4)
                    .help("Kammerton 440 Hz (⌘0)")
                    .accessibilityLabel("Kammerton 440 Hertz")
            }
            .padding(.top, 6)
            Text("⌘↑ ⌘↓ IN ZEHNTEL HERTZ")
                .font(Theme.Fonts.lamp(9))
                .foregroundStyle(Theme.device.lampOffText)
                .padding(.top, 9)
                .accessibilityHidden(true)
        }
        .fixedSize()
    }

    private var displayModule: some View {
        FaceplateModule("Anzeige") {
            Button("Stroboskop") { model.showsStrobe.toggle() }
                .buttonStyle(.hardwareKey(model.showsStrobe ? .on : .normal, keycap: "⌘T"))
                .help("Zwischen Zeiger und Stroboskop wechseln (⌘T)")
                .accessibilityValue(model.showsStrobe ? "an" : "aus")
                .padding(.top, 6)
            Text(model.showsStrobe ? "STEHT STILL, WENN GESTIMMT" : "ZEIGER ±50 CENT")
                .font(Theme.Fonts.lamp(9))
                .foregroundStyle(Theme.device.lampOffText)
                .padding(.top, 9)
                .accessibilityHidden(true)
        }
        .fixedSize()
    }
}
