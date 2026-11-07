import Foundation
import SparkControl

/// `spark-probe catalog-check [place] [first id] [count]`: plays a copy of stored preset 1 on the temporary place,
/// then changes the model of each place to the catalog's models, one after the other, and reads back what the amp
/// plays. Nothing is stored. Paid add-ons are left out.
///
/// A long series of model changes made a Spark MINI hang once, until it was forced to shut down. So it pauses a
/// second between models, takes few at a time, and stops as soon as the amp answers with an echo (`03 06`) instead of
/// an acknowledgement, which came before the hang. Each model ends in a tab separated line for the catalog:
///
///     RESULT  <model id>  <accepted|refused|no answer>  <parameter count>  <values the amp chose>
@MainActor
enum CatalogCheck {
    static let pause: Duration = .seconds(1)

    static func run(_ link: ProbeLink, places: [ChainPlace], from first: String? = nil, count: Int = 8) async throws {
        let before = try await Commands.currentSlot(link)
        let stored = try await link.readPreset(0).preset
        guard stored.effects.count == ChainPlace.allCases.count else {
            throw ProbeFailure("Stored preset 1 has \(stored.effects.count) effects, not 7.")
        }
        log("\nPlaying a copy of stored preset 1 on the temporary place. Nothing is stored.")
        var playing = try await link.playTemporarily(stored)
        let header = link.header
        var results: [String] = []
        var stressed = false

        for place in places where !stressed {
            var models = ModelCatalog.models(for: place)
            if let first, let start = models.firstIndex(where: { $0.id == first }) { models = Array(models[start...]) }
            for model in models.prefix(count) {
                let current = playing.effects[place.rawValue].name
                guard current != model.id else { continue }
                try await Task.sleep(for: pause)
                let status: String
                do {
                    let answer = try await link.request("change \(current) to \(model.id)",
                                                        answer: SparkProtocol.Sub.changeEffect) {
                        [SparkProtocol.changeModel(from: current, to: model.id, sequence: $0, header: header)]
                    }
                    stressed = answer.command != SparkProtocol.Command.acknowledge
                    playing = try await link.readPreset(nil).preset
                    status = playing.effects[place.rawValue].name == model.id ? "accepted" : "refused"
                } catch {
                    playing = try await link.readPreset(nil).preset
                    status = "no answer"
                }
                let effect = playing.effects[place.rawValue]
                let values = effect.name == model.id
                    ? effect.parameters.map { String(format: "%.4f", $0.value) }.joined(separator: ",") : ""
                let count = effect.name == model.id ? "\(effect.parameters.count)" : "-"
                let line = "RESULT\t\(model.id)\t\(status)\t\(count)\t\(values)"
                log(line)
                results.append(line)
                if stressed {
                    log("  ! the amp answered with an echo instead of an acknowledgement, stopping here")
                    break
                }
            }
        }
        log("\nSummary:")
        results.forEach { log($0) }
        // Back to a stored preset. That ends the temporary one with all its changes.
        try await link.switchTo(before ?? 0)
    }
}
