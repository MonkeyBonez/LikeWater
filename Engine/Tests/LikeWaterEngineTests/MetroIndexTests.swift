import XCTest
@testable import LikeWaterEngine

final class MetroIndexTests: XCTestCase {
    static let inline = """
    {"id":"tiny","name":"Tiny","tileLat":0.04,"tileLon":0.05,"minLat":47.48,"minLon":-122.45,
     "maxLat":47.56,"maxLon":-122.35,"bytes":3,"tiles":[
       {"i":1187,"j":-2449,"file":"a.lwbundle","bytes":1},
       {"i":1188,"j":-2448,"file":"b.lwbundle","bytes":2}]}
    """

    func testOldIndexesWithoutBuildTimeStillDecode() throws {
        let m = try JSONDecoder().decode(MetroIndex.self, from: Data(Self.inline.utf8))
        XCTAssertNil(m.built)
        XCTAssertEqual(m.buildKey, "legacy")
        XCTAssertEqual(m.tile(containingLat: 47.50, lon: -122.44)?.file, "a.lwbundle")
        XCTAssertNil(m.tile(containingLat: 47.50, lon: -122.36), "no tile there: water or no streets")
        XCTAssertEqual(m.tiles(intersecting: BBox(minLat: 47.47, minLon: -122.46, maxLat: 47.53, maxLon: -122.41)).map(\.file), ["a.lwbundle"])
    }

    func testBuildKeysOrderBuilds() throws {
        var a = try JSONDecoder().decode(MetroIndex.self, from: Data(Self.inline.utf8))
        var b = a
        a.built = "2026-09-30T06:57:16+00:00"
        b.built = "2026-10-01T05:09:34+00:00"
        XCTAssertEqual(a.buildKey, "20260930065716")
        XCTAssertTrue(b.isNewer(than: a))
        XCTAssertFalse(a.isNewer(than: b))
        var legacy = a; legacy.built = nil
        XCTAssertTrue(a.isNewer(than: legacy))
        XCTAssertFalse(legacy.isNewer(than: a))
    }

    func testExtendsBeyondOnlyOutsideTheBounds() throws {
        let m = try JSONDecoder().decode(MetroIndex.self, from: Data(Self.inline.utf8))
        XCTAssertFalse(m.extendsBeyond(BBox(minLat: 47.49, minLon: -122.44, maxLat: 47.55, maxLon: -122.36)))
        XCTAssertTrue(m.extendsBeyond(BBox(minLat: 47.55, minLon: -122.40, maxLat: 47.60, maxLon: -122.36)))
        XCTAssertTrue(m.intersects(BBox(minLat: 47.55, minLon: -122.40, maxLat: 47.60, maxLon: -122.36)))
        XCTAssertFalse(m.intersects(BBox(minLat: 45.0, minLon: -122.7, maxLat: 45.1, maxLon: -122.6)))
    }

    func testTheRealSeattleIndexDecodes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Server/seattle/metro.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("seattle not built") }
        let m = try MetroIndex.load(from: url)
        XCTAssertEqual(m.id, "seattle")
        XCTAssertNotEqual(m.buildKey, "legacy")
        XCTAssertGreaterThan(m.tiles.count, 20)
        XCTAssertNotNil(m.far)
    }
}

final class CachePolicyTests: XCTestCase {
    func e(_ k: String, _ b: Int, _ t: Double) -> CacheEntry { CacheEntry(key: k, bytes: b, lastUsed: Date(timeIntervalSince1970: t)) }

    func testUnderTheCapNothingGoes() {
        XCTAssertEqual(CachePolicy.evictions([e("a", 10, 1), e("b", 10, 2)], capBytes: 20, protected: []), [])
    }

    func testOldestGoFirstUntilUnderTheCap() {
        let entries = [e("new", 10, 9), e("old", 10, 1), e("mid", 10, 5), e("older", 10, 2)]
        XCTAssertEqual(CachePolicy.evictions(entries, capBytes: 20, protected: []), ["old", "older"])
    }

    func testProtectedFilesAreNeverEvictedEvenOverTheCap() {
        let entries = [e("stitch1", 30, 1), e("stitch2", 30, 2), e("spare", 5, 3)]
        XCTAssertEqual(CachePolicy.evictions(entries, capBytes: 20, protected: ["stitch1", "stitch2"]), ["spare"])
    }
}
