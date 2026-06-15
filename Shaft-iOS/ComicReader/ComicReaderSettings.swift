import Foundation
import Observation

// 1:1 port of upstream `ComicReaderSettings` (MMKV namespace "comic_reader_v3").
// Persisted reader preferences for the V3 manga reader, isolated from the novel
// reader. SwiftUI @Observable replaces the Android LiveData ChangeEvent bus —
// views observe the singleton and recompute; `layoutKey` exists so the paged
// container can detect the subset of changes that require a viewport rebuild.
//
// Volume-key page flip is intentionally absent: iOS apps cannot intercept the
// hardware volume buttons (same omission as the novel reader port).
@MainActor
@Observable
final class ComicReaderSettings {
    static let shared = ComicReaderSettings()

    enum ReadingMode: String { case paged, webtoon }
    enum PageDirection: String { case ltr, rtl }
    enum FitMode: String { case fitWidth, fitScreen, fitOriginal }
    enum FlipAnim: String { case slide, cover, depth, flipBook }

    @ObservationIgnored private let d = UserDefaults.standard
    private static let prefix = "cmr_"

    // ---- Layout group (paged container must rebuild on change) -------------
    var readingMode: ReadingMode {
        didSet { setEnum(readingMode.rawValue, oldValue.rawValue, "mode") }
    }
    var pageDirection: PageDirection {
        didSet { setEnum(pageDirection.rawValue, oldValue.rawValue, "direction") }
    }
    var flipAnim: FlipAnim {
        didSet { setEnum(flipAnim.rawValue, oldValue.rawValue, "flip_anim") }
    }
    var showPageNumber: Bool {
        didSet { set(showPageNumber, oldValue, "page_num") }
    }

    // ---- Image group (fit / source / preload) ------------------------------
    var fitMode: FitMode {
        didSet { setEnum(fitMode.rawValue, oldValue.rawValue, "fit") }
    }
    var loadOriginal: Bool {
        didSet { set(loadOriginal, oldValue, "load_original") }
    }
    var preloadAhead: Int {
        didSet {
            let c = preloadAhead.clamped(0, 8)
            if c != preloadAhead { preloadAhead = c; return }   // clamp in-memory too
            d.set(preloadAhead, forKey: Self.prefix + "preload")
        }
    }
    var doubleTapZoomLevel: Double {
        didSet {
            let c = doubleTapZoomLevel.clamped(1.5, 5)
            if c != doubleTapZoomLevel { doubleTapZoomLevel = c; return }
            d.set(doubleTapZoomLevel, forKey: Self.prefix + "dbltap_zoom")
        }
    }

    // ---- Theme / brightness group ------------------------------------------
    var backgroundDark: Bool {
        didSet { set(backgroundDark, oldValue, "bg_dark") }
    }
    var useSystemBrightness: Bool {
        didSet { set(useSystemBrightness, oldValue, "sys_brightness") }
    }
    var customBrightness: Double {
        didSet {
            let c = customBrightness.clamped(0.01, 1)
            if c != customBrightness { customBrightness = c; return }
            d.set(customBrightness, forKey: Self.prefix + "brightness")
        }
    }
    var warmFilterStrength: Double {
        didSet {
            let c = warmFilterStrength.clamped(0, 0.6)
            if c != warmFilterStrength { warmFilterStrength = c; return }
            d.set(warmFilterStrength, forKey: Self.prefix + "warm_filter")
        }
    }

    // ---- Interaction group -------------------------------------------------
    var keepScreenOn: Bool {
        didSet { set(keepScreenOn, oldValue, "keep_screen_on") }
    }
    var immersive: Bool {
        didSet { set(immersive, oldValue, "immersive") }
    }
    var tapZoneReversed: Bool {
        didSet { set(tapZoneReversed, oldValue, "tap_reversed") }
    }

    private init() {
        let defaults = UserDefaults.standard
        func b(_ k: String, _ def: Bool) -> Bool {
            defaults.object(forKey: Self.prefix + k) == nil ? def : defaults.bool(forKey: Self.prefix + k)
        }
        func f(_ k: String, _ def: Double) -> Double {
            defaults.object(forKey: Self.prefix + k) == nil ? def : defaults.double(forKey: Self.prefix + k)
        }
        func i(_ k: String, _ def: Int) -> Int {
            defaults.object(forKey: Self.prefix + k) == nil ? def : defaults.integer(forKey: Self.prefix + k)
        }
        func s<T: RawRepresentable>(_ k: String, _ def: T) -> T where T.RawValue == String {
            (defaults.string(forKey: Self.prefix + k).flatMap { T(rawValue: $0) }) ?? def
        }
        readingMode = s("mode", ReadingMode.paged)
        pageDirection = s("direction", PageDirection.ltr)
        flipAnim = s("flip_anim", FlipAnim.slide)
        showPageNumber = b("page_num", true)
        fitMode = s("fit", FitMode.fitWidth)
        loadOriginal = b("load_original", true)
        preloadAhead = i("preload", 2).clamped(0, 8)
        doubleTapZoomLevel = f("dbltap_zoom", 2.5).clamped(1.5, 5)
        backgroundDark = b("bg_dark", true)
        useSystemBrightness = b("sys_brightness", true)
        customBrightness = f("brightness", 0.5).clamped(0.01, 1)
        warmFilterStrength = f("warm_filter", 0).clamped(0, 0.6)
        keepScreenOn = b("keep_screen_on", true)
        immersive = b("immersive", true)
        tapZoneReversed = b("tap_reversed", false)
    }

    /// 漫画通常右翻页（RTL）；Pixiv 多页插画一般 LTR。提供一键切换。
    func toggleDirection() {
        pageDirection = pageDirection == .ltr ? .rtl : .ltr
    }

    /// String capturing every layout-affecting field; the paged container resets
    /// the viewport (resuming the current page) whenever this changes.
    var layoutKey: String {
        "\(readingMode.rawValue)|\(pageDirection.rawValue)|\(flipAnim.rawValue)|\(fitMode.rawValue)"
    }

    private func set<T: Equatable>(_ value: T, _ old: T, _ key: String) {
        guard value != old else { return }
        d.set(value, forKey: Self.prefix + key)
    }

    private func setEnum(_ value: String, _ old: String, _ key: String) {
        guard value != old else { return }
        d.set(value, forKey: Self.prefix + key)
    }
}

private extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
