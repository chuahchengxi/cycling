//
//  PCNDataset.swift
//  cyclingskibidi
//
//  Where the connector graph's raw data comes from. A seed copy ships in the
//  bundle so routing works offline on first launch; a newer version, if we've
//  self-hosted one, is downloaded (sha256-verified) into app-support and used
//  from then on. Singapore keeps opening connectors, so this keeps riders
//  current without an app-store update.
//

import Foundation
import CryptoKit

struct PCNManifest: Decodable {
    let version: Int
    let url: String
    let sha256: String
}

enum PCNDataset {
    /// Self-hosted manifest — the update feed you control (a GitHub raw URL is the
    /// zero-cost default). ponytail: static host; point at wherever you publish.
    static var manifestURL = "https://raw.githubusercontent.com/OWNER/REPO/main/pcn-manifest.json"
    /// At most one refresh check per this interval. ponytail: weekly; loosen/tighten freely.
    static let refreshInterval: TimeInterval = 7 * 24 * 3600

    nonisolated private static let fileName = "pcn.geojson"
    private static var cachedGraph: PCNGraph?
    /// In-flight build, so concurrent first-callers share one off-main build.
    private static var building: Task<PCNGraph, Never>?

    // MARK: Graph

    /// The built graph from the freshest GeoJSON we have. Memoised — the graph is
    /// rebuilt only after a successful refresh (which clears the cache).
    /// The freshest graph, built OFF the main actor (a 1.9 MB decode + ~33k-vertex
    /// adjacency build) and memoised. Concurrent first-callers share one build, so
    /// the work never blocks the UI — not at launch, not on the first plan.
    static func graph() async -> PCNGraph {
        if let g = cachedGraph { return g }
        if let building { return await building.value }
        let task = Task.detached(priority: .userInitiated) { () -> PCNGraph in
            let data = downloadedData() ?? seedData() ?? Data()
            return PCNGraph(polylines: GeoJSON.polylines(data))
        }
        building = task
        let g = await task.value
        cachedGraph = g
        building = nil
        return g
    }

    nonisolated private static func seedData() -> Data? {
        guard let url = Bundle.main.url(forResource: "pcn-seed", withExtension: "geojson") else { return nil }
        return try? Data(contentsOf: url)
    }

    nonisolated private static func downloadedData() -> Data? {
        try? Data(contentsOf: cacheFileURL())
    }

    nonisolated private static func cacheFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    // MARK: Refresh

    /// Throttled: fetch the manifest, and if it names a newer version, download +
    /// verify + install it and drop the cached graph so the next graph() rebuilds.
    static func refreshIfStale() async {
        let now = Date.now.timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: "pcnLastCheck")
        guard now - last >= refreshInterval else { return }
        UserDefaults.standard.set(now, forKey: "pcnLastCheck")

        guard let mURL = URL(string: manifestURL),
              let (mData, _) = try? await URLSession.shared.data(from: mURL),
              let manifest = try? JSONDecoder().decode(PCNManifest.self, from: mData),
              isNewer(manifest, thanCached: UserDefaults.standard.integer(forKey: "pcnVersion")),
              let dURL = URL(string: manifest.url),
              let (data, _) = try? await URLSession.shared.data(from: dURL),
              sha256Hex(data) == manifest.sha256.lowercased(),
              !GeoJSON.polylines(data).isEmpty
        else { return }

        try? data.write(to: cacheFileURL(), options: .atomic)
        UserDefaults.standard.set(manifest.version, forKey: "pcnVersion")
        cachedGraph = nil   // next graph() rebuilds from the new data
        building = nil
    }

    // MARK: Pure helpers (tested)

    static func isNewer(_ manifest: PCNManifest, thanCached cached: Int) -> Bool {
        manifest.version > cached
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Self check

extension PCNDataset {
    static func selfCheck() async {
        // Version compare gates on strictly-newer.
        let m = PCNManifest(version: 5, url: "x", sha256: "y")
        assert(isNewer(m, thanCached: 4) && !isNewer(m, thanCached: 5) && !isNewer(m, thanCached: 6))
        // sha256 of "" is the known empty-string digest.
        assert(sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // The bundled seed is present and parses to a non-trivial network.
        // ponytail: comment out if running before the seed file is added.
        let g = await graph()
        assert(!g.isEmpty, "pcn-seed.geojson missing or empty — is it in the bundle?")
    }
}
