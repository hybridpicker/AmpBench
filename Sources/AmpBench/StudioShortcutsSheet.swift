import AmpText
import SparkCore
import SparkDesign
import SwiftUI

/// Every shortcut of AmpBench, from StudioKeymap, by where it works. Numbered series such as ⌘1 – ⌘4 share a row.
struct StudioShortcutsSheet: View {
    let close: () -> Void

    private struct Row: Identifiable {
        let id: String
        let keys: [String]
        let action: String
        let condition: String?
    }

    private static let sections: [(title: String, scope: KeyScope)] = [
        (tr("Everywhere"), .everywhere), (tr("Record area"), .recording), (tr("Presets area"), .presets),
        (tr("Tuner area"), .tuner),
    ]

    var body: some View {
        SheetPanel(tr("Keyboard shortcuts")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Self.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                                ForEach(Self.rows(in: section.scope)) { row in
                                    GridRow {
                                        HStack(spacing: 4) {
                                            ForEach(row.keys, id: \.self) { key in
                                                if key == "–" { Text("–").foregroundStyle(.secondary) } else { Keycap(key) }
                                            }
                                        }
                                        .padding(4)
                                        .background(RoundedRectangle(cornerRadius: Theme.Radius.key)
                                            .fill(Theme.device.faceBottom))
                                        .gridColumnAlignment(.trailing)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(row.action)
                                            if let condition = row.condition {
                                                Text(condition).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel([row.keys.joined(separator: " "), row.action, row.condition]
                                        .compactMap { $0 }.joined(separator: ", "))
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 460)
            Text(tr("Single keys do nothing while you type in a text field. No single key can delete anything; ⌫ moves takes to the Trash, ⌘Z brings them back."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Close"), action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 580)
    }

    /// The shortcuts of a scope in keymap order, with runs like "Play slot 1" … "Play slot 4" merged.
    private static func rows(in scope: KeyScope) -> [Row] {
        var rows: [Row] = []
        var run: [StudioShortcut] = []
        func pattern(_ shortcut: StudioShortcut) -> String {
            shortcut.action.replacingOccurrences(of: "[0-9]", with: "#", options: .regularExpression)
        }
        func flush() {
            guard let first = run.first, let last = run.last else { return }
            if run.count == 1 {
                rows.append(Row(id: first.display + first.action, keys: [first.display], action: first.action,
                                condition: first.condition))
            } else {
                let action = pattern(first).replacingOccurrences(of: "#", with: "\(first.key)–\(last.key)")
                rows.append(Row(id: first.display + action, keys: [first.display, "–", last.display], action: action,
                                condition: first.condition))
            }
            run = []
        }
        for shortcut in StudioKeymap.shortcuts(in: scope) {
            let isDigit = shortcut.key.count == 1 && shortcut.key.first?.isNumber == true
            if let previous = run.last, isDigit, previous.modifiers == shortcut.modifiers,
               pattern(previous) == pattern(shortcut), Int(shortcut.key) == (Int(previous.key) ?? -9) + 1 {
                run.append(shortcut)
            } else {
                flush()
                run = [shortcut]
            }
        }
        flush()
        return rows
    }
}
