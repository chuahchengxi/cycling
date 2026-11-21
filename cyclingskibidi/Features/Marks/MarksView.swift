//
//  MarksView.swift
//  cyclingskibidi
//
//  Every hazard the rider has marked, with when it ends. Swipe one away once
//  it's cleared: routes stop avoiding it and rides stop warning about it.
//

import SwiftUI
import SwiftData

struct MarksView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Obstacle.reportedAt, order: .reverse) private var marks: [Obstacle]

    var body: some View {
        NavigationStack {
            List {
                ForEach(marks) { mark in
                    HStack(spacing: 12) {
                        ObstacleBadge(kind: mark.kind)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mark.kind.rawValue).font(.body.weight(.semibold))
                            if !mark.note.isEmpty { Text(mark.note).font(.subheadline).foregroundStyle(.secondary) }
                            Text("\(mark.expiryText) · marked \(mark.reportedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(mark.isActive ? Color.secondary : Color.orange)
                        }
                    }
                    .opacity(mark.isActive ? 1 : 0.6)
                    .accessibilityElement(children: .combine)
                    .swipeActions {
                        Button(role: .destructive) { remove(mark) } label: { Label("Remove", systemImage: "trash") }
                    }
                }
                .onDelete { $0.map { marks[$0] }.forEach(remove) }
            }
            .overlay {
                if marks.isEmpty {
                    ContentUnavailableView("No marks", systemImage: "exclamationmark.triangle",
                                           description: Text("Hazards you mark on a ride show up here."))
                }
            }
            .navigationTitle("Your marks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { EditButton().disabled(marks.isEmpty) }
            }
        }
    }

    private func remove(_ mark: Obstacle) {
        context.delete(mark)
        try? context.save()
    }
}

/// Where the map, roads, places, elevation and closures come from.
struct CreditsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Map, roads and places") {
                    Text("© OpenStreetMap contributors. Map data is available under the Open Database Licence (ODbL); see openstreetmap.org/copyright.")
                    Text("Map tiles are drawn by this app from that data and ship inside it, so the map works offline.")
                }
                Section("Elevation") {
                    Text("Terrain Tiles (Mapzen, hosted by AWS Open Data), from SRTM and other public sources.")
                }
                Section("Park connectors and closures") {
                    Text("Park connector routes and closure notices from NParks, matched to OpenStreetMap paths.")
                }
            }
            .navigationTitle("Credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
