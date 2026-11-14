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
    @State private var showOptions = false
    @Environment(\.openURL) private var openURL
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
        .font(stageBody(15, .body))
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, studio.isRecording { studio.stop() }
            if phase == .active, tab == 1 { studio.refreshGlassesRegistration() }
        }
        .onChange(of: tab) { _, value in
            if value == 1 { studio.refreshGlassesRegistration() }
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
                ToolbarItem(placement: .topBarLeading) {
                    Label("StageSight", systemImage: "record.circle.fill")
                        .font(stageHeading(19, .headline)).foregroundStyle(ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let email = studio.accountEmail {
                        Menu {
                            Text(email)
                            Button("Sign out", role: .destructive) { studio.signOut() }
                                .disabled(studio.isRecording || studio.isBusy)
                        } label: {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title3).foregroundStyle(green)
                                .accessibilityLabel("StageSight account")
                        }
                    } else {
                        Button("Sign in") { studio.showSignIn = true }
                            .font(stageBody(14, .subheadline).weight(.semibold))
                            .foregroundStyle(green)
                    }
                }
            }
        }
    }

    private var overview: some View {
        Group {
            Text("Find your voice.\nOwn your stage.").font(stageHeading(34, .largeTitle))
                .accessibilityAddTraits(.isHeader)
            Text("A space to practice, reflect, and grow into your next great presentation.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 58)).foregroundStyle(green)
                    .accessibilityHidden(true)
                Text("Great presentations begin with practice.").font(stageHeading(22, .title2))
                Button { tab = 1 } label: {
                    Label("Start a practice session", systemImage: "arrow.up.right")
                }.buttonStyle(.borderedProminent)
            }.card(sage)
            HStack(alignment: .top, spacing: 12) {
                metric("Practice sessions", studio.sessions.count.formatted())
                metric("Time well spent", "\(Int(studio.sessions.reduce(0) { $0 + $1.duration } / 60)) min")
            }
            Text("Your recordings").font(stageHeading(22, .title2))
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
                VStack(alignment: .leading, spacing: 9) {
                    Text("PRACTICE STUDIO").font(stageBody(11, .caption).weight(.semibold))
                        .tracking(1.8).foregroundStyle(green)
                    Text("Take a breath.\nYou’ve got this.").font(stageHeading(34, .largeTitle))
                        .accessibilityAddTraits(.isHeader)
                    Text("Choose how to capture your rehearsal.").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Capture source").font(stageHeading(20, .title3))
                    sourceCard(.glasses, icon: "eyeglasses", subtitle: "Hands-free video and audio")
                    sourceCard(.phone, icon: "iphone", subtitle: "This iPhone’s camera and microphone")
                    if studio.source == .glasses {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(studio.glassesRegistered ? "Meta AI setup complete" : "First time using Meta glasses?",
                                  systemImage: studio.glassesRegistered ? "checkmark.circle.fill" : "link.circle")
                                .font(stageHeading(16, .headline)).foregroundStyle(green)
                            if !studio.glassesRegistered {
                                Text("Finish setup in Meta AI, then return to StageSight.")
                                    .font(stageBody(13, .footnote)).foregroundStyle(.secondary)
                                Button {
                                    Task { await studio.register() }
                                } label: {
                                    Label("Set up in Meta AI", systemImage: "arrow.up.right")
                                }.buttonStyle(.bordered)
                            }
                        }.card(sage)
                    }
                }.disabled(studio.isRecording || studio.isBusy)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Session setup").font(stageHeading(20, .title3))
                    TextField("Presentation title", text: $studio.title).stageField()
                    TextField("Outline or talking points", text: $studio.outline, axis: .vertical)
                        .lineLimit(2...5).stageField()
                    Picker("Practice type", selection: $studio.practiceType) {
                        ForEach(["Pitch practice", "Product walkthrough", "Storytelling", "Keynote"], id: \.self) {
                            Text($0)
                        }
                    }
                    Divider()
                    DisclosureGroup("Coaching and overlays", isExpanded: $showOptions) {
                        VStack(alignment: .leading, spacing: 13) {
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
                        }.padding(.top, 12)
                    }
                }.disabled(studio.isRecording || studio.isBusy).card(.white)
                Toggle("Everyone being recorded knows and has agreed", isOn: $studio.consent)
                    .font(stageBody(14, .subheadline))
                    .disabled(studio.isRecording || studio.isBusy).card(.white)
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
                VStack(alignment: .leading, spacing: 8) {
                    Label(studio.message, systemImage: "info.circle").font(.callout)
                    if studio.message.contains("in Settings"), let settings = URL(string: UIApplication.openSettingsURLString) {
                        Button("Open Settings") { openURL(settings) }.font(.callout.bold())
                    }
                }.card(sage)
            }
            Button {
                if studio.isRecording { studio.stop() }
                else { showControls = false; Task { await studio.start() } }
            } label: {
                Label(studio.isBusy ? (studio.isRecording ? "Connecting camera…" : "Please wait…") : (studio.isRecording ? "Stop and save" : "Start recording"),
                      systemImage: studio.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(studio.isBusy)
            if !studio.isRecording && !studio.consent {
                Text("Confirm recording consent above to start.").font(.footnote).foregroundStyle(.secondary)
            }
            if !studio.isRecording && !studio.sessions.isEmpty {
                Button("Review your sessions") { tab = 2 }
            }
        }
    }

    private func sourceCard(_ source: CaptureSource, icon: String, subtitle: String) -> some View {
        let selected = studio.source == source
        return Button {
            studio.source = source
            if source == .glasses { studio.refreshGlassesRegistration() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2.weight(.medium)).foregroundStyle(green)
                    .frame(width: 46, height: 46)
                    .background(selected ? .white : sage, in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.rawValue).font(stageHeading(17, .headline))
                    Text(subtitle).font(stageBody(13, .footnote)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(green).accessibilityHidden(true)
            }
            .padding(14).foregroundStyle(ink)
            .background(selected ? sage : .white, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(green.opacity(selected ? 0.55 : 0.14)) }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
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
                        Text(session.title).font(stageHeading(17, .headline))
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
            Text(value).font(stageHeading(20, .title3)).monospacedDigit()
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
                Text("Transcript").font(stageHeading(17, .headline))
                Text(session.transcript.isEmpty ? "No transcript was captured. Your recording is saved." : session.transcript)
                    .textSelection(.enabled)
                Text("Coaching report").font(stageHeading(17, .headline))
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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "record.circle.fill").font(.system(size: 42))
                            .foregroundStyle(Color(red: 0.23, green: 0.39, blue: 0.30))
                            .accessibilityHidden(true)
                        Text("Welcome to StageSight").font(stageHeading(34, .largeTitle))
                        Text("Sign in with your StageSight web account to use live coaching and session reports.")
                            .foregroundStyle(.secondary)
                    }.card(Color(red: 0.91, green: 0.93, blue: 0.88))
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Email").font(.subheadline.weight(.semibold))
                            TextField("Email address", text: $email)
                                .keyboardType(.emailAddress)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Password").font(.subheadline.weight(.semibold))
                            SecureField("Your password", text: $password)
                                .textContentType(.password)
                                .textFieldStyle(.roundedBorder)
                        }
                        if !message.isEmpty {
                            Label(message, systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(.red)
                        }
                        Button {
                            busy = true
                            message = ""
                            Task {
                                defer { busy = false }
                                do {
                                    try await studio.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                                    password = ""
                                } catch { message = error.localizedDescription }
                            }
                        } label: {
                            HStack {
                                if busy { ProgressView().tint(.white) }
                                Text(busy ? "Signing in…" : "Sign in")
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    }.card(.white)
                    Label("You’ll stay signed in on this iPhone.", systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
            }
            .font(stageBody(15, .body))
            .background(Color(red: 0.96, green: 0.97, blue: 0.95))
            .tint(Color(red: 0.23, green: 0.39, blue: 0.30))
            .navigationTitle("StageSight account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { studio.showSignIn = false }.disabled(busy)
                }
            }
        }.interactiveDismissDisabled(busy)
    }
}

private func stageHeading(_ size: CGFloat, _ style: Font.TextStyle) -> Font {
    .custom("Manrope-Regular", size: size, relativeTo: style).weight(.bold)
}

private func stageBody(_ size: CGFloat, _ style: Font.TextStyle) -> Font {
    .custom("DMSans-Regular", size: size, relativeTo: style)
}

private extension View {
    func stageField() -> some View {
        padding(12)
            .background(Color(red: 0.97, green: 0.98, blue: 0.97), in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.black.opacity(0.09)) }
    }
}
