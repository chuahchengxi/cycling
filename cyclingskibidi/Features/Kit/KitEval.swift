//
//  KitEval.swift
//  cyclingskibidi
//
//  DEBUG eval of Kit's model picks on real routes (launch with -kiteval). For each
//  route × rider it plans the line, makes the quick picks, asks the on-device model and
//  logs: latency, IDs returned / real / made up, whether `accept` kept the model's picks,
//  summed score and interest match against the quick picks, and the tightest spacing.
//  Needs Apple Intelligence (a recent iPhone, or a Mac host that has it); without it every
//  row says so and the run ends.
//

#if DEBUG
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated enum KitEval {
    static let riders: [(name: String, profile: RiderProfile)] = [
        ("food", RiderProfile(likes: [.food])),
        ("heritage+arch", RiderProfile(likes: [.heritage, .architecture])),
        ("nature+wildlife", RiderProfile(likes: [.nature, .wildlife])),
        ("cafes+art", RiderProfile(likes: [.cafes, .art])),
        ("no likes", RiderProfile()),
    ]

    static var routes: [(name: String, waypoints: [Coord])] {
        PresetLoops.all.map { ($0.name, $0.waypoints) }
            + [("One-North", [Coord(lat: 1.2995, lon: 103.7876), Coord(lat: 1.3046, lon: 103.7930), Coord(lat: 1.2966, lon: 103.7900)])]
    }

    static var available: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return "\(SystemLanguageModel.default.availability)" }
        #endif
        return "no FoundationModels"
    }

    static func run() async {
        print("KITEVAL model: \(available)")
        print("KITEVAL route | rider | n | ms | ids real/made-up | accepted | score quick→model | liked quick→model | min gap km quick/model")
        var rows = 0, answered = 0, accepted = 0, madeUp = 0, returned = 0, slow = 0, latencies: [Double] = []
        let facts = Discovery.facts
        for route in routes {
            guard let plan = try? await Routing.plan(through: route.waypoints, mode: .leisure), plan.polyline.count > 1 else {
                print("KITEVAL \(route.name): no plan"); continue
            }
            let line = plan.polyline
            let length = Geo.cumulative(Geo.sample(line.map(\.cl), count: 400)).last ?? 0
            for rider in riders {
                let p = rider.profile
                let found = Kit.picks(along: line, mode: .leisure, profile: p)
                guard !found.quick.isEmpty else { print("KITEVAL \(route.name) | \(rider.name) | no candidates"); continue }
                rows += 1
                let t0 = ContinuousClock.now
                let ids = await KitModel.pick(candidates: found.candidates, profile: p, count: found.quick.count,
                                              quick: found.quick, timeout: .seconds(60))
                let ms = (ContinuousClock.now - t0) / .milliseconds(1)
                guard let ids else {
                    print("KITEVAL \(route.name) | \(rider.name) | \(found.quick.count) | \(Int(ms)) | no answer")
                    if available.contains("unavailable") || available.contains("no Foundation") { break } else { continue }
                }
                answered += 1; latencies.append(ms); if ms > 8000 { slow += 1 }
                let known = Set(found.candidates.map { $0.sight.osmID ?? $0.sight.id.uuidString })
                let real = ids.filter { known.contains(String($0.split(separator: " ").first ?? "")) }.count
                returned += ids.count; madeUp += ids.count - real
                let model = KitModel.validate(ids, candidates: found.candidates, count: found.quick.count, quick: found.quick,
                                              facts: facts, lengthMeters: length)
                let score: (Sight) -> Double = { Kit.score($0, profile: p, facts: facts) }
                let ok = KitModel.accept(model, over: found.quick, lengthMeters: length, score: score)
                if ok { accepted += 1 }
                // Liked = the rider's interests add to the score (same Kit.score, likes removed).
                var noLikes = p; noLikes.likes = []
                func liked(_ xs: [Sight]) -> Int { xs.filter { score($0) > Kit.score($0, profile: noLikes, facts: facts) }.count }
                func sum(_ xs: [Sight]) -> String { String(format: "%.1f", xs.map(score).reduce(0, +)) }
                func gap(_ xs: [Sight]) -> String {
                    let a = xs.map(\.offsetAlong).sorted()
                    return String(format: "%.1f", (zip(a, a.dropFirst()).map { $1 - $0 }.min() ?? 0) / 1000)
                }
                print("KITEVAL \(route.name) | \(rider.name) | \(found.quick.count) | \(Int(ms)) | \(real)/\(ids.count - real) | \(ok ? "yes" : "no") | \(sum(found.quick))→\(sum(model)) | \(liked(found.quick))→\(liked(model)) | \(gap(found.quick))/\(gap(model))")
            }
        }
        let sorted = latencies.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        print("KITEVAL SUMMARY rows \(rows), answered \(answered), accepted \(accepted), made-up IDs \(madeUp)/\(returned), over 8 s \(slow), median \(Int(median)) ms")
        exit(0)   // -kiteval is a run, not a session
    }
}
#endif
