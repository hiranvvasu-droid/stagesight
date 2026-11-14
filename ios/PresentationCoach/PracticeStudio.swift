import SwiftUI
@preconcurrency import AVFoundation
@preconcurrency import Speech
import Vision
import MWDATCore
import MWDATCamera
import CoreImage
import Security

enum CaptureSource: String, CaseIterable, Identifiable, Codable {
    case phone = "iPhone"
    case glasses = "Meta glasses"
    var id: Self { self }
}

struct PacePoint: Identifiable, Codable {
    let second: Int
    let wpm: Int
    var id: Int { second }
}

struct SpeakingMetrics: Codable {
    var wpm = 0
    var pauses = 0
    var fillers = 0
    var speakingSeconds = 0
}

struct PracticeSession: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    let title: String
    let outline: String
    let source: CaptureSource
    let duration: Double
    let transcript: String
    let metrics: SpeakingMetrics
    let pace: [PacePoint]
    var report: String?
    var practiceType: String?
}

struct AudiencePerson: Identifiable {
    let id: UUID
    let box: CGRect
    let direction: String
    let awaySince: TimeInterval?
    let forwardFrames: Int
}

@MainActor
final class PracticeStudio: ObservableObject {
    @Published var title = ""
    @Published var outline = ""
    @Published var source = CaptureSource.phone
    @Published var practiceType = "Pitch practice"
    @Published var consent = false
    @Published var overlays = false
    @Published var speechEnabled = true
    @Published var liveEnabled = false
    @Published var showSignIn = false
    @Published private(set) var accountEmail: String?
    private var accountSession: AccountSession?
    private var accountGeneration = UUID()

    private struct AccountSession: Codable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double
    }
    private struct SavedAccount: Codable {
        let session: AccountSession
        let email: String
        let expiresAt: Date
    }
    private var accountExpiresAt = Date.distantPast
    private var refreshTask: Task<AccountSession, Error>?
    private let accountKey: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.stagesight.account",
        kSecAttrAccount as String: "session"
    ]

    private func restoreAccount() {
        var query = accountKey
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let saved = try? JSONDecoder().decode(SavedAccount.self, from: data) else { return }
        accountSession = saved.session
        accountEmail = saved.email
        accountExpiresAt = saved.expiresAt
    }

    func signIn(email: String, password: String) async throws {
        let session = try await requestAccount(grant: "password", fields: ["email": email, "password": password])
        try setAccount(session, email: email)
        showSignIn = false
    }

    func signOut() {
        let status = SecItemDelete(accountKey as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            message = "Couldn’t remove your saved sign-in. Try again."
            return
        }
        refreshTask?.cancel()
        refreshTask = nil
        accountGeneration = UUID()
        accountSession = nil
        accountEmail = nil
    }

    private func setAccount(_ session: AccountSession, email: String) throws {
        let expiry = Date().addingTimeInterval(session.expires_in)
        let data = try JSONEncoder().encode(SavedAccount(session: session, email: email, expiresAt: expiry))
        let values = [kSecValueData as String: data]
        var status = SecItemUpdate(accountKey as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = accountKey
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StudioError("Couldn’t save your sign-in to Keychain.") }
        accountSession = session
        accountEmail = email
        accountExpiresAt = expiry
    }

    private func accountToken() async throws -> String {
        guard let session = accountSession, let email = accountEmail else {
            throw StudioError("Sign in to StageSight to use coaching.")
        }
        if accountExpiresAt.timeIntervalSinceNow > 60 { return session.access_token }
        if let refreshTask { return try await refreshTask.value.access_token }
        let generation = accountGeneration
        let task = Task {
            let renewed = try await requestAccount(grant: "refresh_token", fields: ["refresh_token": session.refresh_token])
            guard generation == accountGeneration else { throw StudioError("Sign in again to use coaching.") }
            try setAccount(renewed, email: email)
            return renewed
        }
        refreshTask = task
        defer { if generation == accountGeneration { refreshTask = nil } }
        return try await task.value.access_token
    }

    /// Returns true when the user needs to confirm their email before signing in.
    func createAccount(email: String, password: String) async throws -> Bool {
        let (data, status) = try await accountResponse(
            path: "signup", fields: ["email": email, "password": password]
        )
        guard (200..<300).contains(status) else {
            let error = try? JSONDecoder().decode(AccountError.self, from: data)
            switch error?.error_code {
            case "weak_password":
                throw StudioError("Choose a stronger password and try again.")
            case "email_exists", "user_already_exists":
                throw StudioError("This email already has an account. Try signing in.")
            default:
                if status == 429 { throw StudioError("Too many attempts. Wait a moment and try again.") }
                throw StudioError("Couldn’t create your account. Check your email or try again later.")
            }
        }
        if let session = try? JSONDecoder().decode(AccountSession.self, from: data) {
            try setAccount(session, email: email)
            showSignIn = false
            return false
        }
        return true
    }

    private struct AccountError: Decodable {
        let error_code: String?
    }

    private func requestAccount(grant: String, fields: [String: String]) async throws -> AccountSession {
        let (data, status) = try await accountResponse(path: "token?grant_type=" + grant, fields: fields)
        guard status == 200 else {
            let error = try? JSONDecoder().decode(AccountError.self, from: data)
            if error?.error_code == "email_not_confirmed" {
                throw StudioError("Confirm your email using the link in your inbox, then sign in.")
            }
            if status == 429 { throw StudioError("Too many attempts. Wait a moment and try again.") }
            throw StudioError(grant == "password" ? "Couldn’t sign in. Check your email and password." : "Session expired. Sign out and sign in again.")
        }
        return try JSONDecoder().decode(AccountSession.self, from: data)
    }

    private func accountResponse(path: String, fields: [String: String]) async throws -> (Data, Int) {
        let url = URL(string: "https://ezstwuzfupvsdiuzvdvv.supabase.co/auth/v1/" + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("sb_publishable_k8JR4vZnwCvnnXVRboSXgA_3CYgDIE6", forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StudioError("StageSight couldn’t reach the account service.")
        }
        return (data, http.statusCode)
    }

    @Published private(set) var coachingCue = ""
    @Published private(set) var recordingDate: Date?
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var message = ""
    @Published private(set) var frame: UIImage?
    @Published private(set) var audience: [AudiencePerson] = []
    @Published private(set) var transcript = ""
    @Published private(set) var metrics = SpeakingMetrics()
    @Published private(set) var sessions: [PracticeSession] = []

    private let storage = URL.applicationSupportDirectory.appending(path: "StageSight")
    private let phone = PhoneCapture()
    private let coach = LiveCoach()
    private var coachingTask: Task<Void, Never>?
    private let images = CIContext()
    private let recognizer = SFSpeechRecognizer()
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private var speechFinished = false
    private var writer: SessionMovie?
    private var sessionID = UUID()
    private var started = ProcessInfo.processInfo.systemUptime
    private var pace: [PacePoint] = []
    private var lastAnalysis = -1.0
    private var lastPreview = -1.0
    private var wearablesConfigured = false
    private var glassesSession: DeviceSession?
    private var glassesCamera: MWDATCamera.Camera?
    private var glassesListeners: [any AnyListenerToken] = []
    private var watchdog: Task<Void, Never>?
    private var finishing = false

    init() {
        restoreAccount()
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            let index = storage.appending(path: "sessions.json")
            if FileManager.default.fileExists(atPath: index.path) {
                sessions = try JSONDecoder().decode([PracticeSession].self, from: Data(contentsOf: index))
            }
        } catch { message = "Couldn’t load saved sessions. \(error.localizedDescription)" }
    }

    @Published private(set) var glassesRegistered = false
    @Published private(set) var glassesSetupMessage = ""

    func resetCaptureStatus() {
        message = ""
        glassesSetupMessage = ""
    }

    func refreshGlassesRegistration() {
        if let wearables = try? configureWearables() {
            glassesRegistered = wearables.registrationState == .registered
        }
    }

    func register() async {
        guard source == .glasses, !isBusy, !isRecording else { return }
        glassesSetupMessage = ""
        isBusy = true
        defer { isBusy = false }
        do {
            let wearables = try configureWearables()
            if wearables.registrationState == .registered {
                glassesRegistered = true
                glassesSetupMessage = "Meta AI setup is complete."
            } else {
                try await wearables.startRegistration()
                glassesSetupMessage = "Finish connecting in the Meta AI app."
            }
        } catch { glassesSetupMessage = error.localizedDescription }
    }

    func handle(_ url: URL) async {
        guard url.scheme == "stagesight" else { return }
        do {
            let wearables = try configureWearables()
            guard try await wearables.handleUrl(url) else { return }
            glassesRegistered = wearables.registrationState == .registered
            glassesSetupMessage = glassesRegistered ? "Meta AI setup is complete." : "Finish setup in Meta AI, then return to StageSight."
        } catch { glassesSetupMessage = error.localizedDescription }
    }

    private func configureWearables() throws -> any WearablesInterface {
        if !wearablesConfigured {
            try Wearables.configure()
            wearablesConfigured = true
        }
        return Wearables.shared
    }

    func start() async {
        guard !isBusy, !isRecording else { return }
        isBusy = true
        defer { isBusy = false }
        message = ""
        guard consent else { message = "Confirm recording consent before starting."; return }
        let selected = source
        if selected == .phone {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                message = "Camera access is off. Allow StageSight to use the camera in Settings."
                return
            }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                message = "Microphone access is off. Allow StageSight to use the microphone in Settings."
                return
            }
        }
        var speechAllowed = false
        if speechEnabled {
            speechAllowed = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status == .authorized) }
            }
        }
        do {
            sessionID = UUID()
            writer = try SessionMovie(url: videoURL(for: sessionID))
            started = ProcessInfo.processInfo.systemUptime
            transcript = ""
            metrics = SpeakingMetrics()
            pace = []
            audience = []
            frame = nil
            lastAnalysis = -1
            lastPreview = -1
            if speechAllowed, let recognizer, recognizer.supportsOnDeviceRecognition, recognizer.isAvailable {
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = true
                request.addsPunctuation = true
                speechRequest = request
                speechFinished = false
                let id = sessionID
                speechTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                    let words = result?.bestTranscription.segments.map {
                        SpokenWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    }
                    let formatted = result?.bestTranscription.formattedString
                    let finished = result?.isFinal == true || error != nil
                    let failed = error != nil
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == id, self.speechRequest != nil else { return }
                        if let words, let formatted, !words.isEmpty { self.updateSpeech(words, formatted: formatted) }
                        if finished { self.speechFinished = true }
                        if failed && !self.finishing {
                            self.message = "Live transcription stopped. Video and audio recording are still active."
                        }
                    }
                }
            } else if speechEnabled {
                message = "On-device transcription is unavailable. Camera and microphone recording can continue."
            }
            recordingDate = Date()
            isRecording = true
            coachingCue = ""
            if liveEnabled, let base = backendURL {
                coachingCue = "Connecting live coaching…"
                coachingTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let token = try await self.accountToken()
                        try await self.coach.start(base: base, token: token) { [weak self] cue in
                            self?.coachingCue = cue
                        }
                    } catch {
                        if !Task.isCancelled { self.coachingCue = error.localizedDescription }
                    }
                }
            }
            if selected == .phone {
                try await phone.start(
                    receive: { [weak self] frame, video in
                        self?.receive(frame.sample, video: video, glasses: false)
                    },
                    interrupted: { [weak self] in
                        self?.message = "iPhone capture was interrupted."
                        self?.stop()
                    }
                )
            } else {
                try await startGlasses()
            }
            watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.isRecording,
                      self.writer?.hasBothTracks != true else { return }
                if let failure = self.writer?.recordingError {
                    self.message = failure.localizedDescription
                } else { self.message = selected == .glasses
                    ? "StageSight couldn’t receive both camera and microphone from the glasses."
                    : "StageSight couldn’t receive both iPhone camera and microphone."
                }
                self.stop()
            }
        } catch {
            stopInputs()
            speechTask?.cancel()
            speechTask = nil
            speechRequest = nil
            writer?.discard()
            writer = nil
            isRecording = false
            message = error.localizedDescription
        }
    }

    private func startGlasses() async throws {
        let wearables = try configureWearables()
        guard wearables.registrationState == .registered else {
            throw StudioError("Connect your glasses in Meta AI before starting.")
        }
        for permission in [Permission.camera, .microphone] {
            if try await wearables.checkPermissionStatus(permission) != .granted {
                guard try await wearables.requestPermission(permission) == .granted else {
                    throw StudioError("Allow the glasses camera and microphone in Meta AI.")
                }
            }
        }
        let selector = AutoDeviceSelector(wearables: wearables)
        guard selector.activeDevice != nil else {
            throw StudioError("No Meta glasses are connected. Open Meta AI and check the connection.")
        }
        let session = try wearables.createSession(deviceSelector: selector)
        glassesSession = session
        glassesListeners.append(session.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.glassesSession === session, self.isRecording else { return }
                if state == .started {
                    do { try self.startGlassesStream(on: session) }
                    catch { self.message = error.localizedDescription; self.stop() }
                } else if state == .stopped || state == .paused {
                    self.message = "The glasses connection was interrupted."
                    self.stop()
                }
            }
        })
        try session.start()
        if session.state == .started { try startGlassesStream(on: session) }
    }

    private func startGlassesStream(on session: DeviceSession) throws {
        guard glassesCamera == nil else { return }
        let config = StreamConfiguration(
            videoCodec: .raw, audioCodec: .pcm(sampleRate: .rate16000, numberOfChannels: 1),
            resolution: .medium, frameRate: 24
        )
        guard let camera = try session.addCamera(config: config) else {
            throw StudioError("The glasses couldn’t start camera and microphone capture.")
        }
        glassesCamera = camera
        let stream = camera.stream
        glassesListeners.append(stream.videoFramePublisher.listen { [weak self] video in
            Task { @MainActor [weak self] in
                guard let self, self.glassesCamera?.stream === stream else { return }
                self.receive(video.sampleBuffer, video: true, glasses: true)
            }
        })
        glassesListeners.append(stream.audioFramePublisher.listen { [weak self] audio in
            Task { @MainActor [weak self] in
                guard let self, self.glassesCamera?.stream === stream, self.isRecording else { return }
                self.speechRequest?.append(audio.pcmBuffer)
                self.coach.append(audio.pcmBuffer)
                self.writer?.appendGlassesAudio(audio.pcmBuffer, elapsed: self.elapsed)
            }
        })
        glassesListeners.append(stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.glassesCamera?.stream === stream else { return }
                self.message = "Glasses capture stopped. \(error.localizedDescription)"
                self.stop()
            }
        })
        stream.start()
    }

    private var elapsed: Double { ProcessInfo.processInfo.systemUptime - started }

    private func receive(_ sample: CMSampleBuffer, video: Bool, glasses: Bool) {
        guard isRecording else { return }
        let now = elapsed
        writer?.append(sample, video: video, elapsed: glasses ? now : nil)
        if !video {
            speechRequest?.appendAudioSampleBuffer(sample)
            coach.append(sample)
            return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sample), now - lastPreview >= 0.06 else { return }
        lastPreview = now
        let image = CIImage(cvPixelBuffer: buffer)
        if let cgImage = images.createCGImage(image, from: image.extent) {
            frame = UIImage(cgImage: cgImage)
        }
        if overlays, now - lastAnalysis >= 0.25 {
            lastAnalysis = now
            analyze(buffer, at: now)
        }
    }

    private func analyze(_ buffer: CVPixelBuffer, at timestamp: Double) {
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        let faces = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer).perform([people, faces])
        } catch {
            audience = []
            return
        }
        let previous = audience
        var used = Set<UUID>()
        audience = (people.results ?? []).filter { $0.confidence >= 0.45 }.map { person in
            let box = person.boundingBox
            let nearby = previous.filter { !used.contains($0.id) && intersection($0.box, box) >= 0.3 }
            let match = nearby.max { intersection($0.box, box) < intersection($1.box, box) }
            let id = match?.id ?? UUID()
            used.insert(id)
            let face = (faces.results ?? []).filter {
                $0.confidence >= 0.55 && $0.boundingBox.width >= 0.025 &&
                box.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) &&
                $0.boundingBox.midY >= box.midY
            }.max { $0.confidence < $1.confidence }
            guard let yaw = face?.yaw?.doubleValue, let pitch = face?.pitch?.doubleValue else {
                return AudiencePerson(id: id, box: box, direction: "Unclear", awaySince: nil, forwardFrames: 0)
            }
            let degrees = 180 / Double.pi
            let away = abs(yaw) * degrees >= 60 || abs(pitch) * degrees >= 60
            let forward = abs(yaw) * degrees <= 40 && abs(pitch) * degrees <= 45
            let awaySince = away ? (match?.awaySince ?? timestamp) : nil
            let forwardFrames = forward ? (match?.forwardFrames ?? 0) + 1 : 0
            let direction: String
            if let awaySince, timestamp - awaySince >= 0.8 { direction = "Facing away" }
            else if forwardFrames >= 2 { direction = "Facing presenter" }
            else { direction = "Unclear" }
            return AudiencePerson(id: id, box: box, direction: direction, awaySince: awaySince, forwardFrames: forwardFrames)
        }
    }

    private func intersection(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return 0 }
        let area = overlap.width * overlap.height
        return area / (a.width * a.height + b.width * b.height - area)
    }

    private func updateSpeech(_ words: [SpokenWord], formatted: String) {
        transcript = formatted
        let tokens = words.flatMap {
            $0.text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let fillers = Set(["um", "uh", "erm", "hmm"])
        let timed = words.filter { $0.duration > 0 }
        let speaking = timed.reduce(0.0) { $0 + $1.duration }
        let gaps = zip(timed, timed.dropFirst()).filter { $1.start - ($0.start + $0.duration) >= 0.8 }
        let span = timed.last.map { $0.start + $0.duration - (timed.first?.start ?? 0) } ?? elapsed
        metrics = SpeakingMetrics(
            wpm: Int((Double(tokens.count) * 60 / max(1, span)).rounded()),
            pauses: gaps.count, fillers: tokens.filter { fillers.contains($0) }.count,
            speakingSeconds: Int(speaking.rounded())
        )
        let second = Int(elapsed)
        if pace.last?.second == second { pace.removeLast() }
        pace.append(PacePoint(second: second, wpm: metrics.wpm))
    }

    func stop() {
        guard isRecording, !finishing else { return }
        finishing = true
        isRecording = false
        isBusy = true
        let duration = elapsed
        stopInputs()
        speechRequest?.endAudio()
        let id = sessionID
        Task {
            defer {
                speechTask?.cancel()
                speechTask = nil
                speechRequest = nil
                writer = nil
                frame = nil
                audience = []
                isBusy = false
                finishing = false
            }
            do {
                guard let writer, writer.hasBothTracks else {
                    writer?.discard()
                    throw StudioError(message.isEmpty ? "Both camera and microphone are required to save a rehearsal." : message)
                }
                try await writer.finish()
                for _ in 0..<15 where speechRequest != nil && !speechFinished {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                var session = PracticeSession(title: cleanTitle.isEmpty ? "Practice session" : cleanTitle,
                                              outline: outline, source: source, duration: duration,
                                              transcript: transcript, metrics: metrics, pace: pace)
                session.id = id
                session.practiceType = practiceType
                try save([session] + sessions)
                message = transcript.isEmpty ? "Recording saved. No transcript was captured." : "Practice session saved."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func stopInputs() {
        watchdog?.cancel()
        recordingDate = nil
        coachingTask?.cancel()
        coachingTask = nil
        coach.stop()
        consent = false
        phone.stop()
        glassesCamera?.stream.stop()
        glassesCamera = nil
        glassesSession?.stop()
        glassesSession = nil
        let listeners = glassesListeners
        glassesListeners.removeAll()
        Task { for listener in listeners { await listener.cancel() } }
    }

    func videoURL(for session: PracticeSession) -> URL { videoURL(for: session.id) }

    private func videoURL(for id: UUID) -> URL {
        storage.appending(path: id.uuidString).appendingPathExtension("mov")
    }

    private func save(_ updated: [PracticeSession]) throws {
        let data = try JSONEncoder().encode(updated)
        try data.write(to: storage.appending(path: "sessions.json"), options: .atomic)
        sessions = updated
    }

    private var backendURL: URL? {
        guard let address = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String,
              let base = URL(string: address), base.scheme == "https", base.host != nil else { return nil }
        return base
    }

    func delete(_ session: PracticeSession) throws {
        try save(sessions.filter { $0.id != session.id })
        let url = videoURL(for: session)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func report(for session: PracticeSession) async throws {
        guard let base = backendURL else {
            throw StudioError("The StageSight report service URL is unavailable.")
        }
        let token = try await accountToken()
        struct Input: Encodable {
            let title: String
            let outline: String
            let transcript: String
            let metrics: SpeakingMetrics
        }
        struct Output: Decodable { let report: String }
        var request = URLRequest(url: base.appending(path: "reports"))
        request.httpMethod = "POST"
        request.timeoutInterval = 100
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Input(title: session.title, outline: session.outline,
                                                         transcript: session.transcript, metrics: session.metrics))
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            let report = try JSONDecoder().decode(Output.self, from: data).report
            var updated = sessions
            guard let index = updated.firstIndex(where: { $0.id == session.id }) else { return }
            updated[index].report = report
            try save(updated)
        case 401: throw StudioError("Your session expired. Sign out and sign in again.")
        case 429: throw StudioError("The report service is busy. Try again in a minute.")
        default: throw StudioError("The report service couldn’t generate feedback right now.")
        }
    }
}

private struct SpokenWord: Sendable {
    let text: String
    let start: Double
    let duration: Double
}

struct StudioError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
