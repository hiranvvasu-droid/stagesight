import SwiftUI
import AVKit
import Charts

@main
struct PresentationCoachApp: App {
    @StateObject private var studio = PracticeStudio()

    var body: some Scene {
        WindowGroup {
            Workspace(studio: studio)
                .onOpenURL { url in Task { await studio.handle(url) } }
                .preferredColorScheme(.light)
                .sheet(isPresented: $studio.showSignIn) { AccountSignIn(studio: studio) }
        }
    }
}

private struct Workspace: View {
    @ObservedObject var studio: PracticeStudio
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var showControls = false
    private let ink = Color(red: 0.15, green: 0.23, blue: 0.19)
    private let green = Color(red: 0.23, green: 0.39, blue: 0.30)
    private let paper = Color(red: 0.96, green: 0.97, blue: 0.95)
    private let sage = Color(red: 0.91, green: 0.93, blue: 0.88)

    var body: some View {
        TabView(selection: $tab) {
            page("Overview") { overview }
                .tabItem { Label("Overview", systemImage: "square.grid.2x2") }.tag(0)
            page("Practice studio") { practice }
                .tabItem { Label("Practice", systemImage: "record.circle") }.tag(1)
            page("My sessions") { library }
                .tabItem { Label("My sessions", systemImage: "rectangle.stack") }.tag(2)
        }
        .tint(green)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, studio.isRecording { studio.stop() }
        }
    }

    private func page<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20, content: content)
                    .frame(maxWidth: 620)
                    .padding(20)
                    .frame(maxWidth: .infinity)
            }
            .background(paper)
            .foregroundStyle(ink)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Label("StageSight", systemImage: "record.circle").font(.headline).foregroundStyle(ink)
                }
            }
        }
    }

    private var overview: some View {
        Group {
            Text("Find your voice.\nOwn your stage.").font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("A space to practice, reflect, and grow into your next great presentation.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 58)).foregroundStyle(green)
                    .accessibilityHidden(true)
                Text("Great presentations begin with practice.").font(.title2.bold())
                Button { tab = 1 } label: {
                    Label("Start a practice session", systemImage: "arrow.up.right")
                }.buttonStyle(.borderedProminent)
            }.card(sage)
            HStack(alignment: .top, spacing: 12) {
                metric("Practice sessions", studio.sessions.count.formatted())
                metric("Time well spent", "\(Int(studio.sessions.reduce(0) { $0 + $1.duration } / 60)) min")
            }
            if let email = studio.accountEmail {
                VStack(alignment: .leading, spacing: 8) {
                    Text(email).font(.subheadline)
                    Button("Sign out") { studio.signOut() }.disabled(studio.isRecording || studio.isBusy)
                }.card(.white)
            } else {
                Button("Sign in for AI coaching") { studio.showSignIn = true }.buttonStyle(.bordered)
            }
            Text("Your recordings").font(.title2.bold())
            if studio.sessions.isEmpty {
                Text("Record your first practice session to see it here.").card(.white)
            } else {
                Button("View all sessions") { tab = 2 }.buttonStyle(.bordered)
            }
        }
    }

    private var practice: some View {
        Group {
            if !studio.isRecording || showControls {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Presentation title", text: $studio.title).textFieldStyle(.roundedBorder)
                    TextField("Outline or talking points", text: $studio.outline, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...5)
                    Picker("Capture source", selection: $studio.source) {
                        ForEach(CaptureSource.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Practice type", selection: $studio.practiceType) {
                        ForEach(["Pitch practice", "Product walkthrough", "Storytelling", "Keynote"], id: \.self) {
                            Text($0)
                        }
                    }
                    Toggle("Audience direction overlays", isOn: $studio.overlays)
                    Toggle("On-device transcription", isOn: $studio.speechEnabled)
                    Toggle("Live AI coaching", isOn: $studio.liveEnabled)
                    if studio.liveEnabled {
                        Text("Live coaching sends audio from your selected microphone to OpenAI.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if studio.accountEmail == nil {
                            Button("Sign in to enable coaching") { studio.showSignIn = true }
                        }
                    }
                    Toggle("Everyone being recorded knows and has agreed", isOn: $studio.consent)
                    if studio.source == .glasses {
                        Button("Connect Meta glasses") { Task { await studio.register() } }
                    }
                }.disabled(studio.isRecording || studio.isBusy).card(.white)
            }
            if let frame = studio.frame {
                GeometryReader { geometry in
                    let scale = min(geometry.size.width / frame.size.width, geometry.size.height / frame.size.height)
                    let width = frame.size.width * scale
                    let height = frame.size.height * scale
                    let left = (geometry.size.width - width) / 2
                    let top = (geometry.size.height - height) / 2
                    Image(uiImage: frame).resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    ForEach(studio.audience) { person in
                        let box = person.box
                        Rectangle().strokeBorder(.white, lineWidth: 2)
                            .overlay(alignment: .top) {
                                Text(person.direction).font(.caption2.bold())
                                    .foregroundStyle(.white).padding(3).background(.black.opacity(0.8))
                            }
                            .frame(width: box.width * width, height: box.height * height)
                            .position(x: left + box.midX * width, y: top + (1 - box.midY) * height)
                    }
                }.frame(height: 300).background(.black).clipShape(.rect(cornerRadius: 18))
                    .accessibilityLabel("Live camera preview")
                Text("\(studio.audience.count) visible · \(studio.audience.filter { $0.direction != "Unclear" }.count) with direction estimates")
                    .font(.caption)
            }
            if studio.isRecording {
                if let date = studio.recordingDate {
                    Label { Text(date, style: .timer).monospacedDigit() } icon: {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    }.accessibilityLabel("Recording elapsed time")
                }
                if !studio.coachingCue.isEmpty { Text(studio.coachingCue).card(sage) }
                HStack(spacing: 8) {
                    metric("Words per minute", studio.metrics.wpm.formatted())
                    metric("Pauses", studio.metrics.pauses.formatted())
                    metric("Est. fillers", studio.metrics.fillers.formatted())
                }
                if !studio.transcript.isEmpty {
                    Text(studio.transcript).frame(maxWidth: .infinity, alignment: .leading).card(.white)
                }
                Button(showControls ? "Hide controls" : "Show controls") { showControls.toggle() }
            }
            if !studio.message.isEmpty {
                Text(studio.message).font(.callout).foregroundStyle(.secondary)
            }
            Button {
                if studio.isRecording { studio.stop() }
                else { showControls = false; Task { await studio.start() } }
            } label: {
                Label(studio.isRecording ? "Stop and save" : "Start recording",
                      systemImage: studio.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(studio.isBusy || (!studio.isRecording && (!studio.consent || (studio.liveEnabled && studio.accountEmail == nil))))
            if !studio.isRecording && !studio.sessions.isEmpty {
                Button("Review your sessions") { tab = 2 }
            }
        }
    }

    private var library: some View {
        Group {
            if studio.sessions.isEmpty {
                ContentUnavailableView("No recordings yet", systemImage: "rectangle.stack",
                                       description: Text("Your saved practice sessions appear here."))
                Button("Open practice studio") { tab = 1 }.buttonStyle(.borderedProminent)
            }
            if studio.sessions.count > 1 {
                Chart(Array(studio.sessions.reversed().enumerated()), id: \.element.id) { entry in
                    BarMark(x: .value("Session", "\(entry.offset + 1)"),
                            y: .value("Words per minute", entry.element.metrics.wpm))
                        .foregroundStyle(green)
                }.frame(height: 135).card(.white)
                Text("Speaking pace across sessions").font(.caption)
            }
            ForEach(studio.sessions) { session in
                NavigationLink {
                    SessionReview(session: session, studio: studio)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.title).font(.headline)
                        Text("\(session.date.formatted(date: .abbreviated, time: .shortened)) · \(session.source.rawValue)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.card(.white)
                }.buttonStyle(.plain)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
        }.card(.white)
    }
}

private struct SessionReview: View {
    let session: PracticeSession
    @ObservedObject var studio: PracticeStudio
    @State private var player: AVPlayer?
    @State private var output = ""
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var error = ""
    @State private var generating = false

    private var current: PracticeSession { studio.sessions.first { $0.id == session.id } ?? session }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let player {
                    VideoPlayer(player: player).frame(height: 250)
                    Button("Play recording") {
                        try? AVAudioSession.sharedInstance().setCategory(.playback)
                        player.play()
                        output = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ")
                    }
                    if !output.isEmpty { Text("Audio output: \(output)").font(.caption) }
                    ShareLink(item: studio.videoURL(for: session)) { Label("Share recording", systemImage: "square.and.arrow.up") }
                }
                Text("\(session.metrics.wpm) WPM · \(session.metrics.pauses) pauses · \(session.metrics.fillers) estimated fillers")
                    .font(.subheadline)
                if !session.pace.isEmpty {
                    Chart(session.pace) { point in
                        LineMark(x: .value("Seconds", point.second), y: .value("Words per minute", point.wpm))
                        PointMark(x: .value("Seconds", point.second), y: .value("Words per minute", point.wpm))
                    }.frame(height: 120)
                }
                Text("Transcript").font(.headline)
                Text(session.transcript.isEmpty ? "No transcript was captured. Your recording is saved." : session.transcript)
                    .textSelection(.enabled)
                Text("Coaching report").font(.headline)
                if let report = current.report {
                    Text(report).textSelection(.enabled)
                } else if !session.transcript.isEmpty {
                    Text("Generating a report sends your transcript and speaking metrics to StageSight’s cloud service.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if studio.accountEmail == nil {
                        Button("Sign in to generate a report") { studio.showSignIn = true }
                    }
                    Button(generating ? "Generating…" : "Generate report") {
                        generating = true
                        Task {
                            defer { generating = false }
                            do { try await studio.report(for: session); error = "" }
                            catch { self.error = error.localizedDescription }
                        }
                    }.buttonStyle(.borderedProminent).disabled(generating || studio.accountEmail == nil)
                }
                Button("Delete recording", role: .destructive) { confirmDelete = true }
                if !error.isEmpty { Text(error).font(.callout) }
            }.padding(20)
        }
        .navigationTitle(session.title)
        .confirmationDialog("Delete this practice session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete recording", role: .destructive) {
                player?.pause()
                do { try studio.delete(session); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        }
        .onAppear { player = AVPlayer(url: studio.videoURL(for: session)) }
        .onDisappear { player?.pause(); player = nil }
    }
}

private extension View {
    func card(_ color: Color) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.black.opacity(0.07)) }
    }
}


private struct AccountSignIn: View {
    @ObservedObject var studio: PracticeStudio
    @State private var email = ""
    @State private var password = ""
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Text("Use the same email and password as StageSight on the web.")
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password).textContentType(.password)
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
                Button(busy ? "Signing in…" : "Sign in") {
                    busy = true
                    Task {
                        defer { password = ""; busy = false }
                        do {
                            try await studio.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                        } catch { message = error.localizedDescription }
                    }
                }.disabled(busy || email.isEmpty || password.isEmpty)
            }
            .navigationTitle("StageSight account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { studio.showSignIn = false }.disabled(busy)
                }
            }
        }.interactiveDismissDisabled(busy)
    }
}
