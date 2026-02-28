// QwenRealtimeModels.swift
// Qwen protocol event type definitions and session config
// Ported from speaking-practice — no external dependencies

import Foundation

enum QwenEventType {
    // Client -> Server
    static let sessionUpdate = "session.update"
    static let inputAudioAppend = "input_audio_buffer.append"
    static let inputAudioCommit = "input_audio_buffer.commit"
    static let responseCreate = "response.create"
    static let responseCancel = "response.cancel"

    // Server -> Client
    static let error = "error"
    static let responseCreated = "response.created"
    static let outputItemAdded = "response.output_item.added"
    static let textDelta = "response.text.delta"
    static let audioDelta = "response.audio.delta"
    static let audioTranscriptDelta = "response.audio_transcript.delta"
    static let audioTranscriptDone = "response.audio_transcript.done"
    static let inputTranscriptionCompleted = "conversation.item.input_audio_transcription.completed"
    static let speechStarted = "input_audio_buffer.speech_started"
    static let speechStopped = "input_audio_buffer.speech_stopped"
    static let responseDone = "response.done"
}

struct QwenSessionConfig {
    var modalities: [String] = ["text", "audio"]
    var voice: String = "Ethan"
    var inputAudioFormat: String = "pcm16"
    var outputAudioFormat: String = "pcm16"
    var transcriptionModel: String = "gummy-realtime-v1"
    var vadThreshold: Double = 0.8
    var prefixPaddingMs: Int = 500
    var silenceDurationMs: Int = 1500
    var instructions: String = ""

    func toDict() -> [String: Any] {
        [
            "modalities": modalities,
            "voice": voice,
            "input_audio_format": inputAudioFormat,
            "output_audio_format": outputAudioFormat,
            "input_audio_transcription": [
                "model": transcriptionModel
            ],
            "turn_detection": [
                "type": "server_vad",
                "threshold": vadThreshold,
                "prefix_padding_ms": prefixPaddingMs,
                "silence_duration_ms": silenceDurationMs
            ],
            "instructions": instructions
        ]
    }
}
