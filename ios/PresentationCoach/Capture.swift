@preconcurrency import AVFoundation
import AudioToolbox
import CoreImage

struct CaptureSample: @unchecked Sendable {
    let sample: CMSampleBuffer
}

final class PhoneCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "StageSight.phone")
    private var session: AVCaptureSession?
    private var receive: (@MainActor @Sendable (CaptureSample, Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start(position: AVCaptureDevice.Position, receive: @escaping @MainActor @Sendable (CaptureSample, Bool) -> Void,
               interrupted: @escaping @MainActor @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configure(position: position, receive: receive, interrupted: interrupted)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func configure(position: AVCaptureDevice.Position, receive: @escaping @MainActor @Sendable (CaptureSample, Bool) -> Void,
                           interrupted: @escaping @MainActor @Sendable () -> Void) throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
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
        let rotation = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        let angle = rotation.videoRotationAngleForHorizonLevelCapture
        if let connection = video.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = position == .front
            }
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
    private let glasses: Bool
    private let videoFile: URL
    private let audioFile: URL
    private var glassesAudioWriter: AVAssetWriter?
    private var glassesAudioInput: AVAssetWriterInput?
    private var glassesAudioFailed = false
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var lastVideoTime = CMTime.invalid
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var firstVideo: CMSampleBuffer?
    private var firstAudio: CMSampleBuffer?
    private let imageContext = CIContext()
    private var movieStart = CMTime.invalid
    private(set) var latestVideoSeconds: Double?
    private var glassesPixels: CVPixelBufferPool?
    private var audioFrames: Int64 = 0
    private var audioStart: Double?
    private var wroteVideo = false
    private var wroteAudio = false
    private var failure: Error?
    var recordingError: Error? { failure ?? writer.error }
    var hasVideo: Bool { wroteVideo }
    var hasAudio: Bool { wroteAudio }
    var hasBothTracks: Bool { wroteVideo && wroteAudio }

    init(url: URL, glasses: Bool = false) throws {
        self.url = url
        self.glasses = glasses
        videoFile = glasses ? url.deletingPathExtension().appendingPathExtension("video.mov") : url
        audioFile = url.deletingPathExtension().appendingPathExtension("audio.m4a")
        writer = try AVAssetWriter(outputURL: videoFile, fileType: .mov)
    }

    func append(_ sample: CMSampleBuffer, video isVideo: Bool, elapsed: Double?) {
        guard failure == nil, CMSampleBufferDataIsReady(sample) else { return }
        do {
            let buffer: CMSampleBuffer
            if let elapsed, isVideo {
                buffer = try glassesVideoSample(sample, at: CMTime(seconds: elapsed, preferredTimescale: 48000))
            } else {
                buffer = sample
            }
            if writer.status == .unknown {
                if isVideo { firstVideo = buffer }
                else { firstAudio = buffer }
                if let firstVideo, glasses || firstAudio != nil {
                    let initialAudio = firstAudio
                    try begin(video: firstVideo, audio: initialAudio)
                    self.firstVideo = nil
                    self.firstAudio = nil
                    write(firstVideo, video: true)
                    if let initialAudio { write(initialAudio, video: false) }
                }
            } else if writer.status == .writing {
                write(buffer, video: isVideo)
            }
        } catch { failure = error }
    }

    func appendGlassesAudio(_ pcm: AVAudioPCMBuffer, elapsed: Double) {
        guard pcm.frameLength > 0, failure == nil else { return }
        let rate = pcm.format.sampleRate
        guard rate.isFinite, (8000...192000).contains(rate), (1...2).contains(pcm.format.channelCount) else {
            glassesAudioFailed = true
            return
        }
        if audioStart == nil { audioStart = max(0, elapsed - Double(pcm.frameLength) / rate) }
        let time = CMTime(seconds: (audioStart ?? 0) + Double(audioFrames) / rate,
                          preferredTimescale: Int32(rate))
        audioFrames += Int64(pcm.frameLength)
        do {
            let sample = try makeAudioSample(pcm, time: time)
            if glasses { appendSeparateAudio(sample, format: pcm.format) }
            else { append(sample, video: false, elapsed: nil) }
        } catch { glassesAudioFailed = true }
    }

    // An AAC encoder failure must never cancel the camera recording.
    private func appendSeparateAudio(_ sample: CMSampleBuffer, format: AVAudioFormat) {
        guard !glassesAudioFailed else { return }
        do {
            if glassesAudioWriter == nil {
                let recorder = try AVAssetWriter(outputURL: audioFile, fileType: .m4a)
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: Int(format.channelCount),
                    AVEncoderBitRateKey: 32000
                ], sourceFormatHint: format.formatDescription)
                input.expectsMediaDataInRealTime = true
                guard recorder.canAdd(input) else { throw StudioError("Unsupported glasses audio format.") }
                recorder.add(input)
                glassesAudioWriter = recorder
                glassesAudioInput = input
                guard recorder.startWriting() else { throw recorder.error ?? StudioError("Couldn’t record glasses audio.") }
                recorder.startSession(atSourceTime: .zero)
            }
            guard let input = glassesAudioInput, input.isReadyForMoreMediaData else { return }
            if input.append(sample) { wroteAudio = true }
            else { glassesAudioFailed = true }
        } catch { glassesAudioFailed = true }
    }

    private func begin(video sample: CMSampleBuffer, audio audioSample: CMSampleBuffer?) throws {
        guard let videoFormat = CMSampleBufferGetFormatDescription(sample) else {
            throw StudioError("The camera returned an unsupported format.")
        }
        let size = CMVideoFormatDescriptionGetDimensions(videoFormat)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ], sourceFormatHint: glasses ? nil : videoFormat)
        try addTrack(video)
        self.video = video
        if glasses {
            pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: Int(size.width),
                    kCVPixelBufferHeightKey as String: Int(size.height),
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ])
        }

        if let audioSample {
            guard let audioFormat = CMSampleBufferGetFormatDescription(audioSample),
                  let shape = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee else {
                throw StudioError("The microphone returned an unsupported format.")
            }
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: shape.mSampleRate,
                AVNumberOfChannelsKey: Int(shape.mChannelsPerFrame),
                AVEncoderBitRateKey: shape.mSampleRate <= 16000 ? 32000 : 64000
            ], sourceFormatHint: audioFormat)
            try addTrack(audio)
            self.audio = audio
        }

        guard writer.startWriting() else { throw writer.error ?? StudioError("Couldn’t start the movie.") }
        movieStart = glasses ? .zero : min(sample.presentationTimeStamp,
                                         audioSample?.presentationTimeStamp ?? sample.presentationTimeStamp)
        writer.startSession(atSourceTime: movieStart)
    }

    private func addTrack(_ input: AVAssetWriterInput) throws {
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw StudioError("Couldn’t add a recording track.") }
        writer.add(input)
    }

    private func write(_ sample: CMSampleBuffer, video isVideo: Bool) {
        guard let track = isVideo ? video : audio, track.isReadyForMoreMediaData else { return }
        let appended: Bool
        if isVideo, let pixelAdaptor, let pixels = CMSampleBufferGetImageBuffer(sample) {
            let time = sample.presentationTimeStamp
            guard !lastVideoTime.isValid || time > lastVideoTime else { return }
            appended = pixelAdaptor.append(pixels, withPresentationTime: time)
            if appended { lastVideoTime = time }
        } else { appended = track.append(sample) }
        guard appended else {
            failure = writer.error ?? StudioError("Couldn’t write a recording sample.")
            return
        }
        if isVideo {
            wroteVideo = true
            latestVideoSeconds = (sample.presentationTimeStamp - movieStart).seconds
        } else { wroteAudio = true }
    }

    func finish(allowVideoOnly: Bool = false) async throws {
        if allowVideoOnly, failure == nil, writer.status == .unknown, let firstVideo {
            do {
                try begin(video: firstVideo, audio: nil)
                write(firstVideo, video: true)
            } catch { failure = error }
        }
        if failure == nil, writer.status == .writing, hasBothTracks || (allowVideoOnly && hasVideo) {
            video?.markAsFinished()
            audio?.markAsFinished()
            await writer.finishWriting()
            if writer.status == .completed {
                if glasses { try await finishGlassesMovie() }
                return
            }
        }
        let error = failure ?? writer.error ?? StudioError("Couldn’t finish the recording.")
        discard()
        throw error
    }

    private func finishGlassesMovie() async throws {
        // Preserve the playable video first; merging audio is optional.
        try FileManager.default.moveItem(at: videoFile, to: url)
        defer { try? FileManager.default.removeItem(at: audioFile) }
        guard !glassesAudioFailed, wroteAudio, let recorder = glassesAudioWriter else {
            glassesAudioWriter?.cancelWriting()
            wroteAudio = false
            return
        }
        glassesAudioInput?.markAsFinished()
        await recorder.finishWriting()
        guard recorder.status == .completed else { wroteAudio = false; return }
        let merged = url.deletingPathExtension().appendingPathExtension("merged.mov")
        defer { try? FileManager.default.removeItem(at: merged) }
        do {
            let videoAsset = AVURLAsset(url: url)
            let audioAsset = AVURLAsset(url: audioFile)
            let composition = AVMutableComposition()
            guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
                  let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
                  let videoDestination = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let audioDestination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw StudioError("Couldn’t combine glasses audio and video.")
            }
            let duration = try await videoAsset.load(.duration)
            try videoDestination.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
            let audioDuration = try await audioAsset.load(.duration)
            try audioDestination.insertTimeRange(CMTimeRange(start: .zero, duration: min(duration, audioDuration)), of: audioTrack, at: .zero)
            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                throw StudioError("Couldn’t prepare glasses movie.")
            }
            export.outputURL = merged
            export.outputFileType = .mov
            await export.export()
            guard export.status == .completed else {
                throw export.error ?? StudioError("Couldn’t combine glasses audio and video.")
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: merged)
        } catch {
            // The standalone video remains available in My Sessions.
            wroteAudio = false
        }
    }

    func discard() {
        if writer.status == .writing { writer.cancelWriting() }
        if glassesAudioWriter?.status == .writing { glassesAudioWriter?.cancelWriting() }
        for file in Set([url, videoFile, audioFile]) { try? FileManager.default.removeItem(at: file) }
    }

    private func glassesVideoSample(_ sample: CMSampleBuffer, at time: CMTime) throws -> CMSampleBuffer {
        guard let source = CMSampleBufferGetImageBuffer(sample) else {
            throw StudioError("The glasses returned a video frame without pixels.")
        }
        if glassesPixels == nil {
            let attributes = [
                kCVPixelBufferWidthKey as String: CVPixelBufferGetWidth(source),
                kCVPixelBufferHeightKey as String: CVPixelBufferGetHeight(source),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ] as CFDictionary
            let status = CVPixelBufferPoolCreate(nil, nil, attributes, &glassesPixels)
            guard status == kCVReturnSuccess else {
                throw StudioError("Couldn’t prepare glasses video for recording.")
            }
        }
        guard let glassesPixels else { throw StudioError("Couldn’t prepare glasses video for recording.") }
        var pixels: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, glassesPixels, &pixels) == kCVReturnSuccess,
              let pixels else { throw StudioError("Couldn’t prepare a glasses video frame.") }
        imageContext.render(CIImage(cvPixelBuffer: source), to: pixels)
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
                                                            formatDescriptionOut: &format) == noErr,
              let format else { throw StudioError("Couldn’t describe the glasses video frame.") }
        var timing = CMSampleTimingInfo(duration: sample.duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
                                                         formatDescription: format, sampleTiming: &timing,
                                                         sampleBufferOut: &output) == noErr,
              let output else { throw StudioError("Couldn’t prepare the glasses video sample.") }
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
