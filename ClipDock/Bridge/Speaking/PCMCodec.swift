// PCMCodec.swift
// PCM encode/decode utility for Float32 ↔ PCM16LE conversion
// Ported from speaking-practice — no external dependencies

import Foundation
import AVFoundation

enum PCMCodec {
    static let inputSampleRate: Double = 16000   // mic → Qwen: 16 kHz
    static let outputSampleRate: Double = 24000   // Qwen → speaker: 24 kHz
    static let channels: AVAudioChannelCount = 1

    /// Format for recording / sending to Qwen (16 kHz PCM16 mono)
    static var inputFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: inputSampleRate, channels: channels, interleaved: true)!
    }

    /// Format for decoding audio received from Qwen (24 kHz PCM16 mono)
    static var outputFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: outputSampleRate, channels: channels, interleaved: true)!
    }

    static func encode(_ buffer: AVAudioPCMBuffer) -> String? {
        guard let int16Data = buffer.int16ChannelData else { return nil }
        let count = Int(buffer.frameLength)
        let data = Data(bytes: int16Data[0], count: count * MemoryLayout<Int16>.size)
        return data.base64EncodedString()
    }

    static func decode(_ base64: String) -> AVAudioPCMBuffer? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        let frameCount = UInt32(data.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { rawBuffer in
            if let src = rawBuffer.baseAddress {
                memcpy(buffer.int16ChannelData![0], src, data.count)
            }
        }
        return buffer
    }
}
