//
//  ObstacleStore.swift
//  cyclingskibidi
//
//  Community hazards, shared across every user. SwiftData/CloudKit only syncs an
//  account's *private* store, so obstacles instead live in the CloudKit *public*
//  database — one shared pool that every rider reads from and writes to.
//
//  One-time setup in the CloudKit Dashboard: record type "Obstacle" with a
//  Queryable index on the `location` field (and on `recordName`), plus a
//  Sortable index on `reportedAt`. The record type auto-appears in Development
//  on the first save; the indexes you add by hand, then deploy to Production.
//

import Foundation
import CloudKit
import CoreLocation
import Observation

@Observable
@MainActor
final class ObstacleStore {

    private(set) var obstacles: [Obstacle] = []
    /// Set when a load or report fails (not signed into iCloud, offline, …).
    var errorMessage: String?

    private let db = CKContainer.default().publicCloudDatabase
    private static let recordType = "Obstacle"

    // MARK: - Reading

    /// Load the hazards near a route. Bounds the query to a radius around the
    /// route's centre so a rider only pulls what they might ride past.
    func load(around polyline: [Coord]) async {
        guard !polyline.isEmpty else { return }
        let lats = polyline.map(\.lat), lons = polyline.map(\.lon)
        let center = CLLocation(latitude: (lats.min()! + lats.max()!) / 2,
                                longitude: (lons.min()! + lons.max()!) / 2)
        let corner = CLLocation(latitude: lats.max()!, longitude: lons.max()!)
        // Cover the whole route plus a margin, with a floor for tiny routes.
        let radius = max(corner.distance(from: center) * 1.3, 500)

        let predicate = NSPredicate(format: "distanceToLocation:fromLocation:(%K,%@) < %f",
                                    "location", center, radius)
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "reportedAt", ascending: false)]

        do {
            let (matches, _) = try await db.records(matching: query)
            obstacles = matches.compactMap { _, result in
                (try? result.get()).flatMap(Obstacle.init(record:))
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load shared hazards. \(error.localizedDescription)"
        }
    }

    // MARK: - Writing

    /// Post a hazard for everyone. Appends it locally on success so it shows at
    /// once, before CloudKit's index catches up and returns it to queries.
    func report(kind: ObstacleKind, at coordinate: CLLocationCoordinate2D, note: String) async {
        let record = CKRecord(recordType: Self.recordType)
        record["kind"] = kind.rawValue as CKRecordValue
        record["note"] = note as CKRecordValue
        record["reportedAt"] = Date.now as CKRecordValue
        record["confirmations"] = 0 as CKRecordValue
        record["location"] = CLLocation(latitude: coordinate.latitude,
                                        longitude: coordinate.longitude)

        do {
            let saved = try await db.save(record)
            if let obstacle = Obstacle(record: saved) { obstacles.insert(obstacle, at: 0) }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't share that hazard. \(error.localizedDescription)"
        }
    }
}

private extension Obstacle {
    /// Build from a public-database record; nil if it is missing the essentials.
    init?(record: CKRecord) {
        guard let kindRaw = record["kind"] as? String,
              let location = record["location"] as? CLLocation else {
            return nil
        }
        self.init(id: record.recordID.recordName,
                  kind: ObstacleKind(rawValue: kindRaw) ?? .pothole,
                  at: location.coordinate,
                  note: record["note"] as? String ?? "",
                  reportedAt: record["reportedAt"] as? Date ?? .now,
                  confirmations: record["confirmations"] as? Int ?? 0)
    }
}
