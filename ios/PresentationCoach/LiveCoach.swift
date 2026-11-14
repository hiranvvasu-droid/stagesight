@preconcurrency import AVFoundation
import Foundation

@MainActor
final class LiveCoach {
    private var socket: URLSessionWebSocketTask?
    private var audio: AsyncStream<Data>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000,
                                       channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?

    func start(base: URL, token: String, cue: @escaping @MainActor (String) -> Void) async throws {
        var request = URLRequest(url: base.appending(path: "live-session"))
        request.httpMethod = "POST"
        request.timeoutInterval = 100
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw StudioError("Live coaching couldn’t connect. Sign in again and retry.")
        }
        struct Secret: Decodable { let value: String }
        let secret = try JSONDecoder().decode(Secret.self, from: data)
        try Task.checkCancellation()
        let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")!
        var socketRequest = URLRequest(url: url)
        socketRequest.setValue("Bearer " + secret.value, forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: socketRequest)
        self.socket = socket
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(100))
        audio = continuation
        socket.resume()
        tasks = [
            Task {
                do {
                    for await bytes in stream {
                        try await Self.send(["type": "input_audio_buffer.append", "audio": bytes.base64EncodedString()], through: socket)
                    }
                } catch {
                    if !Task.isCancelled { cue("Live coaching disconnected.") }
                }
            },
            Task {
                var lastCue = Date.distantPast
                do {
                    while !Task.isCancelled {
                        let event = try await socket.receive()
                        guard case let .string(text) = event,
                              let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                              let type = json["type"] as? String else { continue }
                        switch type {
                        case "session.updated", "session.created":
                            cue("Live coaching connected.")
                        case "input_audio_buffer.committed" where Date().timeIntervalSince(lastCue) >= 25:
                            lastCue = Date()
                            try await Self.send(["type": "response.create", "response": ["max_output_tokens": 120]], through: socket)
                        case "response.output_text.done":
                            if let text = json["text"] as? String, !text.isEmpty { cue(text) }
                        case "error":
                            cue("Live coaching returned an error.")
                        default:
                            break
                        }
                    }
                } catch {
                    if !Task.isCancelled { cue("Live coaching disconnected.") }
                }
            }
        ]
    }

    func append(_ sample: CMSampleBuffer) {
        guard audio != nil, let description = sample.formatDescription,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let source = AVAudioFormat(streamDescription: stream),
              let pcm = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return }
        pcm.frameLength = pcm.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(pcm.frameLength),
                                                           into: pcm.mutableAudioBufferList) == noErr else { return }
        append(pcm)
    }

    func append(_ pcm: AVAudioPCMBuffer) {
        guard let audio, pcm.frameLength > 0 else { return }
        if converter?.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: format)
        }
        let capacity = AVAudioFrameCount((Double(pcm.frameLength) * 24000 / pcm.format.sampleRate).rounded(.up)) + 64
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        let input = ConversionInput(pcm)
        var error: NSError?
        let state = converter.convert(to: output, error: &error) { _, status in
            guard let buffer = input.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
        guard state != .error, let samples = output.int16ChannelData, output.frameLength > 0 else { return }
        audio.yield(Data(bytes: samples.pointee, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
    }

    func stop() {
        audio?.finish()
        audio = nil
        converter = nil
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private static func send(_ event: [String: Any], through socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
}

// AVAudioConverter invokes the input block synchronously.
private final class ConversionInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
