import XCTest
@testable import sharemask

final class PresetTests: XCTestCase {
    func testParsesExampleSchema() throws {
        let json = """
        {
          "version": 1,
          "defaults": { "mode": "pixellate", "scale": 24 },
          "apps": {
            "net.whatsapp.WhatsApp": { "regions": [
                { "name": "chat list", "rect": [0.0, 0.0, 0.30, 1.0] },
                { "name": "header", "rect": [0.0, 0.0, 1.0, 0.08], "mode": "solid", "color": "#102030" } ] },
            "com.tinyspeck.slackmacgap": { "whenFrontmostOnly": true,
                "regions": [ { "name": "sidebar", "rect": [0.0, 0.0, 0.22, 1.0], "mode": "blur", "radius": 30 } ] }
          },
          "hotkeys": { "panic": "cmd+shift+ctrl+B" },
          "pointerGuard": false
        }
        """
        let cfg = try PresetConfig.parse(data: json.data(using: .utf8)!)
        XCTAssertEqual(cfg.apps.count, 2)
        let wa = cfg.apps["net.whatsapp.WhatsApp"]!
        XCTAssertEqual(wa.regions[0].mode, .pixellate(scale: 24))
        XCTAssertEqual(wa.regions[0].rect, CGRect(x: 0, y: 0, width: 0.3, height: 1))
        XCTAssertEqual(wa.regions[1].mode, .solid(color: RGBA(hex: "#102030")!))
        let slack = cfg.apps["com.tinyspeck.slackmacgap"]!
        XCTAssertTrue(slack.whenFrontmostOnly)
        XCTAssertEqual(slack.regions[0].mode, .blur(radius: 30))
        XCTAssertEqual(cfg.hotkeys.panic, "cmd+shift+ctrl+B")
        XCTAssertEqual(cfg.hotkeys.toggle, "cmd+shift+ctrl+M")   // default kept
        XCTAssertFalse(cfg.pointerGuard)
    }

    func testRejectsBadRectAndMode() {
        XCTAssertThrowsError(try PresetConfig.parse(data: #"{"apps":{"a":{"regions":[{"rect":[0,0,1]}]}}}"#.data(using: .utf8)!))
        XCTAssertThrowsError(try PresetConfig.parse(data: #"{"apps":{"a":{"regions":[{"rect":[0,0,1,1],"mode":"swirl"}]}}}"#.data(using: .utf8)!))
        XCTAssertThrowsError(try PresetConfig.parse(data: "{not json".data(using: .utf8)!))
    }

    func testHotkeyParsing() {
        XCTAssertNotNil(Hotkeys.parse("cmd+shift+ctrl+B"))
        XCTAssertEqual(Hotkeys.parse("cmd+shift+ctrl+B")!.0, 0x0B)
        XCTAssertNil(Hotkeys.parse("cmd+shift"))
        XCTAssertNil(Hotkeys.parse("cmd+bogus"))
        XCTAssertEqual(Hotkeys.pretty("cmd+shift+ctrl+B"), "⌘⇧⌃B")
    }

    func testStableSerialIsDeterministic() {
        XCTAssertEqual(VirtualDisplay.stableSerial(name: "sharemask", w: 2940, h: 1912),
                       VirtualDisplay.stableSerial(name: "sharemask", w: 2940, h: 1912))
        XCTAssertNotEqual(VirtualDisplay.stableSerial(name: "sharemask", w: 2940, h: 1912),
                          VirtualDisplay.stableSerial(name: "sharemask", w: 1470, h: 956))
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2", than: "0.1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.4", than: "0.1.4"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.3", than: "0.1.4"))
    }
}

final class AppLockConfigTests: XCTestCase {
    func testOldSavedConfigStillDecodes() throws {
        // Saved by 0.1.9/0.2.0: no closeRelockSeconds key.
        let old = #"{"enabled":true,"apps":["net.whatsapp.WhatsApp"],"relockMinutes":5,"relockOnSleep":true,"guardQuit":true,"keepAlive":true}"#
        let c = try JSONDecoder().decode(AppLockConfig.self, from: old.data(using: .utf8)!)
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.apps, ["net.whatsapp.WhatsApp"])
        XCTAssertEqual(c.closeDelay, 0)   // default: instantly
    }
    func testPasswordHashRoundTrip() {
        let h = AppLockStore.hash("test1234")
        XCTAssertTrue(AppLockStore.verify("test1234", against: h))
        XCTAssertFalse(AppLockStore.verify("nope", against: h))
    }
}
