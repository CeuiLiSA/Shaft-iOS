import AVFoundation
import MediaPlayer
import Observation
import UIKit

// System TTS for the V3 novel reader — 1:1 port of upstream
// `ceui.pixiv.ui.novel.reader.tts` (#1113 / #1139): `NovelTtsText` turns
// reader tokens into engine-sized segments that keep their source offsets,
// `NovelTtsPlayer` owns the platform engine + queue (the Android foreground
// `NovelTtsService`), and publishes `PlaybackState` for the reader to render
// the highlight / auto-follow / "read from this page" pill.
//
// Background reading continues after the reader closes, exactly like the
// Android service: the lock-screen Now Playing card with play / pause / stop
// stands in for the media notification.

// MARK: - Text

/// Converts reader tokens to speech-safe text and keeps utterances below the
/// engine limit. Offsets are UTF-16, the reader's coordinate space.
enum NovelTtsText {
    /// Engines commonly reject utterances above roughly 4,000 chars.
    static let defaultMaxChars = 3_500
    /// Japanese voices sound more natural when the engine receives shorter turns.
    static let japaneseMaxChars = 1_800

    struct Segment: Equatable {
        let text: String
        var sourceStart: Int
        var sourceEnd: Int
        var wholeToken = false

        init(text: String, sourceStart: Int = -1, sourceEnd: Int? = nil, wholeToken: Bool = false) {
            self.text = text
            self.sourceStart = sourceStart
            self.sourceEnd = sourceEnd ?? sourceStart + text.utf16.count
            self.wholeToken = wholeToken
        }

        /// Offsets use the same coordinate space as the reader's text blocks.
        func sourceRange(start: Int = 0, end: Int? = nil) -> Range<Int>? {
            let length = text.utf16.count
            let end = end ?? length
            guard sourceStart >= 0, (0..<length).contains(start), ((start + 1)...length).contains(end) else { return nil }
            return wholeToken ? sourceStart..<sourceEnd : (sourceStart + start)..<(sourceStart + end)
        }
    }

    /// Keep paragraph boundaries; split only to respect the engine input limit.
    static func segmentsFromTokens(_ tokens: [ContentToken], startCharIndex: Int = 0, maxChars: Int = defaultMaxChars) -> [Segment] {
        var result: [Segment] = []
        for token in tokens where token.sourceEnd > startCharIndex {
            switch token {
            case .paragraph(_, _, let text, let textSourceStart, _):
                let ns = text as NSString
                let offset = min(max(startCharIndex - textSourceStart, 0), ns.length)
                result += split(ns.substring(from: offset), maxChars: maxChars).map {
                    var s = $0
                    s.sourceStart += textSourceStart + offset
                    s.sourceEnd += textSourceStart + offset
                    return s
                }
            case .chapter(let start, let end, let title):
                result += split(title, maxChars: maxChars).map {
                    Segment(text: $0.text, sourceStart: start, sourceEnd: end, wholeToken: true)
                }
            default:
                break
            }
        }
        return result
    }

    static func paragraphStart(_ tokens: [ContentToken], charIndex: Int) -> Int? {
        for token in tokens {
            switch token {
            case .paragraph(_, _, let text, let textSourceStart, _):
                if (textSourceStart..<(textSourceStart + text.utf16.count)).contains(charIndex) { return textSourceStart }
            case .chapter(let start, let end, _):
                if (start..<end).contains(charIndex) { return start }
            default:
                break
            }
        }
        return nil
    }

    /// Selects a speech language from the script instead of the app/device UI
    /// locale — any kana means Japanese.
    static func detectLanguage(_ text: String) -> String? {
        let hasKana = text.unicodeScalars.contains { (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value) }
        return hasKana ? "ja-JP" : nil
    }

    static func maxChars(forLanguage language: String?) -> Int {
        language?.hasPrefix("ja") == true ? japaneseMaxChars : defaultMaxChars
    }

    static func fromTokens(_ tokens: [ContentToken], title: String? = nil, startCharIndex: Int = 0) -> String {
        var out = ""
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, startCharIndex <= 0 {
            out += title.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        for token in tokens where token.sourceEnd > startCharIndex {
            switch token {
            case .paragraph(_, _, let text, let textSourceStart, _):
                let ns = text as NSString
                let offset = min(max(startCharIndex - textSourceStart, 0), ns.length)
                out += ns.substring(from: offset) + "\n"
            case .chapter(_, _, let title):
                out += title + "\n"
            case .blankLine, .pageBreak:
                out += "\n"
            // Images and navigation controls have no useful spoken
            // representation; skipping them avoids reading markup.
            case .pixivImage, .uploadedImage, .jump:
                break
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func split(_ text: String, maxChars: Int = defaultMaxChars) -> [Segment] {
        precondition(maxChars > 0, "maxChars must be positive")
        let source = Array(text.utf16)
        let ns = text as NSString
        func isWhitespace(_ u: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(u) else { return false }
            return scalar.properties.isWhitespace
        }
        var result: [Segment] = []
        var start = 0
        while start < source.count {
            while start < source.count && isWhitespace(source[start]) { start += 1 }
            if start == source.count { break }
            let remaining = source.count - start
            if remaining <= maxChars {
                let part = trimEnd(ns.substring(from: start))
                result.append(Segment(text: part, sourceStart: start, sourceEnd: start + part.utf16.count))
                break
            }
            let hardEnd = start + maxChars
            var candidate = -1
            for i in stride(from: hardEnd - 1, through: start, by: -1) where sentenceBoundaries.contains(source[i]) {
                candidate = i - start
                break
            }
            var boundary = candidate >= maxChars / 2 ? start + candidate + 1 : hardEnd
            // Do not send half of a supplementary character to the engine.
            if boundary > start + 1, UTF16.isLeadSurrogate(source[boundary - 1]), UTF16.isTrailSurrogate(source[boundary]) {
                boundary -= 1
            }
            let part = trimEnd(ns.substring(with: NSRange(location: start, length: boundary - start)))
            if !part.isEmpty { result.append(Segment(text: part, sourceStart: start, sourceEnd: start + part.utf16.count)) }
            start = boundary
            while start < source.count && isWhitespace(source[start]) { start += 1 }
        }
        return result
    }

    private static func trimEnd(_ s: String) -> String {
        var s = Substring(s)
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return String(s)
    }

    private static let sentenceBoundaries: Set<UInt16> = Set("\n。！？；：!?;:.,，".utf16)
}

// MARK: - Player

/// Owns the system speech engine and its queue. Only one short utterance is
/// outstanding at a time (no unbounded engine queue); each utterance is
/// identity-checked so a late callback from a stopped one never mutates state.
@MainActor
@Observable
final class NovelTtsPlayer: NSObject {
    static let shared = NovelTtsPlayer()

    enum State: String { case idle, preparing, playing, paused, error }

    struct PlaybackState: Equatable {
        var sessionId: String?
        var state: State = .idle
        var sourceRange: Range<Int>?

        func state(forSession id: String) -> State { sessionId == id ? state : .idle }
        var isActive: Bool { state == .preparing || state == .playing || state == .paused }
    }

    /// Only the player writes playback state; the reader renders from it.
    private(set) var playback = PlaybackState()
    /// One-shot error for the session that raised it (the Android state broadcast's EXTRA_ERROR).
    private(set) var lastError: (sessionId: String, message: String, seq: Int)?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var segments: [NovelTtsText.Segment] = []
    @ObservationIgnored private var currentIndex = 0
    @ObservationIgnored private var currentOffset = 0
    @ObservationIgnored private var utteranceOffset = 0
    @ObservationIgnored private var activeUtterance: AVSpeechUtterance?
    @ObservationIgnored private var title = ""
    @ObservationIgnored private var speed: Double = 1
    @ObservationIgnored private var pitch: Double = 1
    @ObservationIgnored private var language: String?
    @ObservationIgnored private var errorSeq = 0
    @ObservationIgnored private var remoteCommandsInstalled = false
    @ObservationIgnored private var l10n: (LocalizedKey) -> String = { $0.rawValue }

    override private init() {
        super.init()
        synthesizer.delegate = self
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(audioInterrupted(_:)),
                           name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(audioRouteChanged(_:)),
                           name: AVAudioSession.routeChangeNotification, object: nil)
    }

    func configureL10n(_ t: @escaping (LocalizedKey) -> String) { l10n = t }

    // MARK: Commands

    func start(sessionId: String, title: String, segments: [NovelTtsText.Segment],
               speed: Double, pitch: Double, language: String?) {
        invalidateUtterance()
        synthesizer.stopSpeaking(at: .immediate)
        self.title = title
        self.segments = segments
        currentIndex = 0
        currentOffset = 0
        self.speed = min(max(speed, 0.5), 2)
        self.pitch = min(max(pitch, 0.5), 2)
        self.language = language
        playback = PlaybackState(sessionId: sessionId, state: .preparing, sourceRange: nil)
        guard !segments.isEmpty else {
            finish(error: l10n(.readerTtsEmpty))
            return
        }
        // A missing voice pack for the detected language must be reported, not
        // silently read with an unrelated voice.
        if let language, AVSpeechSynthesisVoice(language: language) == nil {
            finish(error: l10n(.readerTtsLanguageUnavailable))
            return
        }
        installRemoteCommandsIfNeeded()
        queueFromCurrent()
    }

    func pause(sessionId: String) {
        guard playback.sessionId == sessionId else { return }
        pauseSpeech()
    }

    func resume(sessionId: String) {
        guard playback.sessionId == sessionId, playback.state == .paused else { return }
        playback.state = .preparing
        queueFromCurrent()
    }

    func stop(sessionId: String) {
        guard playback.sessionId == sessionId else { return }
        finish()
    }

    func setSpeed(sessionId: String, speed: Double) {
        guard playback.sessionId == sessionId else { return }
        self.speed = min(max(speed, 0.5), 2)
        if playback.state == .playing { queueFromCurrent() }
    }

    // MARK: Queue

    private func queueFromCurrent() {
        guard !segments.isEmpty else { return }
        invalidateUtterance()
        synthesizer.stopSpeaking(at: .immediate)
        guard activateAudioSession() else {
            playback.state = .paused
            updateNowPlaying()
            return
        }
        playback.state = .playing
        if speakCurrentSegment() { updateNowPlaying() }
    }

    private func speakCurrentSegment() -> Bool {
        guard segments.indices.contains(currentIndex) else { return false }
        let segment = segments[currentIndex]
        utteranceOffset = currentOffset
        let text = (segment.text as NSString).substring(from: min(utteranceOffset, segment.text.utf16.count))
        let utterance = AVSpeechUtterance(string: text)
        // Android rate 1.0 == the engine's default; 2.0 reaches the maximum.
        utterance.rate = Float(min(max(Double(AVSpeechUtteranceDefaultSpeechRate) * speed,
                                       Double(AVSpeechUtteranceMinimumSpeechRate)),
                                   Double(AVSpeechUtteranceMaximumSpeechRate)))
        utterance.pitchMultiplier = Float(pitch)
        utterance.voice = language.flatMap(AVSpeechSynthesisVoice.init(language:))
        activeUtterance = utterance
        synthesizer.speak(utterance)
        return true
    }

    private func isCurrent(_ utterance: AVSpeechUtterance) -> Bool {
        playback.state == .playing && utterance === activeUtterance
    }

    private func invalidateUtterance() { activeUtterance = nil }

    private func pauseSpeech() {
        guard playback.state == .playing || playback.state == .preparing else { return }
        invalidateUtterance()
        synthesizer.stopSpeaking(at: .immediate)
        deactivateAudioSession()
        playback.state = .paused
        updateNowPlaying()
    }

    private func finish(error: String? = nil) {
        invalidateUtterance()
        synthesizer.stopSpeaking(at: .immediate)
        deactivateAudioSession()
        segments = []
        let session = playback.sessionId
        playback = PlaybackState(sessionId: session, state: error == nil ? .idle : .error, sourceRange: nil)
        if let error, let session {
            errorSeq += 1
            lastError = (session, error, errorSeq)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Audio session ("audio focus")

    private func activateAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @objc nonisolated private func audioInterrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor in self.pauseSpeech() }
    }

    /// Headphones unplugged — Android's ACTION_AUDIO_BECOMING_NOISY.
    @objc nonisolated private func audioRouteChanged(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        Task { @MainActor in self.pauseSpeech() }
    }

    // MARK: Now Playing (the media notification)

    private func installRemoteCommandsIfNeeded() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self, let id = self.playback.sessionId, self.playback.state == .paused else { return .commandFailed }
            self.resume(sessionId: id)
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, let id = self.playback.sessionId, self.playback.isActive else { return .commandFailed }
            self.pause(sessionId: id)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, let id = self.playback.sessionId, self.playback.isActive else { return .commandFailed }
            if self.playback.state == .paused { self.resume(sessionId: id) } else { self.pause(sessionId: id) }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            guard let self, let id = self.playback.sessionId, self.playback.isActive else { return .commandFailed }
            self.stop(sessionId: id)
            return .success
        }
    }

    private func updateNowPlaying() {
        let progress = String(format: l10n(.readerTtsProgress), min(currentIndex + 1, segments.count), segments.count)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title.isEmpty ? l10n(.readerTtsTitle) : title,
            MPMediaItemPropertyArtist: progress,
            MPNowPlayingInfoPropertyPlaybackRate: playback.state == .playing ? 1.0 : 0.0,
        ]
    }
}

extension NovelTtsPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.isCurrent(utterance) else { return }
            self.playback.sourceRange = self.segments[self.currentIndex].sourceRange(start: self.utteranceOffset)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.isCurrent(utterance) else { return }
            let length = self.segments[self.currentIndex].text.utf16.count - self.utteranceOffset
            let start = characterRange.location, end = characterRange.location + characterRange.length
            guard (0..<length).contains(start), ((start + 1)...length).contains(end) else { return }
            self.currentOffset = max(self.currentOffset, self.utteranceOffset + start)
            self.playback.sourceRange = self.segments[self.currentIndex]
                .sourceRange(start: self.utteranceOffset + start, end: self.utteranceOffset + end)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.isCurrent(utterance) else { return }
            self.activeUtterance = nil
            self.currentIndex += 1
            self.currentOffset = 0
            if self.currentIndex >= self.segments.count {
                self.finish()
            } else if self.speakCurrentSegment() {
                self.updateNowPlaying()
            }
        }
    }
}
