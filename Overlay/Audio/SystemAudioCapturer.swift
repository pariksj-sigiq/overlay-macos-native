//
//  SystemAudioCapturer.swift
//  OverlayOpus
//

import AVFoundation
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

struct CapturedAudioFrame: Sendable {
    let samples: [Float]
    let level: Float
}

enum SystemAudioCaptureError: LocalizedError {
    case noDisplayAvailable
    case permissionDenied
    case streamUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display is available for system audio capture."
        case .permissionDenied:
            return "Screen Recording permission is required to capture system audio."
        case .streamUnavailable:
            return "System audio stream is not available."
        }
    }

    var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
}

actor SystemAudioCapturer {

    // MARK: - Public stream

    private var stream: SCStream?
    private var output: SystemAudioStreamOutput?
    private var continuation: AsyncStream<CapturedAudioFrame>.Continuation?
    private var excludedWindows: [CGWindowID] = []

    func setExcludedWindows(_ ids: [CGWindowID]) {
        excludedWindows = ids
    }

    func frames() -> AsyncStream<CapturedAudioFrame> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    func start(excludingWindows ids: [CGWindowID]? = nil) async throws {
        if let ids {
            excludedWindows = ids
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                throw SystemAudioCaptureError.noDisplayAvailable
            }

            let excludedWindowIDs = excludedWindows
            let excluded = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)

            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.width = max(2, display.width)
            configuration.height = max(2, display.height)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)

            let output = SystemAudioStreamOutput { [weak self] samples in
                guard let self else { return }
                let frame = CapturedAudioFrame(samples: samples,
                                               level: Self.audioLevel(for: samples))
                Task { await self.emit(frame) }
            }

            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try await stream.startCapture()

            self.output = output
            self.stream = stream
        } catch let error as SystemAudioCaptureError {
            throw error
        } catch {
            if "\(error)".localizedCaseInsensitiveContains("permission") {
                throw SystemAudioCaptureError.permissionDenied
            }
            throw error
        }
    }

    func stop() async {
        let activeStream = stream
        stream = nil
        output = nil
        continuation?.finish()
        continuation = nil

        if let activeStream {
            try? await activeStream.stopCapture()
        }
    }

    // MARK: - Private

    private func setContinuation(_ continuation: AsyncStream<CapturedAudioFrame>.Continuation) {
        self.continuation = continuation
    }

    private func emit(_ frame: CapturedAudioFrame) {
        continuation?.yield(frame)
    }

    private static func audioLevel(for samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        let sumOfSquares = samples.reduce(Float(0)) { partial, sample in
            partial + (sample * sample)
        }
        let rms = sqrt(Double(sumOfSquares / Float(samples.count)))
        guard rms.isFinite, rms > 0 else { return 0 }

        let decibels = 20.0 * log10(max(rms, 0.000_000_1))
        let normalized = (decibels + 60.0) / 60.0
        return Float(min(1.0, max(0.0, normalized)))
    }
}

private final class SystemAudioStreamOutput: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "com.overlay-opus.system-audio", qos: .userInitiated)

    private let onSamples: ([Float]) -> Void

    init(onSamples: @escaping ([Float]) -> Void) {
        self.onSamples = onSamples
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid,
              let samples = Self.extractMono16kSamples(from: sampleBuffer),
              !samples.isEmpty else {
            return
        }
        onSamples(samples)
    }

    private static func extractMono16kSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = asbdPointer.pointee
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let sourceRate = max(1, Int(asbd.mSampleRate.rounded()))
        let stride = max(1, sourceRate / 16_000)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return [] }

        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { destination -> OSStatus in
            guard let baseAddress = destination.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferCopyDataBytes(blockBuffer,
                                              atOffset: 0,
                                              dataLength: length,
                                              destination: baseAddress)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            return nil
        }

        if asbd.mFormatID == kAudioFormatLinearPCM,
           asbd.mBitsPerChannel == 32,
           asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            return data.withUnsafeBytes { rawBuffer in
                let buffer = rawBuffer.bindMemory(to: Float.self)
                return downmixAndDecimate(buffer: buffer, channels: channels, stride: stride)
            }
        }

        if asbd.mFormatID == kAudioFormatLinearPCM,
           asbd.mBitsPerChannel == 16,
           asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            return data.withUnsafeBytes { rawBuffer in
                let buffer = rawBuffer.bindMemory(to: Int16.self)
                return downmixAndDecimate(buffer: buffer, channels: channels, stride: stride)
            }
        }

        return nil
    }

    private static func downmixAndDecimate(buffer: UnsafeBufferPointer<Float>, channels: Int, stride: Int) -> [Float] {
        let frames = buffer.count / channels
        guard frames > 0 else { return [] }

        var output: [Float] = []
        output.reserveCapacity(frames / stride)

        var frameIndex = 0
        while frameIndex < frames {
            let base = frameIndex * channels
            var sum: Float = 0
            for channel in 0..<channels {
                sum += buffer[base + channel]
            }
            output.append(sum / Float(channels))
            frameIndex += stride
        }

        return output
    }

    private static func downmixAndDecimate(buffer: UnsafeBufferPointer<Int16>, channels: Int, stride: Int) -> [Float] {
        let frames = buffer.count / channels
        guard frames > 0 else { return [] }

        var output: [Float] = []
        output.reserveCapacity(frames / stride)

        var frameIndex = 0
        while frameIndex < frames {
            let base = frameIndex * channels
            var sum: Float = 0
            for channel in 0..<channels {
                sum += Float(buffer[base + channel]) / Float(Int16.max)
            }
            output.append(sum / Float(channels))
            frameIndex += stride
        }

        return output
    }
}
