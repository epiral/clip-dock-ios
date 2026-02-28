// SpeakingAudioManager.swift
// AVAudioEngine wrapper for microphone PCM capture and speaker playback
// Ported from speaking-practice — removed SessionRecorder/AppLogger dependencies

import Foundation
import AVFoundation
import os

protocol SpeakingAudioManagerDelegate: AnyObject {
    func audioManagerDidCapture(base64: String)
    func audioManagerDidEncounterFatalError(_ reason: String)
}

final class SpeakingAudioManager {
    weak var delegate: SpeakingAudioManagerDelegate?

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var inputNode: AVAudioInputNode?
    private let log = Logger(subsystem: "com.epiral.pinix-shell", category: "SpeakingAudio")
    private var isRecording = false
    private let processingQueue = DispatchQueue(label: "com.epiral.pinix.speaking.audio", qos: .userInteractive)

    private let playbackFormat: AVAudioFormat

    init() {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: PCMCodec.outputSampleRate,
            channels: PCMCodec.channels,
            interleaved: false
        ) else {
            fatalError("SpeakingAudioManager: failed to create playback format")
        }
        playbackFormat = fmt
        registerForNotifications()
    }

    private func registerForNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            log.info("Audio session interruption began — stopping recording")
            stopRecording()
            delegate?.audioManagerDidEncounterFatalError("Audio interrupted by another app")
        case .ended:
            log.info("Audio interruption ended")
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        if reason == .oldDeviceUnavailable {
            log.info("Audio route change — headphones disconnected")
            stopRecording()
            delegate?.audioManagerDidEncounterFatalError("Headphones disconnected")
        }
    }

    func setupSession() throws {
        log.info("setupSession starting")
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setPreferredSampleRate(PCMCodec.inputSampleRate)
        try session.setActive(true)
        log.info("Audio session configured (sampleRate=\(session.sampleRate))")
    }

    func startRecording() throws {
        guard !isRecording else {
            log.info("startRecording — already recording, skipping")
            return
        }

        if engine != nil {
            log.info("startRecording — cleaning up stale engine")
            inputNode?.removeTap(onBus: 0)
            playerNode?.stop()
            engine?.stop()
            playerNode = nil
            inputNode = nil
            engine = nil
        }

        log.info("startRecording — building engine")

        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        newEngine.attach(newPlayer)

        newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: playbackFormat)

        let inputNode = newEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        log.info("hw input format: \(hwFormat)")

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            let msg = "Invalid hardware input format: sampleRate=\(hwFormat.sampleRate) channels=\(hwFormat.channelCount)"
            log.error("\(msg)")
            throw NSError(domain: "SpeakingAudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        let targetFormat = PCMCodec.inputFormat

        log.info("installing tap (hwFormat → targetFormat: \(targetFormat))")
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            self?.processingQueue.async {
                self?.processInputBuffer(copy, from: hwFormat, to: targetFormat)
            }
        }

        do {
            try newEngine.start()
        } catch {
            log.error("AVAudioEngine.start() failed: \(error)")
            inputNode.removeTap(onBus: 0)
            throw error
        }
        newPlayer.play()

        engine = newEngine
        playerNode = newPlayer
        self.inputNode = inputNode
        isRecording = true
        log.info("Recording started")
    }

    func stopRecording() {
        guard isRecording else { return }
        log.info("stopRecording — tearing down engine")
        isRecording = false

        inputNode?.removeTap(onBus: 0)
        playerNode?.stop()
        engine?.stop()

        playerNode = nil
        inputNode = nil
        engine = nil

        log.info("Recording stopped")
    }

    func playAudio(_ buffer: AVAudioPCMBuffer) {
        guard let player = playerNode, let engine = engine, engine.isRunning else { return }
        guard let converted = convertToPlaybackFormat(buffer) else { return }
        player.scheduleBuffer(converted, completionHandler: nil)
    }

    func stopPlayback() {
        guard let player = playerNode else { return }
        player.stop()
        player.play()
        log.info("[Barge-in] stopPlayback — player stopped & re-armed")
    }

    func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func processInputBuffer(
        _ buffer: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            log.error("processInputBuffer: failed to create AVAudioConverter")
            return
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = UInt32(Double(buffer.frameLength) * ratio)
        guard outputFrameCount > 0 else { return }
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            log.error("processInputBuffer: failed to create output PCMBuffer")
            return
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            log.error("processInputBuffer: conversion error: \(error)")
            return
        }

        if let base64 = PCMCodec.encode(outputBuffer) {
            delegate?.audioManagerDidCapture(base64: base64)
        }
    }

    private func convertToPlaybackFormat(_ pcm16Buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: PCMCodec.outputFormat, to: playbackFormat) else {
            log.error("convertToPlaybackFormat: failed to create converter")
            return nil
        }
        let outputCapacity = UInt32(Double(pcm16Buffer.frameLength) * (playbackFormat.sampleRate / PCMCodec.outputSampleRate))
        guard let output = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: max(outputCapacity, pcm16Buffer.frameLength)) else {
            log.error("convertToPlaybackFormat: failed to create output buffer")
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return pcm16Buffer
        }
        if let error {
            log.error("convertToPlaybackFormat: conversion error: \(error)")
            return nil
        }
        return output
    }
}
