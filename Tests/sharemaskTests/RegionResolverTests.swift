import XCTest
@testable import sharemask

final class RegionResolverTests: XCTestCase {
    // Retina 1470x956 pt display at origin, 2940x1912 px.
    let retina = DisplayGeometry(boundsPoints: CGRect(x: 0, y: 0, width: 1470, height: 956), scale: 2,
                                 pixelSize: CGSize(width: 2940, height: 1912))
    let nonRetina = DisplayGeometry(boundsPoints: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1,
                                    pixelSize: CGSize(width: 1920, height: 1080))

    func window(_ id: UInt32, _ bundle: String?, _ rect: CGRect, layer: Int = 0, alpha: CGFloat = 1, sharing: Int = 1, pid: pid_t = 100) -> TrackedWindow {
        TrackedWindow(windowID: id, pid: pid, bundleID: bundle, boundsPoints: rect, layer: layer, alpha: alpha, sharingState: sharing)
    }

    func presets(_ apps: [String: AppPreset]) -> PresetConfig {
        var c = PresetConfig.empty; c.apps = apps; return c
    }

    let whatsapp = "net.whatsapp.WhatsApp"
    var chatList: AppPreset {
        AppPreset(regions: [PresetRegion(name: "chat list", rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), mode: .pixellate(scale: 24))],
                  whenFrontmostOnly: false)
    }

    func testSingleWindowRetinaFlipsAndScales() {
        // Window at (100, 200) pt, 400x300 pt. Left half → x 100..300 pt, y 200..500 pt (top-left).
        let w = window(1, whatsapp, CGRect(x: 100, y: 200, width: 400, height: 300))
        let out = RegionResolver.resolve(presets: presets([whatsapp: chatList]), windows: [w], display: retina, frontmostBundleID: nil)
        XCTAssertEqual(out.count, 1)
        // Pixels: x 200..600, top y 400..1000 → CI bottom-left y = 1912 - 1000 = 912, height 600.
        XCTAssertEqual(out[0].rect, CGRect(x: 200, y: 912, width: 400, height: 600))
        XCTAssertEqual(out[0].mode, .pixellate(scale: 24))
    }

    func testNonRetinaScaleOne() {
        let w = window(1, whatsapp, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let out = RegionResolver.resolve(presets: presets([whatsapp: chatList]), windows: [w], display: nonRetina, frontmostBundleID: nil)
        XCTAssertEqual(out, [PixelRegion(rect: CGRect(x: 0, y: 0, width: 960, height: 1080), mode: .pixellate(scale: 24))])
    }

    func testOccluderInFrontIsSubtracted() {
        let target = window(1, whatsapp, CGRect(x: 0, y: 0, width: 1000, height: 1000))
        // Terminal covering the middle of the chat list (which is x 0..500).
        let terminal = window(2, "com.apple.Terminal", CGRect(x: 200, y: 200, width: 600, height: 200))
        let out = RegionResolver.resolve(presets: presets([whatsapp: chatList]), windows: [terminal, target], display: nonRetina, frontmostBundleID: nil)
        // Remaining: top band y 0..200 (x 0..500), bottom band y 400..1000, left sliver x 0..200 y 200..400.
        let rects = Set(out.map { NSStringFromRect($0.rect) })
        let expected = Set([
            CGRect(x: 0, y: 1080 - 200, width: 500, height: 200),
            CGRect(x: 0, y: 1080 - 1000, width: 500, height: 600),
            CGRect(x: 0, y: 1080 - 400, width: 200, height: 200),
        ].map { NSStringFromRect($0) })
        XCTAssertEqual(rects, expected)
        // The terminal itself must not be covered.
        for r in out { XCTAssertFalse(r.rect.intersects(CGRect(x: 200, y: 1080 - 400, width: 600, height: 200).insetBy(dx: 1, dy: 1))) }
    }

    func testWindowBehindDoesNotOcclude() {
        let target = window(1, whatsapp, CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let behind = window(2, "com.apple.Terminal", CGRect(x: 200, y: 200, width: 600, height: 200))
        let out = RegionResolver.resolve(presets: presets([whatsapp: chatList]), windows: [target, behind], display: nonRetina, frontmostBundleID: nil)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].rect, CGRect(x: 0, y: 80, width: 500, height: 1000))
    }

    func testNonCapturedOccluderDoesNotPunchHole() {
        let target = window(1, whatsapp, CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let hidden = window(2, "com.1password", CGRect(x: 0, y: 0, width: 400, height: 400), sharing: 0)
        let out = RegionResolver.resolve(presets: presets([whatsapp: chatList]), windows: [hidden, target], display: nonRetina, frontmostBundleID: nil)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].rect, CGRect(x: 0, y: 80, width: 500, height: 1000))
    }

    func testOwnPIDIgnoredAsOccluder() {
        let target = window(1, whatsapp, CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let hud = window(2, "dev.sharemask.app", CGRect(x: 0, y: 0, width: 400, height: 400), pid: 999)
        let out = RegionResolver.resolve(presets: presets([whatsapp: chatList]), windows: [hud, target], display: nonRetina, frontmostBundleID: nil, ignorePIDs: [999])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].rect.height, 1000)
    }

    func testPartiallyOffScreenIsClipped() {
        let w = window(1, whatsapp, CGRect(x: -200, y: -100, width: 1000, height: 500))
        let out = RegionResolver.resolve(presets: presets([whatsapp: chatList]), windows: [w], display: nonRetina, frontmostBundleID: nil)
        XCTAssertEqual(out.count, 1)
        // Left half spans x -200..300 → clipped to 0..300; y -100..400 → clipped 0..400.
        XCTAssertEqual(out[0].rect, CGRect(x: 0, y: 1080 - 400, width: 300, height: 400))
    }

    func testWindowOnAnotherDisplayIsSkipped() {
        let w = window(1, whatsapp, CGRect(x: 3000, y: 0, width: 400, height: 300))
        let out = RegionResolver.resolve(presets: presets([whatsapp: chatList]), windows: [w], display: nonRetina, frontmostBundleID: nil)
        XCTAssertTrue(out.isEmpty)
    }

    func testMultiDisplayOffset() {
        // Secondary display to the left of the primary, Retina.
        let display = DisplayGeometry(boundsPoints: CGRect(x: -1440, y: -200, width: 1440, height: 900), scale: 2,
                                      pixelSize: CGSize(width: 2880, height: 1800))
        let w = window(1, whatsapp, CGRect(x: -1440, y: -200, width: 400, height: 300))
        let out = RegionResolver.resolve(presets: presets([whatsapp: chatList]), windows: [w], display: display, frontmostBundleID: nil)
        XCTAssertEqual(out, [PixelRegion(rect: CGRect(x: 0, y: 1800 - 600, width: 400, height: 600), mode: .pixellate(scale: 24))])
    }

    func testNonNormalLayerAndInvisibleWindowsSkipped() {
        let popup = window(1, whatsapp, CGRect(x: 0, y: 0, width: 400, height: 300), layer: 25)
        let ghost = window(2, whatsapp, CGRect(x: 0, y: 0, width: 400, height: 300), alpha: 0)
        let out = RegionResolver.resolve(presets: presets([whatsapp: chatList]), windows: [popup, ghost], display: nonRetina, frontmostBundleID: nil)
        XCTAssertTrue(out.isEmpty)
    }

    func testWhenFrontmostOnly() {
        var app = chatList; app.whenFrontmostOnly = true
        let w = window(1, whatsapp, CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertTrue(RegionResolver.resolve(presets: presets([whatsapp: app]), windows: [w], display: nonRetina, frontmostBundleID: "com.apple.Terminal").isEmpty)
        XCTAssertEqual(RegionResolver.resolve(presets: presets([whatsapp: app]), windows: [w], display: nonRetina, frontmostBundleID: whatsapp).count, 1)
    }

    func testSubPixelEdgesSnapOutwards() {
        let w = window(1, whatsapp, CGRect(x: 10.3, y: 20.7, width: 100.2, height: 50.1))
        let out = RegionResolver.resolve(presets: presets([whatsapp: chatList]), windows: [w], display: retina, frontmostBundleID: nil)
        let r = out[0].rect
        XCTAssertEqual(r.minX, 20)               // floor(10.3*2)
        XCTAssertEqual(r.maxX, 121)              // ceil((10.3+50.1)*2) = ceil(120.8)
        XCTAssertEqual(r.maxY, 1912 - 41)        // floor(20.7*2)=41 from top
        XCTAssertEqual(r.minY, 1912 - 142)       // ceil((20.7+50.1)*2)=ceil(141.6)=142
    }

    func testOverflowCollapsesToSafeRect() {
        // One target, 70 tiny occluders → far more than 64 pieces; must fall back to the full rect.
        let target = window(1, whatsapp, CGRect(x: 0, y: 0, width: 1000, height: 1000))
        var windows: [TrackedWindow] = []
        for i in 0..<70 { windows.append(window(UInt32(i + 10), "x", CGRect(x: 10 + i * 6, y: 10 + i * 12, width: 3, height: 3))) }
        windows.append(target)
        let out = RegionResolver.resolve(presets: presets([whatsapp: chatList]), windows: windows, display: nonRetina, frontmostBundleID: nil)
        XCTAssertLessThanOrEqual(out.count, 64)
        let union = out.dropFirst().reduce(out[0].rect) { $0.union($1.rect) }
        XCTAssertTrue(union.contains(CGRect(x: 0, y: 80, width: 500, height: 1000)))
    }

    func testSubtractProducesAtMostFourRects() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let hole = CGRect(x: 25, y: 25, width: 50, height: 50)
        let pieces = RegionResolver.subtract(hole, from: a)
        XCTAssertEqual(pieces.count, 4)
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.width * $1.height }, 100 * 100 - 50 * 50)
        XCTAssertEqual(RegionResolver.subtract(CGRect(x: 500, y: 500, width: 10, height: 10), from: a), [a])
        XCTAssertTrue(RegionResolver.subtract(a.insetBy(dx: -1, dy: -1), from: a).isEmpty)
    }
}

final class EllipseTests: XCTestCase {
    let display = DisplayGeometry(boundsPoints: CGRect(x: 0, y: 0, width: 1000, height: 1000), scale: 1, pixelSize: CGSize(width: 1000, height: 1000))
    let app = "a.b"
    func cfg() -> PresetConfig {
        var c = PresetConfig.empty
        c.apps[app] = AppPreset(regions: [PresetRegion(name: "c", rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), mode: .defaultPixellate, shape: .ellipse)], whenFrontmostOnly: false)
        return c
    }
    func w(_ id: UInt32, _ b: String?, _ r: CGRect) -> TrackedWindow {
        TrackedWindow(windowID: id, pid: 1, bundleID: b, boundsPoints: r, layer: 0, alpha: 1, sharingState: 1)
    }
    func testUnoccludedEllipseStaysEllipse() {
        let out = RegionResolver.resolve(presets: cfg(), windows: [w(1, app, CGRect(x: 0, y: 0, width: 400, height: 400))], display: display, frontmostBundleID: nil)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].shape, .ellipse)
        XCTAssertEqual(out[0].rect, CGRect(x: 100, y: 1000 - 300, width: 200, height: 200))
    }
    func testOccludedEllipseFallsBackToRects() {
        let occ = w(2, "x", CGRect(x: 150, y: 150, width: 50, height: 50))
        let out = RegionResolver.resolve(presets: cfg(), windows: [occ, w(1, app, CGRect(x: 0, y: 0, width: 400, height: 400))], display: display, frontmostBundleID: nil)
        XCTAssertTrue(out.allSatisfy { $0.shape == .rect })
        XCTAssertGreaterThan(out.count, 1)
    }
    func testClippedEllipseFallsBackToRect() {
        let out = RegionResolver.resolve(presets: cfg(), windows: [w(1, app, CGRect(x: 800, y: 0, width: 400, height: 400))], display: display, frontmostBundleID: nil)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].shape, .rect)
    }
    func testShapeParsesFromJSON() throws {
        let c = try PresetConfig.parse(data: #"{"apps":{"a":{"regions":[{"rect":[0,0,0.5,0.5],"shape":"ellipse"},{"rect":[0,0,1,1]}]}}}"#.data(using: .utf8)!)
        XCTAssertEqual(c.apps["a"]!.regions[0].shape, .ellipse)
        XCTAssertEqual(c.apps["a"]!.regions[1].shape, .rect)
    }
}

final class ResolverOptionsTests: XCTestCase {
    let display = DisplayGeometry(boundsPoints: CGRect(x: 0, y: 0, width: 1000, height: 1000), scale: 1, pixelSize: CGSize(width: 1000, height: 1000))
    func w(_ id: UInt32, _ b: String?, _ r: CGRect, title: String? = nil, layer: Int = 0) -> TrackedWindow {
        TrackedWindow(windowID: id, pid: 1, bundleID: b, boundsPoints: r, layer: layer, alpha: 1, sharingState: 1, title: title)
    }
    var base: PresetConfig {
        var c = PresetConfig.empty
        c.apps["chat"] = AppPreset(regions: [PresetRegion(name: "list", rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), mode: .defaultPixellate)], whenFrontmostOnly: false)
        c.rules = [MaskRule(name: "wa-web", bundleID: nil, titleContains: "whatsapp",
                            regions: [PresetRegion(name: "all", rect: CGRect(x: 0, y: 0, width: 1, height: 1), mode: .defaultPixellate)], whenFrontmostOnly: false)]
        c.allowlist = ["slides"]
        return c
    }
    func testTitleRuleMatchesAnyBundle() {
        let out = RegionResolver.resolve(presets: base, windows: [w(1, "browser", CGRect(x: 0, y: 0, width: 200, height: 200), title: "WhatsApp Web — Arc")], display: display, frontmostBundleID: nil)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].rect, CGRect(x: 0, y: 800, width: 200, height: 200))
        XCTAssertTrue(RegionResolver.resolve(presets: base, windows: [w(1, "browser", CGRect(x: 0, y: 0, width: 200, height: 200), title: "Gmail")], display: display, frontmostBundleID: nil).isEmpty)
    }
    func testRevealedAndDisabledSkipMasks() {
        let win = [w(1, "chat", CGRect(x: 0, y: 0, width: 200, height: 200))]
        XCTAssertEqual(RegionResolver.resolve(presets: base, windows: win, display: display, frontmostBundleID: nil).count, 1)
        XCTAssertTrue(RegionResolver.resolve(presets: base, windows: win, display: display, frontmostBundleID: nil, options: ResolveOptions(revealed: ["chat"])).isEmpty)
        XCTAssertTrue(RegionResolver.resolve(presets: base, windows: win, display: display, frontmostBundleID: nil, options: ResolveOptions(disabled: ["chat/list"])).isEmpty)
        XCTAssertTrue(RegionResolver.resolve(presets: base, windows: win, display: display, frontmostBundleID: nil, options: ResolveOptions(disabled: ["chat"])).isEmpty)
    }
    func testAllowlistMasksEverythingButAllowedWindows() {
        // Allowed "slides" window in the middle, a non-allowed window in front covering its left part.
        let slides = w(1, "slides", CGRect(x: 200, y: 200, width: 400, height: 400))
        let front = w(2, "other", CGRect(x: 100, y: 100, width: 200, height: 600))
        let out = RegionResolver.resolve(presets: base, windows: [front, slides], display: display, frontmostBundleID: nil, options: ResolveOptions(allowlistMode: true))
        XCTAssertFalse(out.isEmpty)
        func masked(_ x: CGFloat, _ yTop: CGFloat) -> Bool { out.contains { $0.rect.contains(CGPoint(x: x, y: 1000 - yTop)) } }
        XCTAssertTrue(masked(50, 50))        // desktop
        XCTAssertTrue(masked(150, 300))      // the non-allowed front window
        XCTAssertTrue(masked(250, 300))      // slides part hidden under the front window
        XCTAssertFalse(masked(450, 400))     // visible slides content stays sharp
        XCTAssertTrue(masked(700, 700))
    }
    func testNotificationBannerMaskedAtAnyLayer() {
        let banner = w(9, RegionResolver.notificationCenterBundleID, CGRect(x: 600, y: 40, width: 380, height: 90), layer: 25)
        let out = RegionResolver.resolve(presets: base, windows: [banner], display: display, frontmostBundleID: nil)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].mode, .solid(color: .black))
        var off = base; off.maskNotifications = false
        XCTAssertTrue(RegionResolver.resolve(presets: off, windows: [banner], display: display, frontmostBundleID: nil).isEmpty)
    }
    func testRulesParseFromJSON() throws {
        let json = #"{"rules":[{"name":"wa","titleContains":"WhatsApp","regions":[{"rect":[0,0,1,1]}]}],"allowlist":["a.b"],"maskNotifications":false,"hotkeys":{"reveal":"cmd+shift+ctrl+R"}}"#
        let c = try PresetConfig.parse(data: json.data(using: .utf8)!)
        XCTAssertEqual(c.rules.count, 1)
        XCTAssertEqual(c.rules[0].titleContains, "WhatsApp")
        XCTAssertEqual(c.allowlist, ["a.b"])
        XCTAssertFalse(c.maskNotifications)
        XCTAssertEqual(c.hotkeys.reveal, "cmd+shift+ctrl+R")
        XCTAssertEqual(c.hotkeys.endShare, "cmd+shift+ctrl+X")
    }
}

final class DisplayLayoutTests: XCTestCase {
    let builtin = CGRect(x: 0, y: 0, width: 1470, height: 956)

    func testBugLayoutIsDetected() {
        // 2026-10-26: proxy slotted in at x=1470, external monitor pushed to x=4410.
        let proxy = CGRect(x: 1470, y: 0, width: 2940, height: 1912)
        let external = CGRect(x: 4410, y: -124, width: 1920, height: 1080)
        XCTAssertFalse(DisplayLayout.isWellPlaced(proxy, real: [builtin, external]))
        XCTAssertGreaterThan(DisplayLayout.sharedEdge(proxy, builtin), 0)
        XCTAssertGreaterThan(DisplayLayout.sharedEdge(proxy, external), 0)
    }

    func testCornerPlacementTouchesOnlyAtACorner() {
        let external = CGRect(x: 1470, y: -124, width: 1920, height: 1080)
        let origin = DisplayLayout.cornerOrigin(real: [builtin, external])
        XCTAssertEqual(origin, CGPoint(x: 3390, y: 956))
        let proxy = CGRect(origin: origin, size: CGSize(width: 2940, height: 1912))
        XCTAssertTrue(DisplayLayout.isWellPlaced(proxy, real: [builtin, external]))
    }

    func testSingleDisplayCorner() {
        let proxy = CGRect(origin: DisplayLayout.cornerOrigin(real: [builtin]), size: CGSize(width: 2940, height: 1912))
        XCTAssertEqual(proxy.origin, CGPoint(x: 1470, y: 956))
        XCTAssertTrue(DisplayLayout.isWellPlaced(proxy, real: [builtin]))
        XCTAssertFalse(DisplayLayout.isWellPlaced(CGRect(x: 1470, y: 0, width: 100, height: 100), real: [builtin]))
    }
}
