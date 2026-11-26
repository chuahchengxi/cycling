//
//  KitModel.swift
//  cyclingskibidi
//
//  Kit's picks from the on-device model (iOS 26+, Apple Intelligence). The model
//  sees only our candidate lines plus the quick picks as a draft, and returns IDs
//  only: every note is our own template note, so nothing it says reaches a rider.
//  Its picks replace the quick picks only when they're clearly better (`accept`).
//  Without the model, or when it fails or is slow, the quick picks simply stay.
//

import Foundation
import CoreLocation
#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated enum KitModel {
    static let instructions = """
        You are Kit, a cycling cat in Singapore, choosing stops along one bike route.
        Choose only from the Places list and copy each ID exactly.
        Spread the picks along the whole route: use the km to avoid bunching.
        Favour places that match what the rider likes. Places with facts are better than places with no facts.
        """

    static func prompt(candidates: [KitCandidate], profile: RiderProfile, count: Int, quick: [Sight]) -> String {
        let likes = profile.likes.isEmpty ? "nothing in particular yet" : Interest.allCases.filter(profile.likes.contains).map(\.label).joined(separator: ", ")
        let today = profile.today.isEmpty ? "" : "\nRiding today: " + RideContext.allCases.filter(profile.today.contains).map(\.label).joined(separator: ", ") + "."
        let draft = quick.map { "- \($0.osmID ?? $0.id.uuidString) \($0.name)" }.joined(separator: "\n")
        // "none" in a line made the model write "none" back; say what it means.
        let lines = candidates.prefix(40).map { $0.line.replacingOccurrences(of: "| none", with: "| no facts") }
        return """
            The rider likes: \(likes).\(today)
            Pick exactly \(count) places. Kit's draft is below: keep a draft place unless another place fits the rider \
            better and the picks stay spread along the route.
            Draft:
            \(draft)
            Places (ID | name | kind | km along the route | facts):
            \(lines.joined(separator: "\n"))
            """
    }

    /// The model's IDs, or nil when there is no model, it fails, or it's slower than `timeout`.
    static func pick(candidates: [KitCandidate], profile: RiderProfile, count: Int, quick: [Sight], timeout: Duration = .seconds(8),
                     ask: @escaping @Sendable (String) async throws -> [String] = KitModel.askSystemModel) async -> [String]? {
        let text = prompt(candidates: candidates, profile: profile, count: count, quick: quick)
        return await withTaskGroup(of: [String]?.self) { group in
            group.addTask { try? await ask(text) }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The model's picks for this line when they beat the quick picks (`accept`), else nil.
    static func refine(line: [Coord], quick: [Sight], candidates: [KitCandidate], profile: RiderProfile) async -> [Sight]? {
        guard !quick.isEmpty, let ids = await pick(candidates: candidates, profile: profile, count: quick.count, quick: quick) else { return nil }
        let length = Geo.cumulative(Geo.sample(line.map(\.cl), count: 400)).last ?? 0
        let facts = Discovery.facts
        let model = validate(ids, candidates: candidates, count: quick.count, quick: quick, facts: facts, lengthMeters: length)
        return accept(model, over: quick, lengthMeters: length) { Kit.score($0, profile: profile, facts: facts) } ? model : nil
    }

    /// Exactly `count` real candidates in route order: unknown IDs dropped, duplicates
    /// once, extras cut, gaps filled from the quick picks; every note our template note.
    static func validate(_ ids: [String], candidates: [KitCandidate], count: Int, quick: [Sight],
                         facts: [String: PlaceFacts], lengthMeters: Double) -> [Sight] {
        let byID = Dictionary(candidates.map { ($0.sight.osmID ?? $0.sight.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        var chosen: [Sight] = [], seen: Set<String> = []
        // IDs have no spaces; the model sometimes copies the name after one, so keep the first word.
        for raw in ids where chosen.count < count {
            let id = String(raw.split(separator: " ").first ?? "")
            guard let c = byID[id], seen.insert(id).inserted else { continue }
            var s = c.sight
            s.note = Kit.templateNote(s, facts: s.osmID.flatMap { facts[$0] }, lengthMeters: lengthMeters)
            chosen.append(s)
        }
        for s in quick where chosen.count < count {
            let id = s.osmID ?? s.id.uuidString
            guard byID[id] != nil, seen.insert(id).inserted else { continue }
            chosen.append(s)
        }
        return chosen.sorted { $0.offsetAlong < $1.offsetAlong }
    }

    /// Use the model's picks only when all hold: the same count; a strictly higher summed
    /// score (a tie keeps the quick picks, so nothing flickers); no tighter bunching than
    /// the quick picks or half an even spacing, whichever is less; and every strong quick
    /// pick (score ≥ 4: a liked place with our notes, say) still in.
    static func accept(_ model: [Sight], over quick: [Sight], lengthMeters: Double, score: (Sight) -> Double) -> Bool {
        guard model.count == quick.count, !quick.isEmpty else { return false }
        func sum(_ xs: [Sight]) -> Double { xs.map(score).reduce(0, +) }
        func minGap(_ xs: [Sight]) -> Double {
            let a = xs.map(\.offsetAlong).sorted()
            return zip(a, a.dropFirst()).map { $1 - $0 }.min() ?? .infinity
        }
        let ids = Set(model.map { $0.osmID ?? $0.id.uuidString })
        return sum(model) > sum(quick)
            && minGap(model) >= min(minGap(quick), lengthMeters / Double(2 * quick.count))
            && quick.filter { score($0) >= 4 }.allSatisfy { ids.contains($0.osmID ?? $0.id.uuidString) }
    }

    static func askSystemModel(_ prompt: String) async throws -> [String] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: prompt, generating: KitAnswer.self).content.ids
        }
        #endif
        throw CancellationError()   // no model on this iPhone: the caller keeps the quick picks
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct KitAnswer {
    @Guide(description: "IDs of the chosen places, copied exactly", .maximumCount(12))
    var ids: [String]
}
#endif

extension KitModel {
    static func selfCheck() async {
        let line = [CLLocationCoordinate2D(latitude: 1.30, longitude: 103.80), CLLocationCoordinate2D(latitude: 1.30, longitude: 103.8899)]
        let cum = Geo.cumulative(line), length = cum.last!
        func c(_ id: String, km: Double, cat: String = "park", facts: String = "none", score: Double = 1) -> KitCandidate {
            var s = Sight(name: "Place \(id)", category: cat, lat: 1.30, lon: 103.80 + km / 111.0); s.osmID = id; s.offsetAlong = km * 1000
            return KitCandidate(sight: s, score: score, line: "\(id) | Place \(id) | \(Discovery.icon(for: cat).label) | km \(String(format: "%.1f", km)) | \(facts)")
        }
        let cs = [c("a", km: 1, cat: "hawker", facts: "dishes: satay, carrot cake"), c("b", km: 3), c("c", km: 5), c("d", km: 7), c("e", km: 9)]
        let quick = Kit.quickPicks(cs, polyline: line, cumulative: cum, count: 3, facts: [:])

        // Validate: IDs only; every note is our own template note.
        let v = validate(["zzz", "e", "e", "a"], candidates: cs, count: 3, quick: quick, facts: [:], lengthMeters: length)
        assert(v.count == 3, "topped up to count: \(v.map(\.osmID))")
        assert(Set(v.compactMap(\.osmID)).count == 3 && !v.contains { $0.osmID == "zzz" }, "unknown dropped, duplicates once: \(v.map(\.osmID))")
        assert(v.allSatisfy { s in cs.contains { $0.sight.id == s.id } }, "every pick is a candidate")
        assert(v.map(\.offsetAlong) == v.map(\.offsetAlong).sorted(), "route order")
        assert(v.allSatisfy { $0.note == Kit.templateNote($0, facts: nil, lengthMeters: length) }, "notes are always ours")
        assert(validate(cs.map { $0.sight.osmID! }, candidates: cs, count: 3, quick: quick, facts: [:], lengthMeters: length).count == 3, "cut to count")
        // The real model sometimes copies the name after the ID ("r19580129 East Coast Park").
        assert(validate(["e Place e"], candidates: cs, count: 1, quick: [], facts: [:], lengthMeters: length).first?.osmID == "e", "ID with its name kept")

        // Keep the model's picks only when they're strictly better, as spread out, and keep every strong quick pick.
        func s(_ id: String, _ km: Double) -> Sight { var x = Sight(name: id, category: "park", lat: 1.30, lon: 103.80); x.osmID = id; x.offsetAlong = km * 1000; return x }
        let scores: [String: Double] = ["q1": 1, "q2": 4.5, "q3": 1, "x": 3, "y": 5]
        let score: (Sight) -> Double = { scores[$0.osmID ?? ""] ?? 0 }
        let q = [s("q1", 1), s("q2", 5), s("q3", 9)]
        func ok(_ m: [Sight]) -> Bool { accept(m, over: q, lengthMeters: length, score: score) }
        assert(!ok(q), "a tie keeps the quick picks")
        assert(ok([s("x", 2), s("q2", 5), s("q3", 9)]), "better, spread, keeps the strong pick")
        assert(!ok([s("x", 5.2), s("q2", 5), s("q3", 9)]), "bunched picks rejected")
        assert(!ok([s("x", 2), s("y", 5.5), s("q3", 9)]), "dropping a strong quick pick rejected")
        assert(!ok([s("q1", 1), s("q3", 9)]), "fewer picks rejected")

        // Fallbacks.
        struct Boom: Error {}
        let threw = await pick(candidates: cs, profile: RiderProfile(), count: 3, quick: quick) { _ in throw Boom() }
        assert(threw == nil, "a throwing model gives nil")
        let clock = ContinuousClock(), t0 = clock.now
        let slow = await pick(candidates: cs, profile: RiderProfile(), count: 3, quick: quick, timeout: .milliseconds(200)) { _ in
            try await Task.sleep(for: .seconds(10)); return ["a"]
        }
        assert(slow == nil && clock.now - t0 < .seconds(1), "timeout gives nil fast: \(clock.now - t0)")
        let good = await pick(candidates: cs, profile: RiderProfile(), count: 3, quick: quick) { _ in ["b"] }
        assert(good == ["b"], "a good model's IDs come back")

        // Prompt: likes, count, the quick picks as a draft, every line, "no facts" not "none", at most 40 places.
        let pr = prompt(candidates: cs, profile: RiderProfile(likes: [.food, .heritage]), count: 3, quick: quick)
        assert(cs.allSatisfy { pr.contains($0.line.replacingOccurrences(of: "| none", with: "| no facts")) }, "prompt has every line")
        assert(pr.contains("Food") && pr.contains("Heritage") && pr.contains("exactly 3"), "prompt has likes and count")
        assert(quick.allSatisfy { pr.contains("- \($0.osmID!) \($0.name)") }, "prompt has the draft")
        assert(!pr.contains("| none"), "no literal none")
        let fifty = (0..<50).map { c("x\($0)", km: Double($0) / 10) }
        assert(prompt(candidates: fifty, profile: RiderProfile(), count: 3, quick: []).components(separatedBy: "\n").filter { $0.hasPrefix("x") }.count == 40,
               "at most 40 candidate lines")

        // Generation guard: an answer for an older line never lands.
        assert(RouteBuilderView.apply(v, forGeneration: 4, current: 5) == nil, "stale answer dropped")
        assert(RouteBuilderView.apply(v, forGeneration: 5, current: 5)?.count == 3, "current answer applied")
        print("KitModel check: validate, keep rule, fallbacks (timeout in \(clock.now - t0)), prompt, guard")
    }
}
