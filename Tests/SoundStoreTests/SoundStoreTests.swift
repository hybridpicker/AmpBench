import XCTest
@testable import SoundStore

/// Two devices and one store, all in temporary folders with made-up sounds.
final class SoundStoreTests: XCTestCase {
    private var root: URL!
    private var storeFolder: URL!
    private let identity = AgeIdentity.generate()

    override func setUpWithError() throws {
        root = try makeTemporaryFolder(self, "devices")
        storeFolder = root.appendingPathComponent("Store")
    }

    private func folder(_ device: String) -> URL { root.appendingPathComponent(device).appendingPathComponent("Presets") }

    private func device(_ name: String, identity: AgeIdentity? = nil, location: StoreLocation? = nil,
                        remove: (@Sendable (URL) throws -> Void)? = nil) -> SoundStore {
        let state = root.appendingPathComponent(name).appendingPathComponent("state.json")
        let location = location ?? FolderLocation(folder: storeFolder)
        if let remove {
            return SoundStore(folder: folder(name), location: location, identity: identity ?? self.identity, stateURL: state, remove: remove)
        }
        return SoundStore(folder: folder(name), location: location, identity: identity ?? self.identity, stateURL: state)
    }

    private func write(_ text: String, _ path: String, on device: String, modified: Date? = nil) throws {
        let url = folder(device).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    private func sounds(on device: String) -> [String: String] {
        allFiles(in: folder(device)).mapValues { String(decoding: $0, as: UTF8.self) }
    }

    func testRoundTripFromTheMacToTheIPad() async throws {
        try write("{\"name\":\"Made-up Lead\"}", "Lead.json", on: "Mac")
        try write("{\"name\":\"Made-up Jazz\"}", "Kemper/Jazz.json", on: "Mac")
        try write("hidden", ".adopted.json", on: "Mac")

        let first = try await device("Mac").sync()
        XCTAssertEqual(first.uploaded, ["Kemper/Jazz.json", "Lead.json"])
        XCTAssertEqual(first.summary, "Store: 2 stored.")
        let status = try await device("Mac").status()
        XCTAssertEqual(status.entries, 2)
        XCTAssertEqual(status.deleted, 0)

        let fetched = try await device("iPad").sync()
        XCTAssertEqual(fetched.downloaded, ["Kemper/Jazz.json", "Lead.json"])
        XCTAssertEqual(fetched.summary, "Store: 2 fetched.")
        XCTAssertEqual(sounds(on: "iPad"), ["Lead.json": "{\"name\":\"Made-up Lead\"}", "Kemper/Jazz.json": "{\"name\":\"Made-up Jazz\"}"])

        for name in ["Mac", "iPad"] {
            let again = try await device(name).sync()
            XCTAssertTrue(again.isEmpty, name)
            XCTAssertEqual(again.unchanged, 2)
            XCTAssertEqual(again.summary, "The store is up to date: 2 sounds.")
        }
    }

    func testTheStoreHoldsOnlyCiphertext() async throws {
        let content = "{\"name\":\"Made-up Lead\",\"gain\":0.4321}"
        try write(content, "Secret Song Name.json", on: "Mac")
        try write(content, "Copy/Secret Song Name 2.json", on: "Mac")
        _ = try await device("Mac").sync()

        let stored = allFiles(in: storeFolder)
        XCTAssertEqual(stored.count, 2, "the manifest and one object: the same content is stored once")
        XCTAssertTrue(stored.keys.allSatisfy(StoreName.isValid))
        for (name, data) in stored {
            XCTAssertTrue(data.starts(with: Data("age-encryption.org/v1\n".utf8)), name)
            for plain in ["Secret", "Song", "Made-up", "gain", "0.4321", "json", "Copy", "entries", "Presets"] {
                XCTAssertNil(data.range(of: Data(plain.utf8)), "\(plain) is readable in \(name)")
            }
            XCTAssertNil(data.range(of: Data(identity.text.utf8)))
        }
    }

    func testAnEditTravelsAndTheOldContentStaysInTheStore() async throws {
        try write("first", "Lead.json", on: "Mac")
        _ = try await device("Mac").sync()
        _ = try await device("iPad").sync()
        let before = allFiles(in: storeFolder).count

        try write("second", "Lead.json", on: "iPad")
        let edited = try await device("iPad").sync()
        XCTAssertEqual(edited.uploaded, ["Lead.json"])
        let arrived = try await device("Mac").sync()
        XCTAssertEqual(arrived.downloaded, ["Lead.json"])
        XCTAssertEqual(sounds(on: "Mac"), ["Lead.json": "second"])
        XCTAssertEqual(allFiles(in: storeFolder).count, before + 1, "the first content is still an object in the store")
    }

    func testAConflictKeepsTheNewerAndStoresTheOther() async throws {
        try write("first", "Lead.json", on: "Mac")
        _ = try await device("Mac").sync()
        _ = try await device("iPad").sync()

        try write("from the Mac, older", "Lead.json", on: "Mac", modified: Date(timeIntervalSinceNow: -3600))
        try write("from the iPad, newer", "Lead.json", on: "iPad", modified: Date(timeIntervalSinceNow: -60))
        _ = try await device("iPad").sync()
        let report = try await device("Mac").sync()
        XCTAssertEqual(report.downloaded, ["Lead.json"])
        XCTAssertEqual(sounds(on: "Mac"), ["Lead.json": "from the iPad, newer"])

        // The Mac's losing version went into the store before it was replaced: three contents, three objects.
        let objects = allFiles(in: storeFolder).filter { $0.key.hasPrefix("objects/") }
        XCTAssertEqual(objects.count, 3)
        let opened = Set(try objects.values.map { String(decoding: try Age.decrypt($0, with: identity), as: UTF8.self) })
        XCTAssertEqual(opened, ["first", "from the Mac, older", "from the iPad, newer"])

        let settled = try await device("iPad").sync()
        XCTAssertTrue(settled.isEmpty)
        XCTAssertEqual(sounds(on: "iPad"), ["Lead.json": "from the iPad, newer"])
    }

    func testRemovingTravelsThroughTheGivenRemoval() async throws {
        try write("first", "Lead.json", on: "Mac")
        try write("stays", "Jazz.json", on: "Mac")
        _ = try await device("Mac").sync()
        _ = try await device("iPad").sync()

        try FileManager.default.removeItem(at: folder("Mac").appendingPathComponent("Lead.json"))
        let removed = try await device("Mac").sync()
        XCTAssertEqual(removed.markedDeleted, ["Lead.json"])
        XCTAssertEqual(removed.summary, "Store: 1 removed in the store.")
        let status = try await device("Mac").status()
        XCTAssertEqual(status.entries, 1)
        XCTAssertEqual(status.deleted, 1)

        // The iPad removes through what the app gives it, which on the Mac is the Trash.
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let report = try await device("iPad", remove: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }).sync()
        XCTAssertEqual(report.removedLocally, ["Lead.json"])
        XCTAssertEqual(sounds(on: "iPad"), ["Jazz.json": "stays"])
        XCTAssertEqual(allFiles(in: trash).keys.sorted(), ["Lead.json"])

        let again = try await device("Mac").sync()
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(sounds(on: "Mac"), ["Jazz.json": "stays"])
    }

    func testARemovedSoundComesBackWhenItIsPutBack() async throws {
        try write("first", "Lead.json", on: "Mac")
        _ = try await device("Mac").sync()
        _ = try await device("iPad").sync()
        try FileManager.default.removeItem(at: folder("Mac").appendingPathComponent("Lead.json"))
        _ = try await device("Mac").sync()
        _ = try await device("iPad").sync()
        XCTAssertTrue(sounds(on: "iPad").isEmpty)

        // The object never left the store: its content is still there to be put back.
        let objects = allFiles(in: storeFolder).filter { $0.key.hasPrefix("objects/") }
        let kept = try XCTUnwrap(objects.values.first)
        try write(String(decoding: try Age.decrypt(kept, with: identity), as: UTF8.self), "Lead.json", on: "Mac")
        let restored = try await device("Mac").sync()
        XCTAssertEqual(restored.uploaded, ["Lead.json"])
        let back = try await device("iPad").sync()
        XCTAssertEqual(back.downloaded, ["Lead.json"])
        XCTAssertEqual(sounds(on: "iPad"), ["Lead.json": "first"])
        let status = try await device("iPad").status()
        XCTAssertEqual(status.entries, 1)
        XCTAssertEqual(status.deleted, 0)
    }

    func testAnEditBeatsARemovalElsewhere() async throws {
        try write("first", "Lead.json", on: "Mac")
        _ = try await device("Mac").sync()
        _ = try await device("iPad").sync()
        try FileManager.default.removeItem(at: folder("Mac").appendingPathComponent("Lead.json"))
        _ = try await device("Mac").sync()
        try write("edited meanwhile", "Lead.json", on: "iPad")
        let report = try await device("iPad").sync()
        XCTAssertEqual(report.uploaded, ["Lead.json"])
        _ = try await device("Mac").sync()
        XCTAssertEqual(sounds(on: "Mac"), ["Lead.json": "edited meanwhile"])
    }

    func testAWrongKeyChangesNothingAnywhere() async throws {
        try write("first", "Lead.json", on: "Mac")
        _ = try await device("Mac").sync()
        let storedBefore = allFiles(in: storeFolder)

        try write("mine", "Other.json", on: "iPad")
        let stranger = device("iPad", identity: AgeIdentity.generate())
        do {
            _ = try await stranger.sync()
            XCTFail("a wrong key synced")
        } catch {
            XCTAssertEqual(error as? StoreError, .wrongKey)
            XCTAssertTrue(error.localizedDescription.hasPrefix("This key does not open the store"))
        }
        do {
            _ = try await stranger.status()
            XCTFail("a wrong key read the status")
        } catch { XCTAssertEqual(error as? StoreError, .wrongKey) }
        XCTAssertEqual(allFiles(in: storeFolder), storedBefore)
        XCTAssertEqual(sounds(on: "iPad"), ["Other.json": "mine"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("iPad/state.json").path))
    }

    func testATamperedObjectEndsTheSyncBeforeAnyLocalChange() async throws {
        try write("first", "A.json", on: "Mac")
        try write("second", "B.json", on: "Mac")
        _ = try await device("Mac").sync()
        try write("mine", "Lead.json", on: "iPad")

        let objects = allFiles(in: storeFolder).keys.filter { $0.hasPrefix("objects/") }.sorted()
        let victim = storeFolder.appendingPathComponent(objects[0])
        var bytes = try Data(contentsOf: victim)
        bytes[bytes.count - 5] ^= 0x40
        try bytes.write(to: victim)
        let storedBefore = allFiles(in: storeFolder)

        do {
            _ = try await device("iPad").sync()
            XCTFail("a tampered object synced")
        } catch let StoreError.damagedObject(path) {
            XCTAssertTrue(["A.json", "B.json"].contains(path))
        }
        XCTAssertEqual(sounds(on: "iPad"), ["Lead.json": "mine"], "not even the intact sound was written")
        XCTAssertEqual(allFiles(in: storeFolder), storedBefore, "and nothing was uploaded")
    }

    func testAnObjectSwappedForAnotherIsNoticed() async throws {
        try write("first", "A.json", on: "Mac")
        try write("second", "B.json", on: "Mac")
        _ = try await device("Mac").sync()
        // Both are authentic files for this key, but each sits under the other's name.
        let objects = allFiles(in: storeFolder).filter { $0.key.hasPrefix("objects/") }.sorted { $0.key < $1.key }
        try objects[1].value.write(to: storeFolder.appendingPathComponent(objects[0].key))
        do {
            _ = try await device("iPad").sync()
            XCTFail("a swapped object synced")
        } catch let StoreError.damagedObject(path) { XCTAssertFalse(path.isEmpty) }
        XCTAssertTrue(sounds(on: "iPad").isEmpty)
    }

    func testAMissingObjectEndsTheSync() async throws {
        try write("first", "A.json", on: "Mac")
        _ = try await device("Mac").sync()
        let object = try XCTUnwrap(allFiles(in: storeFolder).keys.first { $0.hasPrefix("objects/") })
        try FileManager.default.removeItem(at: storeFolder.appendingPathComponent(object))
        do {
            _ = try await device("iPad").sync()
            XCTFail("a missing object synced")
        } catch { XCTAssertEqual(error as? StoreError, .missingObject("A.json")) }
    }

    /// Writes an index of the test's own making, as someone with the key but bad intentions could.
    private func plant(manifest json: String, in location: MemoryLocation) throws {
        location.files[StoreName.manifest] = try Age.encrypt(Data(json.utf8), to: identity.recipient)
    }

    func testAnIndexThatPointsOutsideTheFolderIsRefused() async throws {
        let object = "objects/" + String(repeating: "a", count: 64) + ".age"
        for path in ["../escaped.json", "/tmp/escaped.json", "a/../../escaped.json", ".hidden.json", "a//b.json"] {
            let location = MemoryLocation()
            location.files[object] = try Age.encrypt(Data("x".utf8), to: identity.recipient)
            let escaped = path.replacingOccurrences(of: "/", with: "\\/")
            try plant(manifest: "{\"version\":1,\"id\":\"s\",\"entries\":{\"\(escaped)\":{\"object\":\"\(object)\",\"modified\":\"2026-01-01T00:00:00Z\",\"size\":1}}}", in: location)
            do {
                _ = try await device("iPad", location: location).sync()
                XCTFail("\(path) was accepted")
            } catch { XCTAssertEqual(error as? StoreError, .unsafePath, path) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("iPad/escaped.json").path))
        XCTAssertTrue(sounds(on: "iPad").isEmpty)
    }

    func testAnIndexWithForeignObjectNamesIsRefused() async throws {
        let location = MemoryLocation()
        try plant(manifest: "{\"version\":1,\"id\":\"s\",\"entries\":{\"a.json\":{\"object\":\"..\\/..\\/x\",\"modified\":\"2026-01-01T00:00:00Z\",\"size\":1}}}", in: location)
        do {
            _ = try await device("iPad", location: location).sync()
            XCTFail("a foreign object name was accepted")
        } catch { XCTAssertEqual(error as? StoreError, .damagedManifest) }
    }

    func testANewerFormatIsRefusedAndLeftAlone() async throws {
        let location = MemoryLocation()
        try plant(manifest: "{\"version\":2,\"entries\":{\"a.json\":{\"something\":\"new\"}}}", in: location)
        let before = location.files
        try write("mine", "Lead.json", on: "iPad")
        do {
            _ = try await device("iPad", location: location).sync()
            XCTFail("a newer format synced")
        } catch { XCTAssertEqual(error as? StoreError, .newerManifest(2)) }
        XCTAssertEqual(location.files, before)
        XCTAssertTrue(location.writes.isEmpty)

        try plant(manifest: "not json", in: location)
        do {
            _ = try await device("iPad", location: location).sync()
            XCTFail("a broken index synced")
        } catch { XCTAssertEqual(error as? StoreError, .damagedManifest) }
    }

    func testObjectsAreWrittenBeforeTheIndexAndOnlyWhenNeeded() async throws {
        let location = MemoryLocation()
        try write("first", "Lead.json", on: "Mac")
        _ = try await device("Mac", location: location).sync()
        XCTAssertEqual(location.writes.count, 2)
        XCTAssertTrue(location.writes[0].allSatisfy { $0.hasPrefix("objects/") })
        XCTAssertEqual(location.writes[1], [StoreName.manifest])
        _ = try await device("Mac", location: location).sync()
        XCTAssertEqual(location.writes.count, 2, "a sync without changes writes nothing")
        _ = try await device("iPad", location: location).sync()
        XCTAssertEqual(location.writes.count, 2, "fetching writes nothing to the store")
    }

    func testAnotherStoreDoesNotInheritTheMemoryOfTheFirst() async throws {
        // The Mac syncs with one store, then is pointed at another that holds a different "Lead". Its memory of the
        // first store must not make this look like "only the store changed", which would drop the Mac's version.
        try write("the Mac's version", "Lead.json", on: "Mac", modified: Date(timeIntervalSinceNow: -60))
        _ = try await device("Mac").sync()

        let second = MemoryLocation()
        try write("another device's version", "Lead.json", on: "Other", modified: Date(timeIntervalSinceNow: -3600))
        try write("only there", "Extra.json", on: "Other")
        _ = try await device("Other", location: second).sync()

        let report = try await device("Mac", location: second).sync()
        XCTAssertEqual(report.uploaded, ["Lead.json"], "a first run with this store: the newer wins")
        XCTAssertEqual(report.downloaded, ["Extra.json"])
        XCTAssertEqual(sounds(on: "Mac"), ["Lead.json": "the Mac's version", "Extra.json": "only there"])
    }

    func testAnEmptiedStoreIsFilledAgainAndNothingIsRemovedHere() async throws {
        try write("first", "Lead.json", on: "Mac")
        _ = try await device("Mac").sync()
        try FileManager.default.removeItem(at: storeFolder)
        let report = try await device("Mac").sync()
        XCTAssertEqual(report.uploaded, ["Lead.json"])
        XCTAssertEqual(sounds(on: "Mac"), ["Lead.json": "first"])
    }

    func testLinksHiddenAndLargeFilesAreLeftAlone() async throws {
        try write("first", "Lead.json", on: "Mac")
        try write("hidden", ".state.json", on: "Mac")
        try write("hidden too", ".cache/x.json", on: "Mac")
        let outside = root.appendingPathComponent("outside.txt")
        try Data("not a sound".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder("Mac").appendingPathComponent("link.json"), withDestinationURL: outside)
        let large = folder("Mac").appendingPathComponent("Take.wav")
        try madeUpBytes(SoundStore.sizeLimit + 1).write(to: large)

        let report = try await device("Mac").sync()
        XCTAssertEqual(report.uploaded, ["Lead.json"])
        _ = try await device("iPad").sync()
        XCTAssertEqual(sounds(on: "iPad"), ["Lead.json": "first"])

        // A file that grows past the limit after it was stored is neither removed in the store nor here.
        try write("small", "Grows.json", on: "Mac")
        _ = try await device("Mac").sync()
        try madeUpBytes(SoundStore.sizeLimit + 1).write(to: folder("Mac").appendingPathComponent("Grows.json"))
        let later = try await device("Mac").sync()
        XCTAssertTrue(later.isEmpty)
        let status = try await device("Mac").status()
        XCTAssertEqual(status.entries, 2)
        XCTAssertEqual(status.deleted, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: large.path))
    }

    func testAFetchedSoundCarriesTheStoresDate() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try write("first", "Lead.json", on: "Mac", modified: date)
        _ = try await device("Mac").sync()
        _ = try await device("iPad").sync()
        let fetched = try folder("iPad").appendingPathComponent("Lead.json").resourceValues(forKeys: [.contentModificationDateKey])
        XCTAssertEqual(fetched.contentModificationDate, date)
    }

    func testAMissingFolderIsAnEmptyOne() async throws {
        let report = try await device("Nowhere").sync()
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.summary, "The store is up to date: 0 sounds.")
    }

    // MARK: Reading the store back

    func testAStoreThatWasJustSyncedReadsBackWhole() async throws {
        try write("{\"name\":\"Made-up Lead\"}", "Lead.json", on: "Mac")
        try write("{\"name\":\"Made-up Jazz\"}", "Kemper/Jazz.json", on: "Mac")
        _ = try await device("Mac").sync()
        let report = try await device("Mac").verify()
        XCTAssertEqual(report.readable, 2)
        XCTAssertTrue(report.isInStep)
        // A device that has not fetched yet sees a whole store that it does not hold.
        let other = try await device("iPad").verify()
        XCTAssertTrue(other.isRestorable)
        XCTAssertEqual(other.notHere, ["Kemper/Jazz.json", "Lead.json"])
    }

    func testReadingBackFindsWhatASyncWouldNotNotice() async throws {
        try write("{\"name\":\"Made-up Lead\"}", "Lead.json", on: "Mac")
        try write("{\"name\":\"Made-up Jazz\"}", "Jazz.json", on: "Mac")
        try write("{\"name\":\"Made-up Funk\"}", "Funk.json", on: "Mac")
        _ = try await device("Mac").sync()
        // One object rots, one disappears; the Mac's own files are untouched, so a sync would see nothing to do.
        let objects = try FileManager.default.contentsOfDirectory(at: storeFolder.appendingPathComponent("objects"),
                                                                  includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(objects.count, 3)
        var rotten = try Data(contentsOf: objects[0])
        rotten[rotten.count - 1] ^= 0x01
        try rotten.write(to: objects[0])
        try FileManager.default.removeItem(at: objects[1])
        let before = sounds(on: "Mac")

        let report = try await device("Mac").verify()
        XCTAssertFalse(report.isRestorable)
        XCTAssertEqual(report.readable, 1)
        XCTAssertEqual(report.damaged.count, 1)
        XCTAssertEqual(report.missing.count, 1)
        XCTAssertEqual(sounds(on: "Mac"), before, "reading back must change nothing")

        try write("{\"name\":\"Made-up New\"}", "New.json", on: "Mac")
        let later = try await device("Mac").verify()
        XCTAssertEqual(later.notStored, ["New.json"])
    }
}
