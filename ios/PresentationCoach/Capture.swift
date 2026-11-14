@preconcurrency import AVFoundation
import AudioToolbox

struct CaptureSample: @unchecked Sendable {
    let sample: CMSampleBuffer
}

final class PhoneCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "StageSight.phone")
    private var session: AVCaptureSession?
    private var receive: (@MainActor @Sendable (CaptureSample, Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start(receive: @escaping @MainActor @Sendable (CaptureSample, Bool) -> Void,
               interrupted: @escaping @MainActor @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configure(receive: receive, interrupted: interrupted)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func configure(receive: @escaping @MainActor @Sendable (CaptureSample, Bool) -> Void,
                           interrupted: @escaping @MainActor @Sendable () -> Void) throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let mic = AVCaptureDevice.default(for: .audio) else {
            throw StudioError("The built-in iPhone camera and microphone are required.")
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        let audio = AVCaptureAudioDataOutput()
        for device in [camera, mic] {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw StudioError("Couldn’t connect the iPhone capture input.") }
            session.addInput(input)
        }
        for output in [video as AVCaptureOutput, audio as AVCaptureOutput] {
            guard session.canAddOutput(output) else { throw StudioError("Couldn’t configure the iPhone capture output.") }
            session.addOutput(output)
        }
        if let connection = video.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        video.setSampleBufferDelegate(self, queue: queue)
        audio.setSampleBufferDelegate(self, queue: queue)
        self.receive = receive
        self.session = session
        let center = NotificationCenter.default
        observers = [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification].map {
            center.addObserver(forName: $0, object: session, queue: .main) { _ in
                Task { @MainActor in interrupted() }
            }
        }
        session.commitConfiguration()
        session.startRunning()
        guard session.isRunning else { throw StudioError("Couldn’t start iPhone capture.") }
    }

    func stop() {
        queue.async {
            self.receive = nil
            self.observers.forEach(NotificationCenter.default.removeObserver)
            self.observers.removeAll()
            self.session?.stopRunning()
            self.session = nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let receive else { return }
        let frame = CaptureSample(sample: sampleBuffer)
        let isVideo = output is AVCaptureVideoDataOutput
        DispatchQueue.main.async { receive(frame, isVideo) }
    }
}

@MainActor
final class SessionMovie {
    private let url: URL
    private let writer: AVAssetWriter
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var firstVideo: CMSampleBuffer?
    private var firstAudio: CMSampleBuffer?
    private var audioFrames: Int64 = 0
    private var audioStart: Double?
    private var wroteVideo = false
    private var wroteAudio = false
    private var failure: Error?
    var recordingError: Error? { failure ?? writer.error }
    var hasBothTracks: Bool { wroteVideo && wroteAudio }

    init(url: URL) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    }

    func append(_ sample: CMSampleBuffer, video isVideo: Bool, elapsed: Double?) {
        guard failure == nil, CMSampleBufferDataIsReady(sample) else { return }
        do {
            let buffer = try elapsed.map { try retime(sample, to: CMTime(seconds: $0, preferredTimescale: 48000)) } ?? sample
            if writer.status == .unknown {
                if isVideo { firstVideo = buffer }
                else { firstAudio = buffer }
                if let firstVideo, let firstAudio {
                    try begin(video: firstVideo, audio: firstAudio)
                    self.firstVideo = nil
                    self.firstAudio = nil
                    write(firstVideo, video: true)
                    write(firstAudio, video: false)
                }
            } else if writer.status == .writing {
                write(buffer, video: isVideo)
            }
        } catch { failure = error }
    }

    func appendGlassesAudio(_ pcm: AVAudioPCMBuffer, elapsed: Double) {
        guard pcm.frameLength > 0, failure == nil else { return }
        let rate = pcm.format.sampleRate
        if audioStart == nil { audioStart = max(0, elapsed - Double(pcm.frameLength) / rate) }
        let time = CMTime(seconds: (audioStart ?? 0) + Double(audioFrames) / rate,
                          preferredTimescale: Int32(rate))
        audioFrames += Int64(pcm.frameLength)
        do {
            let sample = try makeAudioSample(pcm, time: time)
            append(sample, video: false, elapsed: nil)
        } catch { failure = error }
    }

    private func begin(video sample: CMSampleBuffer, audio audioSample: CMSampleBuffer) throws {
        guard let videoFormat = CMSampleBufferGetFormatDescription(sample),
              let audioFormat = CMSampleBufferGetFormatDescription(audioSample),
              let audioShape = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee else {
            throw StudioError("The camera or microphone returned an unsupported format.")
        }
        let size = CMVideoFormatDescriptionGetDimensions(videoFormat)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ], sourceFormatHint: videoFormat)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audioShape.mSampleRate,
            AVNumberOfChannelsKey: Int(audioShape.mChannelsPerFrame), AVEncoderBitRateKey: 64000
        ], sourceFormatHint: audioFormat)
        for input in [video, audio] {
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw StudioError("Couldn’t add a recording track.") }
            writer.add(input)
        }
        self.video = video
        self.audio = audio
        guard writer.startWriting() else { throw writer.error ?? StudioError("Couldn’t start the movie.") }
        writer.startSession(atSourceTime: min(sample.presentationTimeStamp, audioSample.presentationTimeStamp))
    }

    private func write(_ sample: CMSampleBuffer, video isVideo: Bool) {
        guard let track = isVideo ? video : audio, track.isReadyForMoreMediaData else { return }
        guard track.append(sample) else {
            failure = writer.error ?? StudioError("Couldn’t write a recording sample.")
            return
        }
        if isVideo { wroteVideo = true }
        else { wroteAudio = true }
    }

    func finish() async throws {
        if failure == nil, writer.status == .writing, hasBothTracks {
            video?.markAsFinished()
            audio?.markAsFinished()
            await writer.finishWriting()
            if writer.status == .completed { return }
        }
        let error = failure ?? writer.error ?? StudioError("Couldn’t finish the recording.")
        discard()
        throw error
    }

    func discard() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }

    private func retime(_ sample: CMSampleBuffer, to time: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: sample.duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                           sampleBufferOut: &output)
        guard status == noErr, let output else { throw StudioError("Couldn’t timestamp a glasses video frame.") }
        return output
    }

    private func makeAudioSample(_ pcm: AVAudioPCMBuffer, time: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(pcm.format.sampleRate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        let created = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                           makeDataReadyCallback: nil, refcon: nil,
                                           formatDescription: pcm.format.formatDescription,
                                           sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1,
                                           sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                           sampleBufferOut: &output)
        guard created == noErr, let output,
              CMSampleBufferSetDataBufferFromAudioBufferList(output, blockBufferAllocator: kCFAllocatorDefault,
                                                            blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                            flags: 0, bufferList: pcm.audioBufferList) == noErr,
              CMSampleBufferSetDataReady(output) == noErr else {
            throw StudioError("Couldn’t encode a glasses microphone sample.")
        }
        return output
    }
}
