//
//  KitModel.swift
//  cyclingskibidi
//
//  Kit's picks from the on-device model (iOS 26+, Apple Intelligence). The model
//  sees only our candidate lines and returns IDs and one-line notes; every ID is
//  validated and every note checked against that place's facts. Without the
//  model, or when it fails or is slow, the quick picks simply stay.
//

import Foundation
import CoreLocation
#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated struct ModelPick: Sendable, Equatable {
    let id: String
    let note: String
}

nonisolated enum KitModel {
    static let instructions = """
        You are Kit, a friendly cycling cat in Singapore. Choose places for this rider from the list only, \
        and return their IDs exactly as given. Each note is one short line using only that place's facts; \
        never name a stall, dish or number that isn't in the facts. Spell out "park connector" and "hawker centre".
        """

    static func prompt(candidates: [KitCandidate], profile: RiderProfile, count: Int) -> String {
        let likes = profile.likes.isEmpty ? "nothing in particular yet" : Interest.allCases.filter(profile.likes.contains).map(\.label).joined(separator: ", ")
        let today = profile.today.isEmpty ? "" : "\nRiding today: " + RideContext.allCases.filter(profile.today.contains).map(\.label).joined(separator: ", ") + "."
        return """
            The rider likes: \(likes).\(today)
            Pick \(count) places spread along the route. The list is ordered best match first for this rider: \
            prefer places near the top that fit what they like.
            For each, write a fresh note under 12 words from that place's facts. If its facts are "none", \
            say only what kind of place it is.
            Places (ID | name | kind | km along the route | facts):
            \(candidates.prefix(40).map(\.line).joined(separator: "\n"))
            """
    }

    /// The model's answer, or nil when there is no model, it fails, or it's slower than `timeout`.
    static func pick(candidates: [KitCandidate], profile: RiderProfile, count: Int, timeout: Duration = .seconds(8),
                     ask: @escaping @Sendable (String) async throws -> [ModelPick] = KitModel.askSystemModel) async -> [ModelPick]? {
        let text = prompt(candidates: candidates, profile: profile, count: count)
        return await withTaskGroup(of: [ModelPick]?.self) { group in
            group.addTask { try? await ask(text) }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The model's picks for this line, validated, or nil to keep the quick picks.
    static func refine(line: [Coord], quick: [Sight], candidates: [KitCandidate], profile: RiderProfile) async -> [Sight]? {
        guard !quick.isEmpty, let raw = await pick(candidates: candidates, profile: profile, count: quick.count) else { return nil }
        let length = Geo.cumulative(Geo.sample(line.map(\.cl), count: 400)).last ?? 0
        return validate(raw, candidates: candidates, count: quick.count, quick: quick, facts: Discovery.facts, lengthMeters: length)
    }

    /// Exactly `count` real candidates in route order: unknown IDs dropped, duplicates
    /// once, extras cut, gaps filled from the quick picks; every note grounded or
    /// replaced by the template note.
    static func validate(_ raw: [ModelPick], candidates: [KitCandidate], count: Int, quick: [Sight],
                         facts: [String: PlaceFacts], lengthMeters: Double) -> [Sight] {
        let byID = Dictionary(candidates.map { ($0.sight.osmID ?? $0.sight.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        var chosen: [Sight] = [], seen: Set<String> = []
        for p in raw where chosen.count < count {
            guard let c = byID[p.id], seen.insert(p.id).inserted else { continue }
            var s = c.sight
            s.note = noteIsGrounded(p.note, in: c) ? p.note.trimmingCharacters(in: .whitespacesAndNewlines)
                : Kit.templateNote(s, facts: s.osmID.flatMap { facts[$0] }, lengthMeters: lengthMeters)
            chosen.append(s)
        }
        for s in quick where chosen.count < count {
            let id = s.osmID ?? s.id.uuidString
            guard byID[id] != nil, seen.insert(id).inserted else { continue }
            chosen.append(s)
        }
        return chosen.sorted { $0.offsetAlong < $1.offsetAlong }
    }

    /// A note may only name what the candidate's line names: every capitalised word
    /// (bar a sentence's first, "Kit" and "km"), every number, and every dish we know of.
    static func noteIsGrounded(_ note: String, in candidate: KitCandidate) -> Bool {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // "none" is the facts placeholder, not a note; a note is one short line.
        guard !trimmed.isEmpty, trimmed.count <= 100, tokens(trimmed).map({ $0.lowercased() }) != ["none"] else { return false }
        let lineTokens = Set(tokens(candidate.line).map { $0.lowercased() })
        var sentenceStart = true
        for raw in trimmed.split(whereSeparator: \.isWhitespace).map(String.init) {
            defer { sentenceStart = raw.last.map { ".!?".contains($0) } ?? false }
            for t in tokens(raw) {
                let named = t.first?.isNumber == true || (t.first?.isUppercase == true && !sentenceStart)
                if named, !["kit", "km"].contains(t.lowercased()), !lineTokens.contains(t.lowercased()) { return false }
            }
        }
        let noteText = " " + tokens(trimmed).joined(separator: " ").lowercased() + " "
        let lineText = " " + tokens(candidate.line).joined(separator: " ").lowercased() + " "
        return !dishWords.contains { noteText.contains(" \($0) ") && !lineText.contains(" \($0) ") }
    }

    private static func tokens(_ s: String) -> [String] {
        s.matches(of: /[\p{L}\p{N}]+(?:[.'][\p{L}\p{N}]+)*/).map { String($0.output) }
    }

    /// Dishes a note could invent: every dish in our overlay plus common hawker fare.
    static let dishWords: [String] = {
        let common = ["laksa", "rojak", "popiah", "prata", "roti prata", "murtabak", "bak kut teh", "char kway teow", "mee goreng",
                      "nasi goreng", "nasi briyani", "briyani", "yong tau foo", "chilli crab", "kaya toast", "otah", "putu piring",
                      "hor fun", "bak chor mee", "duck rice", "fish ball", "fishball", "economic rice", "dim sum", "durian", "kopi",
                      "teh tarik", "chee cheong fun", "lontong", "mee pok", "goreng pisang", "kueh", "tutu kueh", "satay", "noodles"]
        let ours = Discovery.facts.values.flatMap { $0.note?.dishes ?? [] }
        return Array(Set((common + ours).map { tokens($0).joined(separator: " ").lowercased() }))
    }()

    static func askSystemModel(_ prompt: String) async throws -> [ModelPick] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: instructions)
            let answer = try await session.respond(to: prompt, generating: KitAnswer.self).content
            return answer.picks.map { ModelPick(id: $0.id, note: $0.note) }
        }
        #endif
        throw CancellationError()   // no model on this iPhone: the caller keeps the quick picks
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct KitAnswer {
    @Guide(.maximumCount(12))
    var picks: [KitAnswerPick]
}

@available(iOS 26.0, *)
@Generable
struct KitAnswerPick {
    var id: String
    @Guide(description: "One short line, only from this place's facts")
    var note: String
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

        // Validate.
        let junk = [ModelPick(id: "zzz", note: "Nice"), ModelPick(id: "e", note: "Quiet stretch by the water"),
                    ModelPick(id: "e", note: "Again"), ModelPick(id: "a", note: "Try the satay")]
        let v = validate(junk, candidates: cs, count: 3, quick: quick, facts: [:], lengthMeters: length)
        assert(v.count == 3, "topped up to count: \(v.map(\.osmID))")
        assert(Set(v.compactMap(\.osmID)).count == 3 && !v.contains { $0.osmID == "zzz" }, "unknown dropped, duplicates once: \(v.map(\.osmID))")
        assert(v.allSatisfy { s in cs.contains { $0.sight.id == s.id } }, "every pick is a candidate")
        assert(v.map(\.offsetAlong) == v.map(\.offsetAlong).sorted(), "route order")
        assert(v.first { $0.osmID == "a" }?.note == "Try the satay", "grounded note kept")
        let many = cs.map { ModelPick(id: $0.sight.osmID!, note: "Worth a stop") }
        assert(validate(many, candidates: cs, count: 3, quick: quick, facts: [:], lengthMeters: length).count == 3, "cut to count")

        // Grounding.
        let a = cs[0]
        assert(noteIsGrounded("Try the satay", in: a), "satay is in the facts")
        assert(!noteIsGrounded("Try the laksa", in: a), "laksa is not")
        assert(!noteIsGrounded("Tian Tian Chicken Rice is a Bib pick", in: a), "invented stall")
        assert(!noteIsGrounded("Open until 11 pm", in: a), "invented number")
        assert(noteIsGrounded("Kit says satay at km 1.0", in: a), "Kit and km are always fine")
        assert(!noteIsGrounded("", in: a) && !noteIsGrounded("   ", in: a), "empty note")
        assert(!noteIsGrounded("none", in: a) && !noteIsGrounded("None.", in: a), "the facts placeholder is not a note")
        assert(!noteIsGrounded(String(repeating: "satay ", count: 20), in: a), "a note is one short line")
        let bad = validate([ModelPick(id: "a", note: "Try the laksa")], candidates: cs, count: 1, quick: [], facts: [:], lengthMeters: length)
        assert(bad.first?.note == Kit.templateNote(a.sight, facts: nil, lengthMeters: length), "ungrounded note replaced by the template")

        // Fallbacks.
        struct Boom: Error {}
        let threw = await pick(candidates: cs, profile: RiderProfile(), count: 3) { _ in throw Boom() }
        assert(threw == nil, "a throwing model gives nil")
        let clock = ContinuousClock(), t0 = clock.now
        let slow = await pick(candidates: cs, profile: RiderProfile(), count: 3, timeout: .milliseconds(200)) { _ in
            try await Task.sleep(for: .seconds(10)); return [ModelPick(id: "a", note: "late")]
        }
        assert(slow == nil && clock.now - t0 < .seconds(1), "timeout gives nil fast: \(clock.now - t0)")
        let good = await pick(candidates: cs, profile: RiderProfile(), count: 3) { _ in [ModelPick(id: "b", note: "Quiet")] }
        assert(good == [ModelPick(id: "b", note: "Quiet")], "a good model's picks come back")

        // Prompt.
        let pr = prompt(candidates: cs, profile: RiderProfile(likes: [.food, .heritage]), count: 3)
        assert(cs.allSatisfy { pr.contains($0.line) }, "prompt has every line")
        assert(pr.contains("Food") && pr.contains("Heritage") && pr.contains("3"), "prompt has likes and count")
        let fifty = (0..<50).map { c("x\($0)", km: Double($0) / 10) }
        assert(prompt(candidates: fifty, profile: RiderProfile(), count: 3).components(separatedBy: "\n").filter { $0.hasPrefix("x") }.count == 40,
               "at most 40 candidate lines")

        // Generation guard: an answer for an older line never lands.
        assert(RouteBuilderView.apply(v, forGeneration: 4, current: 5) == nil, "stale answer dropped")
        assert(RouteBuilderView.apply(v, forGeneration: 5, current: 5)?.count == 3, "current answer applied")
        print("KitModel check: validate, grounding, fallbacks (timeout in \(clock.now - t0)), prompt, guard")
    }
}
