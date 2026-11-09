@testable import SparkControl
import XCTest

final class DeviceProfileTests: XCTestCase {
    func testKnownDevicesAndWhatWasChecked() {
        XCTAssertEqual(DeviceProfile.sparkMini.slotCount, 4)
        XCTAssertEqual(DeviceProfile.sparkMini.checkedFirmware, "1.11.2.75")
        XCTAssertEqual(DeviceProfile.sparkNEO.slotCount, 4)
        XCTAssertEqual(DeviceProfile.sparkNEO.checkedFirmware, "1.16.1.60")
        XCTAssertEqual(DeviceProfile.reactor50.slotCount, 8)
        XCTAssertEqual(DeviceProfile.reactor50.bankSize, 4)
        XCTAssertNil(DeviceProfile.reactor50.checkedFirmware, "nothing was ever sent, so the firmware is unknown")
        XCTAssertEqual(DeviceProfile.reactor100.slotCount, 8)
    }

    func testTheNEOLosesTheTemporarySoundAndTheMINIIsTreatedTheSameUntilChecked() {
        XCTAssertEqual(DeviceProfile.sparkNEO.keepsTemporaryAfterDisconnect, false)
        XCTAssertTrue(DeviceProfile.sparkNEO.losesTemporaryOnDisconnect)
        XCTAssertNil(DeviceProfile.sparkMini.keepsTemporaryAfterDisconnect)
        XCTAssertTrue(DeviceProfile.sparkMini.losesTemporaryOnDisconnect)
    }

    func testNoSparkConfirmsParameters() {
        for profile in DeviceProfile.all { XCTAssertFalse(profile.confirmsParameters, profile.displayName) }
    }

    func testTheREACTORMayOnlyBeListenedTo() {
        for profile in [DeviceProfile.reactor50, .reactor100] {
            XCTAssertTrue(profile.can(.listen))
            XCTAssertFalse(profile.canSend)
            for capability: DeviceProfile.Capabilities in [.read, .switchSlot, .playTemporary, .liveEdit, .store,
                                                           .modelChange] {
                XCTAssertFalse(profile.can(capability), "\(profile.displayName) \(capability)")
            }
            XCTAssertTrue(profile.can(.usbAudio))
            XCTAssertTrue(profile.can(.textToTone))
        }
    }

    func testAnUnknownSparkOnlyReadsAndSwitches() {
        let profile = DeviceProfile.unknownSpark
        XCTAssertTrue(profile.can(.read) && profile.can(.switchSlot) && profile.canSend)
        for capability: DeviceProfile.Capabilities in [.playTemporary, .liveEdit, .store, .modelChange] {
            XCTAssertFalse(profile.can(capability))
        }
    }

    func testOnlyTheNEOHasCheckedTextLimits() {
        XCTAssertEqual(DeviceProfile.sparkNEO.checkedText?.nameBytes, 12)
        XCTAssertEqual(DeviceProfile.sparkNEO.checkedText?.descriptionBytes, 0)
        XCTAssertNil(DeviceProfile.sparkMini.checkedText)
        var preset = PresetFactory.empty(name: "Größere Bühne")
        preset.description = "Ein Sound"
        let fitted = AmpGuard.prepared(preset, for: .sparkNEO)
        XCTAssertLessThanOrEqual(fitted.name.utf8.count, 12)
        XCTAssertEqual(fitted.name, "Größere B", "13 bytes with ü, so cut before it, never inside it")
        XCTAssertEqual(fitted.description, "")
        XCTAssertEqual(AmpGuard.prepared(preset, for: .sparkMini), AmpGuard.prepared(preset))
    }

    func testTheNEOIsNoRecordingInput() {
        XCTAssertFalse(DeviceProfile.sparkNEO.can(.usbAudio))
        XCTAssertTrue(DeviceProfile.sparkNEO.usbAudioNames.isEmpty)
    }

    /// Only names read on a device: the MINI's "Spark". The REACTOR's joins once it is read on the device.
    func testRecordableUSBNamesComeFromTheProfiles() {
        XCTAssertEqual(DeviceProfile.recordableUSBNames, ["spark"])
        XCTAssertTrue(DeviceProfile.reactor50.usbAudioNames.isEmpty)
    }

    func testRecognitionFromWhatIsAdvertised() {
        XCTAssertEqual(DeviceProfile.forAdvertisement(service: "FFC0", name: "Spark NEO Control").id, .sparkNEO)
        XCTAssertEqual(DeviceProfile.forAdvertisement(service: "FFC0", name: "Spark MINI BLE").id, .sparkMini)
        XCTAssertEqual(DeviceProfile.forAdvertisement(service: "FFC0", name: "Spark 40 Audio").id, .unknownSpark)
        XCTAssertEqual(DeviceProfile.forAdvertisement(service: "FFC0", name: nil).id, .unknownSpark)
        XCTAssertEqual(DeviceProfile.forAdvertisement(service: "FFD0", name: "Reactor 50 Probenraum").id, .reactor50)
        XCTAssertEqual(DeviceProfile.forAdvertisement(service: "ffd0", name: "Reactor 100 X").id, .reactor100)
        // The service decides: a REACTOR is a REACTOR whatever its name says.
        XCTAssertEqual(DeviceProfile.forAdvertisement(service: "FFD0", name: "Spark MINI").id, .reactor50)
    }

    func testRecognitionFromTheAmpName() {
        XCTAssertEqual(DeviceProfile.forAmpName("Spark NEO")?.id, .sparkNEO)
        XCTAssertEqual(DeviceProfile.forAmpName("Spark MINI")?.id, .sparkMini)
        XCTAssertNil(DeviceProfile.forAmpName("Spark 40"))
    }

    func testTheOwnersPartOfAREACTORNameStaysOutOfLogs() {
        XCTAssertEqual(DeviceProfile.loggableName("Reactor 50 Probenraum"), "Reactor 50")
        XCTAssertEqual(DeviceProfile.loggableName("Reactor 100 Bühne links"), "Reactor 100")
        XCTAssertEqual(DeviceProfile.loggableName("Spark NEO Control"), "Spark NEO Control")
        XCTAssertEqual(DeviceProfile.loggableName(nil), "?")
    }

    func testSlotNamesWithAndWithoutBanks() {
        XCTAssertEqual(DeviceProfile.sparkNEO.slotName(2), "Platz 3")
        XCTAssertEqual(DeviceProfile.reactor50.slotName(0), "Rot 1")
        XCTAssertEqual(DeviceProfile.reactor50.slotName(3), "Rot 4")
        XCTAssertEqual(DeviceProfile.reactor50.slotName(4), "Grün 1")
        XCTAssertEqual(DeviceProfile.reactor50.slotName(7), "Grün 4")
        XCTAssertEqual(DeviceProfile.reactor50.bank(of: 5), 1)
        XCTAssertNil(DeviceProfile.sparkMini.bank(of: 1))
        XCTAssertEqual(DeviceProfile.largestSlotCount, 8)
    }

    func testTheSearchLooksForSparkAndREACTORServicesOnly() {
        XCTAssertEqual(DeviceProfile.searchedServices, ["FFC0", "FFD0"])
        XCTAssertEqual(SparkProtocol.serviceUUID, DeviceProfile.sparkService)
    }
}
