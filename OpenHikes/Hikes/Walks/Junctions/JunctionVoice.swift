//
//  JunctionVoice.swift
//  OpenHikes
//
//  The voice junction warnings are spoken in.
//
//  ## Over what is already playing
//
//  A hiker with a podcast on hears the warning over it, as a navigation app
//  is heard: the session is `.playback` in the `.voicePrompt` mode, which
//  ducks other audio and interrupts spoken audio such as a podcast rather
//  than talking over it, and is let go once the sentence is said, so what
//  was playing comes back up. `.playback` is also what speaks with the ring
//  switch on silent, which is how a phone in a pocket on a hike is usually
//  set, and what lets a sentence start with the app in the background: the
//  app declares the `audio` background mode for this alone.
//
//  ## In the app's language
//
//  The sentence is the app's own words, in the language the app is running
//  in, so the voice is that language's rather than the device's: a phone set
//  to a language the app has no words for reads English words in an English
//  voice.
//

import AVFoundation
import Foundation
import os

/// What junction warnings are said through. A seam, so a suite can hear what
/// was said and a hosted test never takes the audio session.
@MainActor
protocol JunctionSpeaking: AnyObject {
    func speak(_ sentence: String)
    /// Stops anything being said, for a walk that has paused or ended.
    func stopSpeaking()
}

/// The voice for a launch that must say nothing aloud.
@MainActor
final class SilentJunctionVoice: JunctionSpeaking {
    func speak(_: String) { /* nobody listening */ }
    func stopSpeaking() { /* nothing said */ }
}

#if os(iOS)
/// The voice itself.
@MainActor
final class SystemJunctionVoice: NSObject, JunctionSpeaking {
    private static let logger = Logger(subsystem: "OpenHikes", category: "JunctionVoice")

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ sentence: String) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
            try session.setActive(true)
        } catch {
            // Said anyway: the synthesizer takes whatever session it is
            // given, and a warning heard without ducking beats none.
            Self.logger.error("Audio session refused: \(error.localizedDescription, privacy: .public)")
        }
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.language)
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// The language the app's words are in, which is the language the
    /// voice has to speak.
    private static var language: String? {
        Bundle.main.preferredLocalizations.first
    }

    /// Lets the session go once nothing more is queued, so what the warning
    /// ducked comes back.
    private func finishedSentence() {
        guard !synthesizer.isSpeaking else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.logger.debug("Audio session kept: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension SystemJunctionVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        onMainActor { [weak self] in self?.finishedSentence() }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        onMainActor { [weak self] in self?.finishedSentence() }
    }
}
#endif
