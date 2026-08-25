//
//  TimerAudioEngine.swift
//  TheJym
//
//  Synthesizes every tone the Timer feature plays — a continuous low tone
//  for the duration of a rest timer, and the short 3-2-1/1-2-3 countdown
//  beeps — entirely in code (a sine wave generator), so nothing needs to
//  ship as a bundled audio asset. Runs on an AVAudioSession configured for
//  background playback (see Info.plist's UIBackgroundModes) so a rest
//  timer's tone — and the app process it keeps alive — can keep going with
//  the screen locked, not just in the foreground. The single end-of-segment
//  alarm chime is still a local notification (TimerEngine), which is the
//  only mechanism guaranteed to fire regardless of app state; this engine's
//  tones are best-effort while the app itself is actually running.
//

import AVFoundation

@MainActor
final class TimerAudioEngine {
    static let shared = TimerAudioEngine()

    private let engine = AVAudioEngine()
    private let loopPlayer = AVAudioPlayerNode()
    private let beepPlayer = AVAudioPlayerNode()
    private let sampleRate: Double = 44100

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        engine.attach(loopPlayer)
        engine.attach(beepPlayer)
        engine.connect(loopPlayer, to: engine.mainMixerNode, format: format)
        engine.connect(beepPlayer, to: engine.mainMixerNode, format: format)
    }

    private func ensureRunning() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    /// A single short sine-wave beep at `frequency` — used for the 3-2-1/
    /// 1-2-3 countdown tones.
    func playBeep(frequency: Double, duration: Double = 0.18, amplitude: Float = 0.35) {
        ensureRunning()
        let buffer = toneBuffer(frequency: frequency, duration: duration, amplitude: amplitude)
        beepPlayer.scheduleBuffer(buffer, at: nil)
        if !beepPlayer.isPlaying { beepPlayer.play() }
    }

    /// Starts (or restarts) a continuous low tone — played for as long as a
    /// rest timer is counting down. A 1-second buffer looped indefinitely
    /// until `stopLoop()`.
    func startLoop(frequency: Double = 110, amplitude: Float = 0.12) {
        ensureRunning()
        loopPlayer.stop()
        let buffer = toneBuffer(frequency: frequency, duration: 1.0, amplitude: amplitude)
        loopPlayer.scheduleBuffer(buffer, at: nil, options: .loops)
        loopPlayer.play()
    }

    func stopLoop() {
        loopPlayer.stop()
    }

    /// A sine wave at `frequency`, `amplitude`-scaled, with a short fade at
    /// each end so looping/back-to-back playback doesn't click.
    private func toneBuffer(frequency: Double, duration: Double, amplitude: Float) -> AVAudioPCMBuffer {
        let frameCount = max(1, Int(duration * sampleRate))
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channel = buffer.floatChannelData![0]
        let fadeFrames = max(1, Int(0.01 * sampleRate))
        for frame in 0..<frameCount {
            let t = Double(frame) / sampleRate
            var sample = Float(sin(2.0 * .pi * frequency * t)) * amplitude
            if frame < fadeFrames {
                sample *= Float(frame) / Float(fadeFrames)
            } else if frame > frameCount - fadeFrames {
                sample *= Float(frameCount - frame) / Float(fadeFrames)
            }
            channel[frame] = sample
        }
        return buffer
    }
}
