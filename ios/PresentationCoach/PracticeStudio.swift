import FirebaseAuth
import FirebaseCore
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

struct AudienceInterval: Identifiable {
    let start: Int
    let percentFacingCamera: Double
    var id: Int { start }
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
    var isOfficialPresentation: Bool?
    var cloudTranscript: String?
    var cloudTranscriptPending: Bool?
    var cloudTranscriptError: String?
    var reportAfterTranscription: Bool?
    var reportUsesCloudTranscript: Bool?
    var reviewTranscript: String { cloudTranscript ?? transcript }
    var audienceFrames: [AudienceFrame]?
    var audienceDetectorVersion: Int?
}

struct AudienceBox: Identifiable, Codable, Sendable {
    let id: UUID
    let box: CGRect
    let facingCamera: Bool
    // An orange box can also mean there wasn't a clear enough view to confirm direction.
    let measured: Bool
    var label: String { facingCamera ? "Facing presenter" : "Facing away" }
}

struct AudienceFrame: Codable, Sendable {
    let seconds: Double
    let boxes: [AudienceBox]

    static func intervals(for frames: [Self]) -> [AudienceInterval] {
        let windows = Dictionary(grouping: frames.filter { $0.seconds.isFinite && $0.seconds >= 0 }) {
            Int($0.seconds / 10) * 10
        }
        return windows.keys.sorted().compactMap { start in
            guard let window = windows[start] else { return nil }
            let reliable = window.compactMap { frame -> (time: Double, fraction: Double)? in
                let measured = frame.boxes.filter(\.measured)
                guard !measured.isEmpty, Double(measured.count) / Double(frame.boxes.count) >= 0.6 else {
                    return nil
                }
                let forward = measured.count { $0.facingCamera }
                return (frame.seconds, Double(forward) / Double(measured.count))
            }
            guard reliable.count >= 4, Double(reliable.count) / Double(window.count) >= 0.6,
                  let first = reliable.first, let last = reliable.last, last.time - first.time >= 2 else { return nil }
            let average = reliable.reduce(0) { $0 + $1.fraction } / Double(reliable.count)
            return AudienceInterval(start: start, percentFacingCamera: 100 * average)
        }
    }
}

struct AudienceDetector {
    static let version = 2

    private struct Track {
        let id: UUID
        let box: CGRect
        let awaySince: Double?
        let lastFacingEvidence: Double?
    }

    private var tracks: [Track] = []

    mutating func detect(_ handler: VNImageRequestHandler, at time: Double) -> [AudienceBox] {
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = true
        let faces = VNDetectFaceRectanglesRequest()
        do { try handler.perform([people, faces]) }
        catch { tracks = []; return [] }

        let visibleFaces = (faces.results ?? []).filter { $0.confidence >= 0.5 && $0.boundingBox.width >= 0.015 }
        let facesWithoutYaw = visibleFaces.filter { $0.yaw == nil }
        let landmarks = VNDetectFaceLandmarksRequest()
        if !facesWithoutYaw.isEmpty {
            landmarks.inputFaceObservations = facesWithoutYaw
            try? handler.perform([landmarks])
        }

        var bodies = (people.results ?? []).filter { $0.confidence >= 0.45 }.map(\.boundingBox)
        var attached: [Int: VNFaceObservation] = [:]
        for face in visibleFaces.sorted(by: { $0.confidence > $1.confidence }) {
            let rect = face.boundingBox
            let candidates = bodies.indices.filter {
                let body = bodies[$0]
                let head = body.insetBy(dx: -body.width * 0.18, dy: -body.height * 0.35)
                return attached[$0] == nil && head.contains(CGPoint(x: rect.midX, y: rect.midY)) &&
                    rect.midY >= body.minY + 0.35 * body.height
            }
            if let closest = candidates.min(by: { headDistance(rect, bodies[$0]) < headDistance(rect, bodies[$1]) }) {
                attached[closest] = face
            } else {
                // A face can still be visible when the torso is behind a desk or outside the image.
                let visible = rect.insetBy(dx: -rect.width * 0.3, dy: -rect.height * 0.2)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                attached[bodies.count] = face
                bodies.append(visible)
            }
        }

        var remaining = tracks
        var next: [Track] = []
        let boxes = bodies.enumerated().map { index, body in
            let match = remaining.indices.max { overlap(remaining[$0].box, body) < overlap(remaining[$1].box, body) }
            let previous = match.flatMap { overlap(remaining[$0].box, body) >= 0.25 ? remaining.remove(at: $0) : nil }
            let id = previous?.id ?? UUID()
            let face = attached[index]
            let refined = face.flatMap { candidate in
                landmarks.results?.first { overlap($0.boundingBox, candidate.boundingBox) >= 0.65 }
            }
            let yaw = (face?.yaw ?? refined?.yaw)?.doubleValue
            let pitch = (face?.pitch ?? refined?.pitch)?.doubleValue
            let details = refined?.landmarks
            let hasFrontLandmarks = details?.leftEye != nil && details?.rightEye != nil && details?.nose != nil
            let pose = Self.direction(yaw: yaw, pitch: pitch, hasFrontLandmarks: hasFrontLandmarks)
            let awaySince = pose == false ? (previous?.awaySince ?? time) : nil
            let confirmedAway = awaySince.map { time - $0 >= 0.45 } ?? false
            let lastFacing = confirmedAway ? nil : (pose == true ? time : previous?.lastFacingEvidence)
            let recentFacing = lastFacing.map { time - $0 <= 0.9 } ?? false
            let facing = !confirmedAway && recentFacing
            next.append(Track(id: id, box: body, awaySince: awaySince, lastFacingEvidence: lastFacing))
            return AudienceBox(id: id, box: body, facingCamera: facing, measured: pose == true || confirmedAway)
        }
        tracks = next
        return boxes
    }

    // Vision reports pose in radians. Moderate pitch is normal when the camera is below eye level.
    static func direction(yaw: Double?, pitch: Double?, hasFrontLandmarks: Bool) -> Bool? {
        let tilt = abs(pitch ?? 0) * 180 / .pi
        if let yaw, yaw.isFinite {
            let turn = abs(yaw) * 180 / .pi
            if turn >= 55 || tilt >= 65 { return false }
            if turn <= 44 && tilt <= 60 { return true }
            return nil
        }
        return hasFrontLandmarks && tilt <= 60 ? true : nil
    }

    private func headDistance(_ face: CGRect, _ person: CGRect) -> CGFloat {
        abs(face.midX - person.midX) / person.width + abs(face.midY - person.maxY) / person.height
    }

    private func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        return area / (lhs.width * lhs.height + rhs.width * rhs.height - area)
    }
}

@MainActor
final class PracticeStudio: ObservableObject {
    @Published private(set) var lastSavedSessionID: UUID?
    @Published var title = ""
    @Published var outline = ""
    @Published var source = CaptureSource.phone
    @Published var practiceType = "Pitch practice"
    @Published var consent = false
    @Published var overlays = true
    private var audienceFrames: [AudienceFrame] = []
    private var audienceDetector = AudienceDetector()
    @Published var speechEnabled = true
    @Published var liveEnabled = true
    @Published var glassesLiveEnabled = true

    var liveCoachingEnabled: Bool {
        source == .glasses ? glassesLiveEnabled : liveEnabled
    }

    var liveCoachingSetting: ReferenceWritableKeyPath<PracticeStudio, Bool> {
        source == .glasses ? \.glassesLiveEnabled : \.liveEnabled
    }
    @Published var autoReport = true
    private var transcriptionsInProgress: Set<UUID> = []
    @Published private(set) var reportsInProgress: Set<UUID> = []
    @Published private(set) var reportErrors: [UUID: String] = [:]
    @Published var useFrontCamera = false
    @Published private(set) var accountEmail: String?
    @Published private(set) var username: String?
    private var accountSession: AccountSession?
    private var accountGeneration = UUID()

    private let authPublishableKey = "sb_publishable_k8JR4vZnwCvnnXVRboSXgA_3CYgDIE6"
    private let authBase = URL(string: "https://ezstwuzfupvsdiuzvdvv.supabase.co/auth/v1/")!

    var usesFirebaseAccount: Bool { accountSession == nil && accountEmail != nil }

    private func configureFirebase() {
        guard FirebaseApp.app() == nil,
              let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist", inDirectory: "Firebase"),
              let options = FirebaseOptions(contentsOfFile: path),
              options.projectID == "stagesight-ccf4a",
              options.bundleID == Bundle.main.bundleIdentifier else { return }
        FirebaseApp.configure(options: options)
    }

    func signIn(with credential: AuthCredential) async throws {
        guard FirebaseApp.app() != nil else {
            throw StudioError("Google sign-in is unavailable in this build.")
        }
        let result = try await Auth.auth().signIn(with: credential)
        accountEmail = result.user.email ?? "StageSight account"
        username = result.user.displayName
    }

    private struct AccountUser: Codable {
        let email: String?
        struct Metadata: Codable { let username: String? }
        let user_metadata: Metadata?
    }

    private struct AccountSession: Codable {
        let user: AccountUser?
        let access_token: String
        let refresh_token: String
        let expires_in: Double
    }
    private struct SavedAccount: Codable {
        let session: AccountSession
        let email: String
        let expiresAt: Date
        let username: String?
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
        username = saved.username ?? saved.session.user?.user_metadata?.username
        accountExpiresAt = saved.expiresAt
    }

    func signIn(email: String, password: String) async throws {
        let session = try await requestAccount(grant: "password", fields: ["email": email, "password": password])
        try setAccount(session, email: email)
    }

    func signOut() {
        if usesFirebaseAccount {
            do { try Auth.auth().signOut() }
            catch {
                message = "Couldn’t sign out. Try again."
                return
            }
        }
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
        username = nil
    }

    private func setAccount(_ session: AccountSession, email: String, username suppliedName: String? = nil, expiry: Date? = nil) throws {
        let expiry = expiry ?? Date().addingTimeInterval(session.expires_in)
        let name = suppliedName ?? session.user?.user_metadata?.username
        let data = try JSONEncoder().encode(SavedAccount(session: session, email: email, expiresAt: expiry, username: name))
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
        username = name
        accountExpiresAt = expiry
    }

    private func accountToken() async throws -> String {
        if usesFirebaseAccount, let user = Auth.auth().currentUser {
            return try await user.getIDToken()
        }
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
    func createAccount(email: String, password: String, username: String) async throws -> Bool {
        let name = try validatedUsername(username)
        let (data, status) = try await accountResponse(
            path: "signup", fields: ["email": email, "password": password, "data": ["username": name]]
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
            try setAccount(session, email: email, username: name)
            return false
        }
        return true
    }

    private func validatedUsername(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name.range(of: #"^[a-z0-9_]{3,24}$"#, options: .regularExpression) != nil else {
            throw StudioError("Use 3 to 24 letters, numbers, or underscores.")
        }
        return name
    }

    func updateUsername(_ input: String) async throws {
        let name = try validatedUsername(input)
        if usesFirebaseAccount, let user = Auth.auth().currentUser {
            let profile = user.createProfileChangeRequest()
            profile.displayName = name
            try await profile.commitChanges()
            guard Auth.auth().currentUser?.uid == user.uid else { return }
            username = name
            return
        }
        let generation = accountGeneration
        let token = try await accountToken()
        let (data, status) = try await accountResponse(
            path: "user", fields: ["data": ["username": name]], method: "PUT", token: token
        )
        guard status == 200,
              let user = try? JSONDecoder().decode(AccountUser.self, from: data),
              let savedName = user.user_metadata?.username else {
            throw StudioError("Couldn’t save your username. Try again.")
        }
        guard generation == accountGeneration, let session = accountSession, let email = accountEmail else {
            throw StudioError("Sign in again to update your username.")
        }
        try setAccount(session, email: email, username: savedName, expiry: accountExpiresAt)
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

    private func accountResponse(path: String, fields: [String: Any], method: String = "POST", token: String? = nil) async throws -> (Data, Int) {
        let url = URL(string: path, relativeTo: authBase)!.absoluteURL
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 20
        request.setValue(authPublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
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
    @Published private(set) var audience: [AudienceBox] = []
    @Published private(set) var transcript = ""
    private var speechWords: [SpokenWord] = []
    private var committedSpeech: [SpokenWord] = []
    private var committedTranscript = ""
    private var speechTail = ""
    @Published private(set) var metrics = SpeakingMetrics()
    @Published private(set) var sessions: [PracticeSession] = []

    private let storage = URL.applicationSupportDirectory.appending(path: "StageSight")
    private let phone = PhoneCapture()
    private var recordingIsOfficial = false
    private let coach = LiveCoach()
    private var coachingTask: Task<Void, Never>?
    private let images = CIContext()
    @Published var speechLocale = ""
    lazy var speechLocales = SFSpeechRecognizer.supportedLocales()
        .filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
        .sorted { $0.identifier < $1.identifier }
    private var activeRecognizer: SFSpeechRecognizer?
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
    private var glassesSelector: AutoDeviceSelector?
    private var glassesSession: DeviceSession?
    private var glassesCamera: MWDATCamera.Camera?
    private var glassesListeners: [any AnyListenerToken] = []
    private var watchdog: Task<Void, Never>?
    private var finishing = false

    init() {
        restoreAccount()
        configureFirebase()
        if accountEmail == nil, FirebaseApp.app() != nil, let user = Auth.auth().currentUser {
            accountEmail = user.email ?? "StageSight account"
            username = user.displayName
        }
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
        guard url.scheme == "stagesight", url.host != "auth" else { return }
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
            glassesSelector = AutoDeviceSelector(wearables: Wearables.shared)
            wearablesConfigured = true
        }
        return Wearables.shared
    }

    func start(official: Bool) async {
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
            writer = try SessionMovie(url: videoURL(for: sessionID), glasses: selected == .glasses)
            started = ProcessInfo.processInfo.systemUptime
            transcript = ""
            speechWords = []
            committedSpeech = []
            committedTranscript = ""
            speechTail = ""
            metrics = SpeakingMetrics()
            pace = []
            audience = []
            audienceFrames = []
            audienceDetector = AudienceDetector()
            frame = nil
            lastAnalysis = -1
            lastPreview = -1
            let recognizer = speechLocale.isEmpty
                ? SFSpeechRecognizer()
                : SFSpeechRecognizer(locale: Locale(identifier: speechLocale))
            if speechAllowed, let recognizer, recognizer.supportsOnDeviceRecognition, recognizer.isAvailable {
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = true
                request.addsPunctuation = true
                let context = ([title] + outline.components(separatedBy: .newlines))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0.count <= 80 }
                request.contextualStrings = Array(context.prefix(30))
                activeRecognizer = recognizer
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
                        if let words, let formatted, !words.isEmpty { self.updateSpeech(words, formatted: formatted, isFinal: finished) }
                        if finished { self.speechFinished = true }
                        if failed && !self.finishing {
                            self.message = "Live transcription stopped. Video and audio recording are still active."
                        }
                    }
                }
            } else if speechEnabled {
                message = "On-device transcription is unavailable. Camera and microphone recording can continue."
            }
            recordingIsOfficial = official
            recordingDate = selected == .glasses ? nil : Date()
            isRecording = true
            coachingCue = ""
            if liveCoachingEnabled, backendURL == nil {
                coachingCue = "The live coaching server URL is missing."
            }
            if liveCoachingEnabled, accountEmail != nil, let base = backendURL {
                coachingCue = "Connecting live coaching…"
                coachingTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let firebase = self.usesFirebaseAccount
                        let token = try await self.accountToken()
                        try await self.coach.start(base: base, token: token, official: official, firebase: firebase) { [weak self] cue in
                            self?.coachingCue = cue
                        }
                    } catch {
                        if !Task.isCancelled { self.coachingCue = error.localizedDescription }
                    }
                }
            }
            if selected == .phone {
                try await phone.start(
                    position: useFrontCamera ? .front : .back,
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
            guard isRecording else { return }
            watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.isRecording,
                      self.writer?.hasBothTracks != true else { return }
                if let failure = self.writer?.recordingError {
                    if selected == .glasses, self.frame != nil {
                        self.stopFailedGlassesRecording()
                        return
                    }
                    self.message = failure.localizedDescription
                } else if selected == .glasses {
                    if self.frame != nil {
                        return
                    } else if self.writer?.hasAudio == true {
                        self.message = "StageSight received glasses microphone audio, but no camera video arrived."
                    } else {
                        self.message = "StageSight found the glasses, but no camera video or microphone audio arrived."
                    }
                } else {
                    self.message = "StageSight couldn’t receive both iPhone camera and microphone."
                }
                self.stop()
            }
        } catch {
            stopInputs()
            speechTask?.cancel()
            speechTask = nil
            speechRequest = nil
            activeRecognizer = nil
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
        guard let selector = glassesSelector else {
            throw StudioError("Couldn’t start Meta glasses discovery.")
        }
        // The selector can still be waiting for the first device update after setup.
        for _ in 0..<40 {
            if selector.activeDevice != nil || !isRecording { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard isRecording else { return }
        guard selector.activeDevice != nil else {
            throw StudioError("Meta AI setup is complete, but StageSight couldn’t find an active pair of glasses. Wake the glasses and check their connection in Meta AI, then try again.")
        }
        for permission in [Permission.camera, .microphone] {
            if try await wearables.checkPermissionStatus(permission) != .granted {
                guard try await wearables.requestPermission(permission) == .granted else {
                    throw StudioError("Allow the glasses camera and microphone in Meta AI.")
                }
            }
        }
        guard isRecording else { return }
        guard selector.activeDevice != nil else {
            throw StudioError("The glasses disconnected while checking camera and microphone access. Reconnect them in Meta AI and try again.")
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
                guard let self, self.glassesCamera?.stream === stream, self.isRecording, self.recordingDate != nil else { return }
                self.speechRequest?.append(audio.pcmBuffer)
                self.coach.append(audio.pcmBuffer)
                self.writer?.appendGlassesAudio(audio.pcmBuffer, elapsed: self.elapsed)
                if self.writer?.recordingError != nil { self.stopFailedGlassesRecording() }
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
        guard isRecording, CMSampleBufferDataIsReady(sample) else { return }
        let firstGlassesFrame = glasses && recordingDate == nil
        if firstGlassesFrame {
            guard video, CMSampleBufferGetImageBuffer(sample) != nil else { return }
            started = ProcessInfo.processInfo.systemUptime
            recordingDate = Date()
        }
        let now = firstGlassesFrame ? 0 : elapsed
        let previousVideoTime = writer?.latestVideoSeconds
        writer?.append(sample, video: video, elapsed: glasses ? now : nil)
        if glasses, writer?.recordingError != nil { stopFailedGlassesRecording(); return }
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
        if overlays, let seconds = writer?.latestVideoSeconds, seconds != previousVideoTime,
           seconds.isFinite, seconds >= 0, seconds - lastAnalysis >= 0.25 {
            lastAnalysis = seconds
            audience = audienceDetector.detect(VNImageRequestHandler(cvPixelBuffer: buffer), at: seconds)
            audienceFrames.append(AudienceFrame(seconds: seconds, boxes: audience))
        }
    }

    func analyzeSavedAudience(in session: PracticeSession) async throws {
        let url = videoURL(for: session)
        let frames = try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw StudioError("This video has no readable duration.") }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.125, preferredTimescale: 600)
            var detector = AudienceDetector()
            var frames: [AudienceFrame] = []
            for seconds in stride(from: 0.0, to: duration, by: 0.25) {
                if let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                    let time = image.actualTime.seconds
                    if time.isFinite, time >= 0, time > (frames.last?.seconds ?? -1) {
                        let boxes = detector.detect(VNImageRequestHandler(cgImage: image.image), at: time)
                        frames.append(AudienceFrame(seconds: time, boxes: boxes))
                    }
                }
            }
            return frames
        }.value
        guard !frames.isEmpty else { throw StudioError("StageSight couldn’t read the recording to add audience boxes.") }
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        var updated = sessions
        updated[index].audienceFrames = frames
        updated[index].audienceDetectorVersion = AudienceDetector.version
        try save(updated)
    }

    private func updateSpeech(_ words: [SpokenWord], formatted: String, isFinal: Bool) {
        let previousTokens = speechTokens(speechTail)
        let nextTokens = speechTokens(formatted)
        guard !nextTokens.isEmpty else { return }
        let shorter = nextTokens.count < previousTokens.count
        if shorter, previousTokens.suffix(nextTokens.count).elementsEqual(nextTokens) ||
            previousTokens.prefix(nextTokens.count).elementsEqual(nextTokens) { return }

        // A recognition window can slide forward even when its new text is longer.
        if let previousStart = speechWords.first(where: { $0.duration > 0 })?.start,
           let nextStart = words.first(where: { $0.duration > 0 })?.start,
           nextStart > previousStart + 0.2,
           !previousTokens.prefix(2).elementsEqual(nextTokens.prefix(2)) {
            let prefix = speechWords.prefix { $0.start < nextStart - 0.05 }
            committedSpeech.append(contentsOf: prefix)
            if !prefix.isEmpty {
                committedTranscript += prefix.map(\.text).joined(separator: " ") + " "
            }
        } else if shorter {
            let overlap = (0...nextTokens.count).reversed().first {
                previousTokens.suffix($0).elementsEqual(nextTokens.prefix($0))
            } ?? 0
            if overlap == 0 {
                if isFinal || finishing { return }
                committedSpeech.append(contentsOf: speechWords)
                committedTranscript += speechTail + " "
            } else {
                let prefix = speechWords.dropLast(min(overlap, speechWords.count))
                committedSpeech.append(contentsOf: prefix)
                committedTranscript += prefix.map(\.text).joined(separator: " ") + " "
            }
        }
        speechWords = words
        speechTail = formatted
        transcript = committedTranscript + formatted
        let allWords = committedSpeech + words
        let tokens = allWords.flatMap {
            $0.text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let fillers = Set(["um", "uh", "erm", "hmm"])
        let timed = allWords.filter { $0.duration > 0 }
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

    private func speechTokens(_ text: String) -> [Substring] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }
    }

    private func stopFailedGlassesRecording() {
        // Surface the actual encoder error instead of silently discarding the movie.
        message = "Glasses recording stopped: \(writer?.recordingError?.localizedDescription ?? "Video encoding failed.")"
        stop()
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
                activeRecognizer = nil
                writer = nil
                frame = nil
                audience = []
                isBusy = false
                finishing = false
            }
            do {
                guard let writer, source == .glasses || writer.hasBothTracks else {
                    writer?.discard()
                    throw StudioError(message.isEmpty ? "Both camera and microphone are required to save a rehearsal." : message)
                }
                try await writer.finish(allowVideoOnly: source == .glasses)
                for _ in 0..<15 where speechRequest != nil && !speechFinished {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                var session = PracticeSession(title: cleanTitle.isEmpty ? "Practice session" : cleanTitle,
                                              outline: outline, source: source, duration: duration,
                                              transcript: transcript, metrics: metrics, pace: pace)
                session.id = id
                session.practiceType = practiceType
                session.isOfficialPresentation = recordingIsOfficial
                session.audienceFrames = overlays ? audienceFrames : nil
                session.audienceDetectorVersion = overlays ? AudienceDetector.version : nil
                let shouldTranscribe = speechEnabled && writer.hasAudio && accountEmail != nil
                session.cloudTranscriptPending = shouldTranscribe ? true : nil
                session.reportAfterTranscription = shouldTranscribe ? autoReport : nil
                try save([session] + sessions)
                lastSavedSessionID = session.id
                if shouldTranscribe {
                    Task { await finishTranscript(for: session.id) }
                } else if autoReport, accountEmail != nil, !session.transcript.isEmpty {
                    Task { await report(for: session) }
                }
                if !writer.hasAudio {
                    message = "Video saved. No microphone audio was recorded."
                } else {
                    message = transcript.isEmpty ? "Recording saved. No transcript was captured." : "Practice session saved."
                }
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

    func finishTranscript(for id: UUID) async {
        guard let session = sessions.first(where: { $0.id == id && $0.cloudTranscriptPending == true }),
              transcriptionsInProgress.insert(id).inserted else { return }
        defer { transcriptionsInProgress.remove(id) }

        var transcript: String?
        var failure: String?
        do { transcript = try await transcribeAudio(for: session) }
        catch { failure = error.localizedDescription }

        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var updated = sessions
        updated[index].cloudTranscript = transcript
        updated[index].cloudTranscriptError = failure
        updated[index].cloudTranscriptPending = false
        do { try save(updated) }
        catch { return }

        if session.reportAfterTranscription == true, !updated[index].reviewTranscript.isEmpty {
            await report(for: updated[index])
        }
    }

    private func transcribeAudio(for session: PracticeSession) async throws -> String {
        guard let base = backendURL else { throw StudioError("The StageSight transcription service is unavailable.") }
        let firebase = usesFirebaseAccount
        let token = try await accountToken()
        let asset = AVURLAsset(url: videoURL(for: session))
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw StudioError("This recording has no audio to transcribe.")
        }
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        exporter.outputURL = audio
        exporter.outputFileType = .m4a
        await exporter.export()
        guard exporter.status == .completed else { throw StudioError("StageSight couldn’t prepare the recorded audio.") }
        let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 24_000_000 else { throw StudioError("This recording is too long for cloud transcription.") }

        var request = URLRequest(url: base.appending(path: "transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if firebase { request.setValue("firebase", forHTTPHeaderField: "X-StageSight-Auth") }
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: audio)
        struct Output: Decodable { let transcript: String?; let error: String? }
        let result = try? JSONDecoder().decode(Output.self, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200, let transcript = result?.transcript, !transcript.isEmpty else {
            let message = status == 404 ? "Cloud transcription is unavailable on this server." : result?.error
            throw StudioError(message ?? "StageSight couldn’t transcribe this recording right now.")
        }
        return transcript
    }

    func report(for session: PracticeSession) async {
        guard let current = sessions.first(where: { $0.id == session.id && $0.report == nil }),
              reportsInProgress.insert(session.id).inserted else { return }
        reportErrors[session.id] = nil
        defer { reportsInProgress.remove(session.id) }
        do { try await requestReport(for: current) }
        catch { reportErrors[session.id] = error.localizedDescription }
    }

    private func requestReport(for session: PracticeSession) async throws {
        guard let base = backendURL else {
            throw StudioError("The StageSight report service URL is unavailable.")
        }
        let firebase = usesFirebaseAccount
        let token = try await accountToken()
        struct Input: Encodable {
            let title: String
            let outline: String
            let transcript: String
            let metrics: SpeakingMetrics
            let official: Bool
        }
        struct Output: Decodable { let report: String }
        var request = URLRequest(url: base.appending(path: "reports"))
        request.httpMethod = "POST"
        request.timeoutInterval = 100
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if firebase { request.setValue("firebase", forHTTPHeaderField: "X-StageSight-Auth") }
        request.httpBody = try JSONEncoder().encode(Input(title: session.title, outline: session.outline,
                                                         transcript: session.reviewTranscript, metrics: session.metrics,
                                                         official: session.isOfficialPresentation == true))
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            let report = try JSONDecoder().decode(Output.self, from: data).report
            var updated = sessions
            guard let index = updated.firstIndex(where: { $0.id == session.id }) else { return }
            updated[index].report = report
            updated[index].reportUsesCloudTranscript = session.cloudTranscript != nil
            try save(updated)
        case 401, 403:
            throw StudioError(firebase
                ? "The coaching server couldn’t verify Google sign-in. Your recording and on-device analysis are available."
                : "Your session expired. Sign out and sign in again.")
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
