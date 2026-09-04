//
//  StatsView.swift
//  cyclingskibidi
//
//  Riding statistics across every ride in the store, whether it was recorded
//  here or pulled in off a Garmin or COROS.
//

import SwiftUI
import SwiftData
import Charts

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
            List {
                Section {
                    Picker("Window", selection: $window) {
                        ForEach(Window.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(.init())
                    .listRowBackground(Color.clear)
                }

                Section("Totals") {
                    LabeledContent("Distance", value: Fmt.km(totalDistance))
                    LabeledContent("Moving time", value: Fmt.clock(totalTime))
                    LabeledContent("Average speed", value: Fmt.speed(averageSpeed))
                    LabeledContent("Climbed", value: "\(Int(totalAscent)) m")
                    LabeledContent("Rides", value: "\(scoped.count)")
                    if let longest {
                        LabeledContent("Longest", value: Fmt.km(longest.distanceMeters))
                    }
                }

                if daily.count > 1 {
                    Section("Distance per day") {
                        Chart(daily, id: \.day) { entry in
                            BarMark(x: .value("Day", entry.day, unit: .day),
                                    y: .value("km", entry.km))
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(height: 180)
                    }
                }

                Section("Rides") {
                    if scoped.isEmpty {
                        Text("Nothing in this window.").foregroundStyle(.secondary)
                    }
                    ForEach(scoped) { ride in
                        NavigationLink(value: ride) { RideRow(ride: ride) }
                    }
                    .onDelete(perform: delete)
                }
            }
            .navigationDestination(for: Ride.self) { RideDetailView(ride: $0) }
            .navigationTitle("Statistics")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sync") { syncNow() }.disabled(importing)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { syncNow() } label: {
                        if importing { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(importing)
                    .accessibilityLabel("Refresh")
                }
            }
        }
    }

    /// Distance summed per calendar day, for the bar chart.
    private var daily: [(day: Date, km: Double)] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: scoped) { cal.startOfDay(for: $0.startedAt) }
        return grouped
            .map { (day: $0.key, km: $0.value.reduce(0) { $0 + $1.distanceKM }) }
            .sorted { $0.day < $1.day }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { context.delete(scoped[index]) }
        try? context.save()
    }

    /// Pull in cycling workouts from Apple Health / Garmin / COROS. importRides
    /// skips anything already stored, so Sync and Refresh both just fetch what's new.
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
            Image(systemName: ride.source.symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(ride.routeName.isEmpty ? "Ride" : ride.routeName)
                    .font(.subheadline.weight(.semibold))
                Text(ride.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.km(ride.distanceMeters)).font(.subheadline).monospacedDigit()
                Text(Fmt.clock(ride.movingSeconds)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    StatsView()
        .modelContainer(for: [Route.self, Obstacle.self, Ride.self], inMemory: true)
}
