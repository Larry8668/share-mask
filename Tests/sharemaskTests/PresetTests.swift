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
}
