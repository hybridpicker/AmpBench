import Foundation
import SparkControl

/// Headless commands for sound recipes and the catalog, so an AI assistant or a script can check its work:
///   --recipe-check <recipe.json>...         says whether Studio can read each recipe, and what it corrected
///   --recipe-from <preset.json> [out.json]  describes a saved preset as a recipe
///   --recipe-prompt <recipe or preset.json> describes the sound in English, e.g. for REACTOR's Text to Tone
///   --catalog-export <folder>               writes spark-catalog.json and spark-catalog.md
///   --fingerprint <preset.json>...          prints the SHA-256 of each preset's effect chain, the take's sound id
enum RecipeCommandLine {
    /// The exit status, or nil when the arguments are not one of these commands.
    static func run(_ arguments: [String]) -> Int32? {
        guard let command = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "--recipe-check": return check(rest)
        case "--recipe-from": return describe(rest)
        case "--recipe-prompt": return prompt(rest)
        case "--catalog-export": return export(rest)
        case "--fingerprint": return fingerprint(rest)
        default: return nil
        }
    }

    /// For checking other implementations of the fingerprint, such as spark-studio on Linux.
    private static func fingerprint(_ paths: [String]) -> Int32 {
        guard !paths.isEmpty else {
            print("usage: --fingerprint <preset.json>...")
            return 64
        }
        var failed = false
        for path in paths {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let preset: SparkPreset
                if let file = try? PresetFile.read(data) {
                    preset = file.preset
                } else {
                    preset = try JSONDecoder().decode(SparkPreset.self, from: data)
                }
                let hash = try preset.sha256Hex()
                print("\(hash)  \(URL(fileURLWithPath: path).lastPathComponent)")
            } catch {
                print("nicht lesbar: \(path): \(error)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    private static func check(_ paths: [String]) -> Int32 {
        guard !paths.isEmpty else {
            print("usage: --recipe-check <recipe.json>...")
            return 64
        }
        var failed = false
        for path in paths {
            let name = URL(fileURLWithPath: path).lastPathComponent
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                guard let recipe = try SoundRecipe.decodeIfRecipe(data) else {
                    print("\(name): kein Rezept (\"format\": \"\(SoundRecipe.formatName)\" fehlt)")
                    failed = true
                    continue
                }
                let conversion = try recipe.preset(identity: data)
                print("\(name): ok, „\(conversion.preset.name)“")
                for (index, effect) in conversion.preset.effects.enumerated() {
                    let place = ChainPlace(rawValue: index)!
                    let info = ModelCatalog.info(for: effect.name, parameterCount: effect.parameters.count)
                    let values = info.settableParameters.compactMap { parameterIndex, parameter -> String? in
                        guard let value = effect.parameters.first(where: { Int($0.index) == parameterIndex })?.value
                        else { return nil }
                        return "\(parameter.key) \(parameter.display(value))"
                    }
                    let state = effect.isOn ? "an " : "aus"
                    print("  \(place.key.padding(toLength: 10, withPad: " ", startingAt: 0)) \(state) \(effect.name): "
                          + values.joined(separator: ", "))
                }
                for warning in conversion.warnings { print("  Hinweis: \(warning)") }
            } catch let problems as SoundRecipe.Problems {
                print("\(name): nicht lesbar")
                for message in problems.messages { print("  Fehler: \(message)") }
                failed = true
            } catch {
                print("\(name): nicht lesbar: \(error)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    private static func describe(_ arguments: [String]) -> Int32 {
        guard (1...2).contains(arguments.count) else {
            print("usage: --recipe-from <preset.json> [out.json]")
            return 64
        }
        do {
            let file = try PresetFile.read(Data(contentsOf: URL(fileURLWithPath: arguments[0])))
            let recipe = try SoundRecipe(preset: file.preset, tags: file.tags, notes: file.notes)
            let data = try recipe.jsonData()
            if arguments.count == 2 {
                try data.write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
            } else {
                FileHandle.standardOutput.write(data)
            }
            return 0
        } catch {
            print("nicht möglich: \(error.localizedDescription)")
            return 1
        }
    }

    /// A recipe file, or a saved preset described as one.
    private static func prompt(_ arguments: [String]) -> Int32 {
        guard arguments.count == 1 else {
            print("usage: --recipe-prompt <recipe or preset.json>")
            return 64
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[0]))
            let recipe: SoundRecipe
            if let read = try SoundRecipe.decodeIfRecipe(data) {
                recipe = read
            } else {
                let file = try PresetFile.read(data)
                recipe = try SoundRecipe(preset: file.preset, tags: file.tags, notes: file.notes)
            }
            print(try recipe.toneDescription(), terminator: "")
            return 0
        } catch {
            print("nicht möglich: \(error.localizedDescription)")
            return 1
        }
    }

    private static func export(_ arguments: [String]) -> Int32 {
        guard arguments.count == 1 else {
            print("usage: --catalog-export <folder>")
            return 64
        }
        let folder = URL(fileURLWithPath: arguments[0], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let reference = CatalogReference()
            try reference.jsonData().write(to: folder.appendingPathComponent("spark-catalog.json"), options: .atomic)
            try Data(reference.markdown().utf8).write(to: folder.appendingPathComponent("spark-catalog.md"),
                                                      options: .atomic)
            print("\(reference.models.count) Modelle nach \(folder.path)")
            return 0
        } catch {
            print("nicht möglich: \(error.localizedDescription)")
            return 1
        }
    }
}
