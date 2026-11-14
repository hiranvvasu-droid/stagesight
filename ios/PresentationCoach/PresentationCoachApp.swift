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
    private enum PracticeStep: Equatable { case source, setup, ready }
    @State private var step = PracticeStep.source
    @State private var showControls = false
    @Environment(\.openURL) private var openURL
    private let ink = Color(red: 0.17, green: 0.25, blue: 0.22)
    private let green = Color(red: 0.28, green: 0.44, blue: 0.35)
    private let paper = Color(red: 0.96, green: 0.97, blue: 0.95)
    private let sage = Color(red: 0.93, green: 0.95, blue: 0.91)

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
        .font(stageBody(16, .body))
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
                ZStack {
                    Circle().strokeBorder(green.opacity(0.15)).frame(width: 72, height: 72)
                    Circle().fill(.white.opacity(0.55)).frame(width: 58, height: 58)
                    Image(systemName: "mic.fill").font(.system(size: 27, weight: .regular))
                        .rotationEffect(.degrees(14)).foregroundStyle(green)
                }.accessibilityHidden(true)
                Text("Great presentations begin with practice.").font(stageHeading(22, .title2))
                Button { newPractice() } label: {
                    Label("Start a practice session", systemImage: "arrow.up.right")
                }.buttonStyle(.borderedProminent)
            }.card(sage)
            HStack(alignment: .top, spacing: 12) {
                metric("Practice sessions", studio.sessions.count.formatted())
                metric("Time well spent", "\(Int(studio.sessions.reduce(0) { $0 + $1.duration } / 60)) min")
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("Practice tools").font(stageHeading(22, .title2)).accessibilityAddTraits(.isHeader)
                practiceTool("Live AI coaching", icon: "sparkles",
                             description: "Get short tips as you speak. When enabled, audio from your selected microphone is sent to OpenAI.")
                Divider()
                practiceTool("Audience direction overlays", icon: "viewfinder",
                             description: "See boxes around people in the camera view and an estimate of which way they’re facing.")
                Divider()
                practiceTool("On-device transcription", icon: "waveform",
                             description: "See your words as you speak and track your pace, pauses, and estimated filler words.")
            }.card(.white)
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
            if !studio.isRecording {
                switch step {
                case .source:
                    practiceHeading("Choose your camera", "Pick how you’ll capture video and audio.", progress: "Step 1 of 3")
                    sourceCard(.glasses, icon: "eyeglasses", subtitle: "Hands-free video and audio")
                    sourceCard(.phone, icon: "iphone", subtitle: "Use this iPhone’s camera and microphone")
                case .setup:
                    practiceBack(to: .source, label: "Capture source")
                    practiceHeading("Set up your rehearsal", studio.source.rawValue, progress: "Step 2 of 3")
                    if studio.source == .glasses {
                        glassesSetup
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Session details").font(stageHeading(20, .title3))
                        TextField("Presentation title", text: $studio.title).stageField()
                        TextField("Outline or talking points", text: $studio.outline, axis: .vertical)
                            .lineLimit(2...5).stageField()
                        Picker("Practice type", selection: $studio.practiceType) {
                            ForEach(["Pitch practice", "Product walkthrough", "Storytelling", "Keynote"], id: \.self) {
                                Text($0)
                            }
                        }
                    }.card(.white)
                    Button {
                        advance(to: .ready)
                    } label: {
                        Label("Continue", systemImage: "arrow.right").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(studio.isBusy || (studio.source == .glasses && !studio.glassesRegistered))
                case .ready:
                    practiceBack(to: .setup, label: "Session setup")
                    practiceHeading("Ready to rehearse?", studio.source.rawValue + " · " + studio.practiceType,
                                    progress: "Step 3 of 3")
                    recordingOptions
                }
            } else if showControls {
                Label(studio.source.rawValue, systemImage: studio.source == .glasses ? "eyeglasses" : "iphone")
                    .card(sage)
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
            if studio.isRecording || step == .ready {
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
            }
            if !studio.isRecording && step == .ready && !studio.sessions.isEmpty {
                Button("Review your sessions") { tab = 2 }
            }
        }
    }

    private func advance(to next: PracticeStep) {
        withAnimation(.easeInOut(duration: 0.22)) { step = next }
    }

    private func practiceHeading(_ title: String, _ subtitle: String, progress: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progress).font(stageBody(12, .caption).weight(.semibold)).foregroundStyle(green)
            Text(title).font(stageHeading(34, .largeTitle)).accessibilityAddTraits(.isHeader)
            Text(subtitle).foregroundStyle(.secondary)
        }
    }

    private func practiceBack(to previous: PracticeStep, label: String) -> some View {
        Button { advance(to: previous) } label: {
            Label(label, systemImage: "chevron.left").font(stageBody(14, .subheadline).weight(.semibold))
        }.disabled(studio.isBusy)
    }

    private var glassesSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(studio.glassesRegistered ? "Meta AI setup complete" : "First time using Meta glasses?",
                  systemImage: studio.glassesRegistered ? "checkmark.circle.fill" : "link.circle")
                .font(stageHeading(16, .headline)).foregroundStyle(green)
            if !studio.glassesRegistered {
                Text("Finish setup in Meta AI, then return to StageSight.")
                    .font(stageBody(15, .subheadline)).foregroundStyle(.secondary)
                Button {
                    Task { await studio.register() }
                } label: {
                    Label("Set up in Meta AI", systemImage: "arrow.up.right")
                }.buttonStyle(.bordered)
            }
        }.card(sage)
    }

    private func practiceTool(_ title: String, icon: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium)).foregroundStyle(green)
                .frame(width: 40, height: 40)
                .background(sage, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(stageHeading(17, .headline))
                Text(description).font(stageBody(15, .subheadline))
                    .foregroundStyle(.secondary).lineSpacing(2)
            }
        }
    }

    private var recordingOptions: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Coaching and overlays").font(stageHeading(20, .title3)).accessibilityAddTraits(.isHeader)
            Toggle(isOn: $studio.liveEnabled) { Label("Live AI coaching", systemImage: "sparkles") }
            if studio.liveEnabled {
                Text("Audio from your selected microphone is sent to OpenAI.")
                    .font(stageBody(15, .subheadline)).foregroundStyle(.secondary)
                if studio.accountEmail == nil {
                    Button("Sign in to enable coaching") { studio.showSignIn = true }
                }
            }
            Toggle(isOn: $studio.overlays) { Label("Audience direction overlays", systemImage: "viewfinder") }
            Toggle(isOn: $studio.speechEnabled) { Label("On-device transcription", systemImage: "waveform") }
            Divider()
            Toggle("Everyone being recorded knows and has agreed", isOn: $studio.consent)
        }.disabled(studio.isBusy).card(.white)
    }

    private func sourceCard(_ source: CaptureSource, icon: String, subtitle: String) -> some View {
        let featured = source == .glasses
        return Button {
            studio.source = source
            if source == .glasses { studio.refreshGlassesRegistration() }
            advance(to: .setup)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2.weight(.medium)).foregroundStyle(green)
                    .frame(width: 46, height: 46)
                    .background(featured ? .white : sage, in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.rawValue).font(stageHeading(17, .headline))
                    Text(subtitle).font(stageBody(15, .subheadline)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Image(systemName: "arrow.right")
                    .font(.title3).foregroundStyle(green).accessibilityHidden(true)
            }
            .padding(14).foregroundStyle(ink)
            .background(featured ? sage : .white, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(green.opacity(featured ? 0.32 : 0.14)) }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }

    private var library: some View {
        let totalDuration = studio.sessions.reduce(0) { $0 + $1.duration }
        let measured = studio.sessions.reversed().filter { !$0.pace.isEmpty }
        return Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("My sessions").font(stageHeading(34, .largeTitle)).accessibilityAddTraits(.isHeader)
                Text("Revisit a rehearsal and see how your delivery changes.").foregroundStyle(.secondary)
            }
            if studio.sessions.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 26)).foregroundStyle(green).accessibilityHidden(true)
                    Text("Your first rehearsal starts here").font(stageHeading(21, .title2))
                    Text("Saved recordings, transcripts, and reports appear here.")
                        .foregroundStyle(.secondary)
                    Button("Start a practice session") { newPractice() }
                        .buttonStyle(.borderedProminent)
                }.multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, 14).card(sage)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    metric("Recordings", studio.sessions.count.formatted())
                    metric("Practice time", Duration.seconds(totalDuration).formatted(.time(pattern: .minuteSecond)))
                }
                if measured.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Speaking pace").font(stageHeading(18, .headline))
                        Text("Words per minute by rehearsal").font(stageBody(15, .subheadline)).foregroundStyle(.secondary)
                        Chart(Array(measured.enumerated()), id: \.element.id) { entry in
                            BarMark(x: .value("Rehearsal", "\(entry.offset + 1)"),
                                    y: .value("Words per minute", entry.element.metrics.wpm))
                                .foregroundStyle(green.gradient)
                                .cornerRadius(4)
                        }.frame(height: 128)
                    }.card(.white)
                }
                HStack {
                    Text("Recordings").font(stageHeading(22, .title2)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { newPractice() } label: { Label("New session", systemImage: "plus") }
                        .buttonStyle(.bordered)
                }
                ForEach(studio.sessions) { session in
                    NavigationLink {
                        SessionReview(session: session, studio: studio)
                    } label: {
                        sessionCard(session)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func newPractice() {
        if !studio.isRecording && !studio.isBusy { step = .source }
        tab = 1
    }

    private func sessionCard(_ session: PracticeSession) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: session.source == .glasses ? "eyeglasses" : "iphone")
                .font(.title3.weight(.medium)).foregroundStyle(green)
                .frame(width: 42, height: 42)
                .background(sage, in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title).font(stageHeading(17, .headline))
                Text(session.date.formatted(date: .abbreviated, time: .omitted) + " · " +
                     Duration.seconds(session.duration).formatted(.time(pattern: .minuteSecond)))
                    .font(stageBody(15, .subheadline)).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { sessionTags(session) }
                    VStack(alignment: .leading, spacing: 5) { sessionTags(session) }
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(green).accessibilityHidden(true)
        }.card(.white)
    }

    @ViewBuilder
    private func sessionTags(_ session: PracticeSession) -> some View {
        Text(session.source.rawValue).sessionTag()
        if let type = session.practiceType { Text(type).sessionTag() }
        if session.report != nil { Text("Report").sessionTag() }
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
                            .foregroundStyle(Color(red: 0.28, green: 0.44, blue: 0.35))
                            .accessibilityHidden(true)
                        Text("Welcome to StageSight").font(stageHeading(34, .largeTitle))
                        Text("Sign in with your StageSight web account to use live coaching and session reports.")
                            .foregroundStyle(.secondary)
                    }.card(Color(red: 0.93, green: 0.95, blue: 0.91))
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
            .font(stageBody(16, .body))
            .background(Color(red: 0.96, green: 0.97, blue: 0.95))
            .tint(Color(red: 0.28, green: 0.44, blue: 0.35))
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
    .custom("Manrope-Regular", size: size, relativeTo: style).weight(.semibold)
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


private extension View {
    func sessionTag() -> some View {
        font(stageBody(11, .caption2).weight(.semibold))
            .foregroundStyle(Color(red: 0.28, green: 0.44, blue: 0.35))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(red: 0.93, green: 0.95, blue: 0.91), in: Capsule())
    }
}
