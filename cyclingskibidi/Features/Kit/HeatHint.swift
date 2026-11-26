//
//  HeatHint.swift
//  cyclingskibidi
//
//  Singapore's afternoon heat and storms, as a short hint on the route brief.
//  Pure: no main actor, no UI.
//

import Foundation

nonisolated enum HeatHint {
    static let text = "Cooler before 10 am or after 5 pm; 1–4 pm is hottest and storms are common."

    /// Singapore's 1–4 pm heat window (13:00 through 16:59), in Singapore time.
    static func isHot(_ start: Date) -> Bool {
        guard let hour = Closures.sg.dateComponents([.hour], from: start).hour else { return false }
        return (13...16).contains(hour)
    }

    /// The first sheltered rest stop on a hot ride, if the ride has one.
    static func shelterSuggestion(start: Date, stops: [RestStop]) -> String? {
        guard isHot(start), let stop = stops.first(where: \.sheltered) else { return nil }
        return "It's the hottest part of the day. \(stop.name) at km \(String(format: "%.1f", stop.offsetAlong / 1000)) has shelter."
    }

    static func selfCheck() {
        assert(text == "Cooler before 10 am or after 5 pm; 1–4 pm is hottest and storms are common.",
               "heat hint copy: \(text)")

        func at(_ hour: Int, _ minute: Int) -> Date {
            Closures.sg.date(from: DateComponents(year: 2026, month: 11, day: 27,
                                                  hour: hour, minute: minute))!
        }
        assert(!isHot(at(12, 59)), "12:59 is not hot")
        assert(isHot(at(13, 0)), "13:00 is hot")
        assert(isHot(at(16, 59)), "16:59 is hot")
        assert(!isHot(at(17, 0)), "17:00 is not hot")

        func stop(_ name: String, _ km: Double, _ amenities: [String]) -> RestStop {
            RestStop(name: name, lat: 1.30, lon: 103.80,
                     offsetAlong: km * 1000, amenities: amenities)
        }
        let hot = at(14, 0)
        let tap = stop("Tap", 3, ["drinkingWater"])
        assert(shelterSuggestion(start: hot, stops: [tap]) == nil, "no sheltered stop, no suggestion")
        let stops = [tap, stop("Shade", 5, ["shelter"]), stop("Canopy", 9, ["shelter"])]
        let expected = "It's the hottest part of the day. Shade at km 5.0 has shelter."
        assert(shelterSuggestion(start: hot, stops: stops) == expected,
               "first sheltered stop: \(shelterSuggestion(start: hot, stops: stops) ?? "nil")")
        assert(shelterSuggestion(start: at(9, 0), stops: stops) == nil, "no suggestion outside the hot window")
    }
}
