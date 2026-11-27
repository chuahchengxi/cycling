//
//  StatsView.swift
//  cyclingskibidi
//
//  Riding statistics across every ride in the store, whether it was recorded
//  here or pulled in off a Garmin or COROS.
//

import SwiftUI
import SwiftData

struct StatsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Ride.startedAt, order: .reverse) private var rides: [Ride]

    @State private var window: Window = .month
    @State private var importing = false

    enum Window: String, CaseIterable, Identifiable {
        case week = "Week", month = "Month", year = "Year", all = "All"
        var id: String { rawValue }

        var start: Date {
            let cal = Calendar.current
            switch self {
            case .week:  return cal.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
            case .month: return cal.date(byAdding: .month, value: -1, to: .now) ?? .distantPast
            case .year:  return cal.date(byAdding: .year, value: -1, to: .now) ?? .distantPast
            case .all:   return .distantPast
            }
        }
    }

    private var scoped: [Ride] { rides.filter { $0.startedAt >= window.start } }
    private var totalDistance: Double { scoped.reduce(0) { $0 + $1.distanceMeters } }
    private var totalTime: Double { scoped.reduce(0) { $0 + $1.movingSeconds } }
    private var totalAscent: Double { scoped.reduce(0) { $0 + $1.ascentMeters } }
    private var averageSpeed: Double { totalTime > 0 ? totalDistance / totalTime : 0 }
    private var longest: Ride? { scoped.max { $0.distanceMeters < $1.distanceMeters } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    periodPicker
                    totalsGrid
                    chartSection
                    ridesSection
                }
                .padding(16)
            }
            .kitScreen()
            .navigationDestination(for: Ride.self) { RideDetailView(ride: $0) }
            .navigationTitle("Statistics")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button(importing ? "Syncing…" : "Sync") { syncNow() }
                        .disabled(importing)
                }
            }
        }
    }

    /// One bordered box with ink dividers; the chosen segment is ink-filled.
    private var periodPicker: some View {
        HStack(spacing: 0) {
            ForEach(Array(Window.allCases.enumerated()), id: \.element.id) { index, option in
                Button { window = option } label: {
                    Text(option.rawValue)
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(window == option ? KitColor.paper : KitColor.ink)
                        .background(window == option ? KitColor.ink : KitColor.paper)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(window == option ? AccessibilityTraits.isSelected : AccessibilityTraits())
                if index < Window.allCases.count - 1 {
                    Rectangle().fill(KitColor.ink).frame(width: 2, height: 44)
                }
            }
        }
        .background(KitColor.paper)
        .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
    }

    private var totalsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            let distance = splitValueUnit(Fmt.km(totalDistance))
            statTile(caption: "Distance", value: distance.0, unit: distance.1)

            let moving = movingTime
            statTile(caption: "Moving", value: moving.0, unit: moving.1)

            let speed = splitValueUnit(Fmt.speed(averageSpeed))
            statTile(caption: "Avg speed", value: speed.0, unit: speed.1)

            statTile(caption: "Climbed", value: "\(Int(totalAscent))", unit: "m")
            statTile(caption: "Rides", value: "\(scoped.count)")
            if let longest {
                let longestDistance = splitValueUnit(Fmt.km(longest.distanceMeters))
                statTile(caption: "Longest", value: longestDistance.0, unit: longestDistance.1)
            }
        }
    }

    @ViewBuilder
    private func statTile(caption: String, value: String, unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption).font(.footnote).foregroundStyle(KitColor.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.kitNumber(.title)).lineLimit(1).minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit).font(.footnote).foregroundStyle(KitColor.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kitCard(KitColor.board, padding: 12)
        .accessibilityElement(children: .combine)
    }

    private func splitValueUnit(_ text: String) -> (String, String) {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : (text, "")
    }

    private var movingTime: (String, String) {
        let seconds = Int(totalTime.rounded())
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return (hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m", "")
    }

    /// Days that actually cover ground — the cells worth colouring in.
    private var ridingDays: Int { daily.filter { $0.km > 0 }.count }

    /// Distance summed per calendar day, for the heatmap. All rides: the grid is always 20 weeks.
    private var daily: [(day: Date, km: Double)] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: rides) { cal.startOfDay(for: $0.startedAt) }
        return grouped
            .map { (day: $0.key, km: $0.value.reduce(0) { $0 + $1.distanceKM }) }
            .sorted { $0.day < $1.day }
    }

    /// Twenty weeks of square cells, ending today, so the grid reads like the board.
    private var heatDays: [(day: Date, km: Double)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let byDay = Dictionary(uniqueKeysWithValues: daily.map { ($0.day, $0.km) })
        return (0..<140).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -(139 - offset), to: today) else { return nil }
            return (day: day, km: byDay[day] ?? 0)
        }
    }

    private var peakKm: Double { daily.map(\.km).max() ?? 1 }

    private func heatColor(_ km: Double) -> Color {
        guard km > 0, peakKm > 0 else { return KitColor.line }
        switch Int((km / peakKm * 3).rounded()) {
        case 0, 1: return KitColor.sage.opacity(0.45)
        case 2: return KitColor.sage
        default: return KitColor.accentStrong
        }
    }

    @ViewBuilder
    private var chartSection: some View {
        if ridingDays > 0 {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Rides, last 20 weeks").font(.footnote.weight(.semibold))
                    Spacer(minLength: 4)
                    Text("Less").font(.caption2).foregroundStyle(KitColor.muted)
                    HStack(spacing: 2) {
                        ForEach([KitColor.line, KitColor.sage.opacity(0.45), KitColor.sage, KitColor.accentStrong],
                                id: \.self) { color in
                            Rectangle().fill(color).frame(width: 10, height: 10)
                        }
                    }
                    Text("More").font(.caption2).foregroundStyle(KitColor.muted)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 20),
                          spacing: 3) {
                    ForEach(heatDays, id: \.day) { entry in
                        Rectangle().fill(heatColor(entry.km)).aspectRatio(1, contentMode: .fit)
                    }
                }
            }
            .kitCard(KitColor.board, padding: 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rides, last 20 weeks")
            .accessibilityValue("\(ridingDays) riding \(ridingDays == 1 ? "day" : "days")")
        } else if !scoped.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Distance per day").font(.kitLabel).foregroundStyle(KitColor.muted)
                Text("No distance recorded in this window.")
                    .font(.footnote).foregroundStyle(KitColor.muted)
            }
            .kitCard(KitColor.board, padding: 12)
        }
    }

    private var ridesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            KitHeader("Rides")
            if scoped.isEmpty {
                Text("Nothing in this window.").font(.footnote).foregroundStyle(KitColor.muted)
            } else {
                ForEach(Array(scoped.enumerated()), id: \.element.id) { index, ride in
                    NavigationLink(value: ride) { RideRow(ride: ride) }
                        .buttonStyle(.plain)
                        // A scroll view, not a List, so no swipe: delete sits on long-press and in the VoiceOver rotor.
                        .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { delete(IndexSet(integer: index)) } }
                        .accessibilityAction(named: "Delete") { delete(IndexSet(integer: index)) }
                }
            }
        }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { context.delete(scoped[index]) }
        try? context.save()
    }

    /// Pull in cycling workouts from Apple Health / Garmin / COROS. importRides
    /// skips anything already stored, so Sync just fetches what's new.
    private func syncNow() {
        guard !importing else { return }
        Task {
            importing = true
            _ = try? await Providers.importRides(into: context)
            importing = false
        }
    }
}

struct RideRow: View {
    let ride: Ride

    var body: some View {
        HStack(spacing: 12) {
            Image("kit-icon-bike").renderingMode(.template).resizable()
                .frame(width: 22, height: 22)
                .foregroundStyle(KitColor.ink)
                .frame(width: 40, height: 40)
                .background(KitColor.paper)
                .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
            VStack(alignment: .leading, spacing: 3) {
                Text(ride.routeName.isEmpty ? "Ride" : ride.routeName)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(ride.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(ride.source.rawValue)")
                    .font(.footnote).foregroundStyle(KitColor.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.km(ride.distanceMeters))
                    .font(.kitNumber(.headline)).lineLimit(1).minimumScaleFactor(0.7)
                Text(Fmt.clock(ride.movingSeconds))
                    .font(.footnote).foregroundStyle(KitColor.muted)
            }
        }
        .foregroundStyle(KitColor.ink)
        .kitCard(KitColor.paper, padding: 10)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    StatsView()
        .modelContainer(for: [Route.self, Ride.self], inMemory: true)
}
