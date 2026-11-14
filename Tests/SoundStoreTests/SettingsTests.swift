import XCTest
@testable import SoundStore

final class StoreSettingsTests: XCTestCase {
    func testSettingsSurviveCodingAndHoldNoSecret() throws {
        let settings = StoreSettings(kind: .http, url: "https://store.example/dav", user: "player")
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(StoreSettings.self, from: data), settings)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["kind", "url", "user"])
    }

    func testTheSummaryNamesThePlaceWithoutUserOrPath() {
        XCTAssertEqual(StoreSettings(kind: .folder, folderPath: "/srv/shared/AmpBench Store").summary, "Folder “AmpBench Store”")
        XCTAssertEqual(StoreSettings(kind: .folder).summary, "Folder")
        XCTAssertEqual(StoreSettings(kind: .ssh, host: "myserver", path: "~/secret/place").summary, "Server myserver (SSH)")
        XCTAssertEqual(StoreSettings(kind: .http, url: "https://store.example/dav/x", user: "player").summary, "Server store.example (HTTPS)")
        XCTAssertEqual(StoreSettings(kind: .http).summary, "Server (HTTPS)")
    }

    func testSettingsMakeTheirLocation() throws {
        XCTAssertTrue(try StoreSettings(kind: .folder, folderPath: "/tmp/x").location() is FolderLocation)
        let picked = URL(fileURLWithPath: "/tmp/picked")
        XCTAssertEqual((try StoreSettings(kind: .folder, folderPath: "/tmp/x").location(folder: picked) as? FolderLocation)?.folder, picked)
        XCTAssertTrue(try StoreSettings(kind: .http, url: " https://store.example/dav ").location() is HTTPLocation)
        #if os(macOS)
        XCTAssertTrue(try StoreSettings(kind: .ssh, host: "server", path: "store").location() is SSHLocation)
        XCTAssertThrowsError(try StoreSettings(kind: .ssh, host: "server; x", path: "store").location()) {
            XCTAssertEqual($0 as? StoreError, .invalidHost)
        }
        #endif
        for incomplete in [StoreSettings(kind: .folder), StoreSettings(kind: .ssh, host: "server"), StoreSettings(kind: .http, url: "")] {
            XCTAssertThrowsError(try incomplete.location()) { XCTAssertEqual($0 as? StoreError, .incompleteSettings) }
        }
        XCTAssertThrowsError(try StoreSettings(kind: .http, url: "http://store.example/dav").location()) {
            XCTAssertEqual($0 as? StoreError, .insecureURL)
        }
        XCTAssertThrowsError(try StoreSettings(kind: .http, url: "not an address").location()) {
            XCTAssertEqual($0 as? StoreError, .invalidURL)
        }
    }

    func testEveryErrorHasAText() {
        let errors: [StoreError] = [.invalidName, .wrongKey, .damagedManifest, .newerManifest(2), .unsafePath, .missingObject("a"),
                                    .damagedObject("a"), .invalidHost, .invalidPath, .ssh("x"), .sshOnlyOnMac, .insecureURL,
                                    .invalidURL, .notAllowed(401), .storeFull, .http(500), .incompleteSettings]
        for error in errors { XCTAssertFalse((error.errorDescription ?? "").isEmpty) }
        XCTAssertTrue(StoreError.wrongKey.errorDescription!.hasPrefix("This key does not open the store"))
    }
}

final class StoreKeychainTests: XCTestCase {
    func testKeyAndPasswordAreStoredReadAndRemoved() throws {
        // A service of its own, so the real key of a store on this machine is never touched.
        let service = "local.ampbench.store.tests.\(UUID().uuidString)"
        addTeardownBlock {
            try? StoreKeychain.setIdentity(nil, service: service)
            try? StoreKeychain.setPassword(nil, service: service)
        }
        XCTAssertNil(StoreKeychain.identity(service: service))
        let identity = AgeIdentity.generate()
        do {
            try StoreKeychain.setIdentity(identity.text, service: service)
        } catch {
            throw XCTSkip("no keychain here: \(error.localizedDescription)")
        }
        XCTAssertTrue(StoreKeychain.identity(service: service) == identity.text, "the key did not come back")
        XCTAssertNil(StoreKeychain.password(service: service), "key and password are separate items")
        try StoreKeychain.setPassword("made-up word", service: service)
        try StoreKeychain.setPassword("another made-up word", service: service)
        XCTAssertEqual(StoreKeychain.password(service: service), "another made-up word")
        try StoreKeychain.setIdentity(nil, service: service)
        try StoreKeychain.setPassword(nil, service: service)
        try StoreKeychain.setPassword(nil, service: service)
        XCTAssertNil(StoreKeychain.identity(service: service))
        XCTAssertNil(StoreKeychain.password(service: service))
    }
}
