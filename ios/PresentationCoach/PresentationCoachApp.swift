import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import SwiftUI
import UIKit
import AVKit
import Charts

@main
struct PresentationCoachApp: App {
    @StateObject private var studio = PracticeStudio()
    @AppStorage("stageSight.darkMode") private var darkMode = true

    var body: some Scene {
        WindowGroup {
            Group {
                if studio.accountEmail == nil {
                    AccountSignIn(studio: studio, darkMode: $darkMode)
                } else {
                    Workspace(studio: studio, darkMode: $darkMode)
                }
            }
            .font(stageBody(16, .body))
            .onOpenURL { url in
                if !GIDSignIn.sharedInstance.handle(url) {
                    Task { await studio.handle(url) }
                }
            }
            .preferredColorScheme(darkMode ? .dark : .light)
        }
    }
}

private struct Workspace: View {
    @ObservedObject var studio: PracticeStudio
    @Binding var darkMode: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animateAISparkle = false
    @State private var tab = 0
    @State private var sessionPath: [UUID] = []
    @State private var editingUsername = false
    private enum PracticeStep: Equatable { case source, setup, ready }
    @State private var step = PracticeStep.source
    @State private var showControls = false
    @Environment(\.openURL) private var openURL
    private let ink = stageInk
    private let green = stageGreen
    private let paper = stagePaper
    private let sage = stageSage

    var body: some View {
        TabView(selection: $tab) {
            page("Overview") { overview }
                .tabItem { Label("Overview", systemImage: "square.grid.2x2") }.tag(0)
            page("Practice studio", official: false) { practice(official: false) }
                .tabItem { Label("Practice", systemImage: "record.circle") }.tag(1)
            page("Present", official: true) { practice(official: true) }
                .tabItem { Label("Present", systemImage: "person.wave.2") }.tag(3)
            page("My Sessions", path: $sessionPath) {
                library.navigationDestination(for: UUID.self) { id in
                    if let session = studio.sessions.first(where: { $0.id == id }) {
                        SessionReview(session: session, studio: studio)
                    }
                }
            }
                .tabItem { Label("My Sessions", systemImage: "rectangle.stack") }.tag(2)
        }
        .tint(green)
        .toolbarBackground(stageSurface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .sheet(isPresented: $editingUsername) { UsernameSettings(studio: studio) }
        .font(stageBody(16, .body))
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, studio.isRecording { studio.stop() }
            if phase == .active, tab == 1 || tab == 3 { studio.refreshGlassesRegistration() }
        }
        .onChange(of: studio.lastSavedSessionID) { _, id in
            guard let id else { return }
            sessionPath = [id]
            tab = 2
        }
        .onChange(of: tab) { _, value in
            if value == 1 || value == 3 { studio.refreshGlassesRegistration() }
            if !studio.isRecording && !studio.isBusy { advance(to: .source) }
        }
    }

    private func page<Content: View>(_ name: String, official: Bool? = nil, path: Binding<[UUID]> = .constant([]), @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: path) {
            Group {
                if let official, studio.isRecording {
                    liveRecording(official: official)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20, content: content)
                            .frame(maxWidth: 620)
                            .padding(20)
                            .frame(maxWidth: .infinity)
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let official, step == .ready {
                            recordingAction(official: official)
                        }
                    }
                }
            }
            .toolbar(official != nil && studio.isRecording ? .hidden : .visible, for: .navigationBar)
            .toolbar(official != nil && studio.isRecording ? .hidden : .visible, for: .tabBar)
            .background(paper)
            .foregroundStyle(ink)
            .navigationTitle(name)
            .toolbarBackground(stageSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Label("StageSight", systemImage: "record.circle.fill")
                        .font(stageHeading(19, .headline)).foregroundStyle(ink)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    StageAppearanceButton(darkMode: $darkMode)
                    if let email = studio.accountEmail {
                        Menu {
                            Text(email)
                            Button(studio.username == nil ? "Set username" : "Edit username", systemImage: "at") {
                                editingUsername = true
                            }
                            Button("Sign out", role: .destructive) { studio.signOut() }
                                .disabled(studio.isRecording || studio.isBusy)
                        } label: {
                            Label {
                                if let name = studio.username { Text("@\(name)").lineLimit(1) }
                            } icon: {
                                Image(systemName: "person.crop.circle.fill")
                            }
                                .font(stageBody(14, .subheadline).weight(.semibold)).foregroundStyle(green)
                                .accessibilityLabel("StageSight account")
                        }

                    }
                }
            }
        }
    }

    private var overview: some View {
        Group {
            overviewHero
            HStack(alignment: .top, spacing: 12) {
                metric("Practice sessions", studio.sessions.count.formatted())
                metric("Practice time", "\(Int(studio.sessions.reduce(0) { $0 + $1.duration } / 60)) min")
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("Practice tools").font(stageHeading(22, .title2)).accessibilityAddTraits(.isHeader)
                practiceTool("Live AI Coaching", icon: "sparkles",
                             description: "Get short tips as you speak. When enabled, audio from your selected microphone is sent to OpenAI.")
                Divider()
                practiceTool("Audience Attention Overlays", icon: "viewfinder",
                             description: "See boxes around people in the camera view and an estimate of which way they’re facing.")
                Divider()
                practiceTool("Live and Saved Transcripts", icon: "waveform",
                             description: "See a live preview as you speak. OpenAI transcribes the saved audio for review.")
            }.card(stageSurface)
            Text("Your recordings").font(stageHeading(22, .title2))
            if studio.sessions.isEmpty {
                Text("Record your first practice session to see it here.").card(stageSurface)
            } else {
                Button("View all sessions") { tab = 2 }.buttonStyle(.bordered)
            }
        }
    }

    private var overviewHero: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("YOUR NEXT CHAPTER STARTS HERE", systemImage: "sparkle")
                .font(stageBody(11, .caption).weight(.semibold))
                .tracking(1)
                .foregroundStyle(green)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(stageSurface.opacity(0.55), in: Capsule())
                .overlay { Capsule().strokeBorder(green.opacity(0.2)) }

            Image("OverviewMicrophone")
                .resizable().scaledToFill()
                .frame(width: 172, height: 172)
                .clipShape(Circle())
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(true)

            Text("Great presentations begin with practice.")
                .font(stageHeading(36, .largeTitle))
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Text("Rehearse your talk, see how you deliver, and turn every session into a step forward.")
                    .foregroundStyle(green)
                    .lineSpacing(4)

                Label {
                    Text("AI tips as you speak and feedback after.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "sparkles")
                        .symbolEffect(.bounce, value: animateAISparkle)
                        .accessibilityHidden(true)
                }
                .font(stageBody(14, .subheadline).weight(.medium))
                .foregroundStyle(green)
                .onAppear {
                    if !reduceMotion { animateAISparkle = true }
                }
            }

            Button { newPractice() } label: {
                HStack {
                    Image(systemName: "record.circle")
                    Text("Start a practice session").foregroundStyle(.white)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                }.font(stageBody(16, .body).weight(.semibold))
            }
            .buttonStyle(.borderedProminent).tint(stageAction)
            .controlSize(.large)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [stageSage, stageHeroEnd],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24)
        )
    }

    private func practice(official: Bool) -> some View {
        Group {
            if !studio.isRecording {
                switch step {
                case .source:
                    practiceHeading(official ? "Official presentation" : "Practice your presentation", "Pick how you’ll capture video and audio.", progress: "Step 1 of 3")
                    sourceCard(.glasses, icon: "eyeglasses", subtitle: "Hands-free video and audio")
                    sourceCard(.phone, icon: "iphone", subtitle: "Use this iPhone’s camera and microphone")
                case .setup:
                    practiceBack(to: .source, label: "Capture Source")
                    practiceHeading(official ? "Set up your presentation" : "Set up your rehearsal", studio.source.rawValue, progress: "Step 2 of 3")
                    if studio.source == .glasses {
                        glassesSetup
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Session Details").font(stageHeading(20, .title3))
                        if studio.source == .phone {
                            Picker("iPhone Camera", selection: $studio.useFrontCamera) {
                                Text("Rear Camera").tag(false)
                                Text("Front Camera").tag(true)
                            }.pickerStyle(.segmented).setupGlass()
                        }
                        TextField("Presentation Title", text: $studio.title).stageField()
                        TextField("Outline or Talking Points", text: $studio.outline, axis: .vertical)
                            .lineLimit(2...5).stageField()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Type of Presentation").font(stageHeading(15, .subheadline))
                            Picker("Type of Presentation", selection: $studio.practiceType) {
                                ForEach(["Pitch practice", "Product walkthrough", "Storytelling", "Keynote", "Interview"], id: \.self) { type in
                                    Text(type.capitalized).tag(type)
                                }
                            }
                            .pickerStyle(.menu)
                            .setupGlass()
                        }
                    }.card(stageSurface)
                    Button {
                        advance(to: .ready)
                    } label: {
                        Label("Continue", systemImage: "arrow.right").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(stageAction).controlSize(.large)
                        .disabled(studio.isBusy || (studio.source == .glasses && !studio.glassesRegistered))
                case .ready:
                    practiceBack(to: .setup, label: "Session Setup")
                    practiceHeading(official ? "Ready to present?" : "Ready to rehearse?", studio.source.rawValue + " · " + studio.practiceType.capitalized,
                                    progress: "Step 3 of 3")
                    recordingOptions
                }
            }
            if !studio.message.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(studio.message, systemImage: "info.circle").font(stageBody(16, .callout))
                    if studio.message.contains("in Settings"), let settings = URL(string: UIApplication.openSettingsURLString) {
                        Button("Open Settings") { openURL(settings) }.font(stageBody(16, .callout).bold())
                    }
                }.card(sage)
            }
            if !studio.isRecording && step == .ready && !studio.sessions.isEmpty {
                Button("Review your sessions") { tab = 2 }
            }
        }
    }

    private func liveRecording(official: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                if let date = studio.recordingDate {
                    Label { Text(date, style: .timer).monospacedDigit() } icon: {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    }.accessibilityLabel("Recording elapsed time")
                }
                Spacer()
                Button("Session Details", systemImage: "waveform") { showControls = true }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)

            if let frame = studio.frame {
                cameraPreview(frame)
                    .overlay(alignment: .top) { liveCoachingOverlay }
            } else {
                ProgressView("Connecting camera…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .background(.black)
            }

            if !studio.message.isEmpty {
                Text(studio.message).font(stageBody(13, .footnote))
                    .padding(.horizontal, 16).padding(.top, 8)
            }
            recordingAction(official: official)
        }
        .sheet(isPresented: $showControls) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            metric("Words per minute", studio.metrics.wpm.formatted())
                            metric("Pauses", studio.metrics.pauses.formatted())
                            metric("Est. fillers", studio.metrics.fillers.formatted())
                        }
                        if !studio.transcript.isEmpty {
                            Text(studio.transcript).frame(maxWidth: .infinity, alignment: .leading).card(stageSurface)
                        }
                    }.padding(20)
                }
                .background(paper)
                .navigationTitle("Session Details")
                .toolbar { Button("Done") { showControls = false } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var liveCoachingOverlay: some View {
        if !studio.coachingCue.isEmpty {
            Label(studio.coachingCue, systemImage: "sparkles")
                .font(stageBody(14, .subheadline).weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .environment(\.colorScheme, .dark)
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.18)) }
                .padding(12)
                .allowsHitTesting(false)
        }
    }

    private func cameraPreview(_ frame: UIImage) -> some View {
        Image(uiImage: frame).resizable().scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { AudienceBoxes(boxes: studio.audience, imageSize: frame.size) }
            .background(.black)
            .accessibilityLabel("Live camera preview")
    }

    private func recordingAction(official: Bool) -> some View {
        VStack(spacing: 6) {
            if !studio.isRecording && !studio.isBusy {
                Toggle((studio.liveCoachingEnabled || studio.speechEnabled) && studio.accountEmail != nil
                   ? "Everyone being recorded agrees to recording and AI audio processing"
                   : "Everyone being recorded knows and has agreed", isOn: $studio.consent)
                    .font(stageBody(13, .footnote))
            }
            Button {
                if studio.isRecording { studio.stop() }
                else { showControls = false; Task { await studio.start(official: official) } }
            } label: {
                Label(studio.isBusy ? "Please wait…" : (studio.isRecording ? "Stop and Save" : (official ? "Start Presentation" : "Start Practice")),
                      systemImage: studio.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(stageAction).controlSize(.large)
            .disabled(studio.isBusy || (!studio.isRecording && !studio.consent))
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(paper)
    }

    private func advance(to next: PracticeStep) {
        if next == .source { studio.resetCaptureStatus() }
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
            Label("Back to " + label, systemImage: "chevron.left")
                .font(stageBody(15, .subheadline).weight(.semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(studio.isBusy)
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
                if !studio.glassesSetupMessage.isEmpty {
                    Text(studio.glassesSetupMessage).font(stageBody(15, .subheadline))
                        .foregroundStyle(.secondary)
                }
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
        VStack(alignment: .leading, spacing: 9) {
            Text("Coaching and Overlays").font(stageHeading(20, .title3)).accessibilityAddTraits(.isHeader)
            if studio.source == .glasses {
                Label("Video Saves to My Sessions", systemImage: "video.badge.checkmark")
                Text("Your glasses recording and session analysis are saved on this iPhone.")
                    .font(stageBody(13, .footnote)).foregroundStyle(.secondary)
            }
            Toggle(isOn: $studio[dynamicMember: studio.liveCoachingSetting]) { Label("Live AI Coaching", systemImage: "sparkles") }
            if studio.liveCoachingEnabled {
                Text("Audio from your selected microphone is sent to OpenAI.")
                    .font(stageBody(15, .subheadline)).foregroundStyle(.secondary)
            }
            Toggle(isOn: $studio.autoReport) { Label("Automatic Coaching Report", systemImage: "doc.text") }
            if studio.autoReport {
                Text("When signed in, StageSight sends your transcript and speaking metrics for feedback after saving.")
                    .font(stageBody(13, .footnote)).foregroundStyle(.secondary)
            }
            Toggle(isOn: $studio.overlays) { Label("Audience Attention Overlays", systemImage: "viewfinder") }
            Text("See which way people in view appear to face and review changes in My Sessions.")
                .font(stageBody(13, .footnote)).foregroundStyle(.secondary)
            Toggle(isOn: $studio.speechEnabled) { Label("Session Transcription", systemImage: "waveform") }
            Text("Live preview runs on your iPhone. After saving, StageSight sends the recording’s audio to OpenAI for the final transcript.")
                .font(stageBody(13, .footnote)).foregroundStyle(.secondary)
            if studio.speechEnabled {
                Picker("Spoken Language", selection: $studio.speechLocale) {
                    Text("Use iPhone Default").tag("")
                    ForEach(studio.speechLocales, id: \.identifier) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }
            }
        }.disabled(studio.isBusy).card(stageSurface)
    }

    private func sourceCard(_ source: CaptureSource, icon: String, subtitle: String) -> some View {
        let featured = source == .glasses
        return Button {
            studio.resetCaptureStatus()
            studio.source = source
            if source == .glasses { studio.refreshGlassesRegistration() }
            advance(to: .setup)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2.weight(.medium)).foregroundStyle(green)
                    .frame(width: 46, height: 46)
                    .background(featured ? stageSurface : sage, in: RoundedRectangle(cornerRadius: 13))
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
            .background(featured ? sage : stageSurface, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(green.opacity(featured ? 0.32 : 0.14)) }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }

    private var library: some View {
        let totalDuration = studio.sessions.reduce(0) { $0 + $1.duration }
        let measured = studio.sessions.reversed().filter { !$0.pace.isEmpty }
        return Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("My Sessions").font(stageHeading(34, .largeTitle)).accessibilityAddTraits(.isHeader)
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
                        .buttonStyle(.borderedProminent).tint(stageAction)
                }.multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, 14).card(sage)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    metric("Recordings", studio.sessions.count.formatted())
                    metric("Practice time", Duration.seconds(totalDuration).formatted(.time(pattern: .minuteSecond)))
                }
                if !measured.isEmpty {
                    let average = Double(measured.reduce(0) { $0 + $1.metrics.wpm }) / Double(measured.count)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Speaking Pace").font(stageHeading(18, .headline))
                            Spacer(minLength: 8)
                            Text("\(Int(average.rounded())) WPM avg")
                                .font(stageBody(13, .footnote).weight(.semibold))
                                .foregroundStyle(green)
                        }
                        Text("Words per minute by rehearsal").font(stageBody(15, .subheadline)).foregroundStyle(.secondary)
                        Chart(Array(measured.enumerated()), id: \.element.id) { entry in
                            BarMark(x: .value("Rehearsal", "\(entry.offset + 1)"),
                                    y: .value("Words per minute", entry.element.metrics.wpm))
                                .foregroundStyle(green.gradient)
                                .cornerRadius(4)
                        }.frame(height: 128)
                    }.card(stageSurface)
                }
                HStack {
                    Text("Recordings").font(stageHeading(22, .title2)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { newPractice() } label: { Label("New session", systemImage: "plus") }
                        .buttonStyle(.bordered)
                }
                ForEach(studio.sessions) { session in
                    NavigationLink(value: session.id) {
                        sessionCard(session)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func newPractice() {
        if !studio.isRecording && !studio.isBusy { advance(to: .source) }
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
        }.card(stageSurface)
    }

    @ViewBuilder
    private func sessionTags(_ session: PracticeSession) -> some View {
        Text(session.source.rawValue).sessionTag()
        if session.isOfficialPresentation == true { Text("Official presentation").sessionTag() }
        else if let type = session.practiceType { Text(type.capitalized).sessionTag() }
        if session.report != nil { Text("Report").sessionTag() }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(stageBody(12, .caption)).foregroundStyle(.secondary)
            Text(value).font(stageHeading(20, .title3)).monospacedDigit()
        }.card(stageSurface)
    }
}

private struct AudienceBoxes: View {
    let boxes: [AudienceBox]
    let imageSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            if imageSize.width > 0, imageSize.height > 0 {
                let scale = min(geometry.size.width / imageSize.width, geometry.size.height / imageSize.height)
                let width = imageSize.width * scale
                let height = imageSize.height * scale
                let left = (geometry.size.width - width) / 2
                let top = (geometry.size.height - height) / 2
                ForEach(boxes) { person in
                    let box = person.box
                    RoundedRectangle(cornerRadius: 5).strokeBorder(person.facingCamera ? .green : .orange, lineWidth: 2)
                        .overlay(alignment: .top) {
                            Text(person.label).font(stageBody(11, .caption2).bold())
                                .fixedSize()
                                .foregroundStyle(.white).padding(3).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                        }
                        .frame(width: box.width * width, height: box.height * height)
                        .position(x: left + box.midX * width, y: top + (1 - box.midY) * height)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AudiencePlayback: View {
    let player: AVPlayer
    let frames: [AudienceFrame]
    @State private var size = CGSize.zero
    @State private var seconds = 0.0
    @State private var observer: Any?

    var body: some View {
        VideoPlayer(player: player) {
            AudienceBoxes(boxes: currentBoxes, imageSize: size)
        }
        .task {
            guard let item = player.currentItem,
                  let track = try? await item.asset.loadTracks(withMediaType: .video).first,
                  let naturalSize = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform) else { return }
            let display = CGRect(origin: .zero, size: naturalSize).applying(transform)
            size = display.size
        }
        .onAppear {
            guard observer == nil else { return }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { time in
                MainActor.assumeIsolated { seconds = time.seconds }
            }
        }
        .onDisappear {
            if let observer { player.removeTimeObserver(observer) }
            observer = nil
        }
    }

    private var currentBoxes: [AudienceBox] {
        guard seconds.isFinite else { return [] }
        var low = 0
        var high = frames.count
        while low < high {
            let mid = low + (high - low) / 2
            if frames[mid].seconds <= seconds { low = mid + 1 }
            else { high = mid }
        }
        guard low > 0, seconds - frames[low - 1].seconds < 0.65 else { return [] }
        return frames[low - 1].boxes
    }
}

private struct SessionReview: View {
    let session: PracticeSession
    @ObservedObject var studio: PracticeStudio
    @State private var player: AVPlayer?
    @State private var output = ""
    @State private var analyzingAudience = false
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var error = ""

    private var current: PracticeSession { studio.sessions.first { $0.id == session.id } ?? session }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.title).font(stageHeading(30, .largeTitle)).accessibilityAddTraits(.isHeader)
                    Text(session.date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }

                if let player {
                    VStack(alignment: .leading, spacing: 12) {
                        AudiencePlayback(player: player, frames: current.audienceFrames ?? [])
                            .frame(height: session.source == .glasses ? 320 : 230)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        ViewThatFits(in: .horizontal) {
                            HStack { playButton(player); Spacer(); shareButton }
                            VStack(alignment: .leading) { playButton(player); shareButton }
                        }
                        if current.audienceFrames?.isEmpty != false || current.audienceDetectorVersion != AudienceDetector.version {
                            if analyzingAudience {
                                ProgressView("Analyzing audience in this recording…")
                            } else {
                                Button(current.audienceFrames?.isEmpty == false ? "Refresh Audience Boxes" : "Add Audience Boxes", systemImage: "viewfinder") {
                                    analyzingAudience = true
                                    Task {
                                        defer { analyzingAudience = false }
                                        do { try await studio.analyzeSavedAudience(in: session) }
                                        catch { self.error = error.localizedDescription }
                                    }
                                }.buttonStyle(.bordered)
                            }
                        }
                        if !output.isEmpty { Text("Audio output: \(output)").font(stageBody(12, .caption)).foregroundStyle(.secondary) }
                    }.card(stageSurface)
                }

                VStack(alignment: .leading, spacing: 16) {
                    sectionHeading("Speaking metrics", icon: "waveform.path")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { metrics }
                        VStack(alignment: .leading, spacing: 10) { metrics }
                    }
                    if !session.pace.isEmpty {
                        Chart(session.pace) { point in
                            LineMark(x: .value("Seconds", point.second), y: .value("Words per minute", point.wpm))
                            PointMark(x: .value("Seconds", point.second), y: .value("Words per minute", point.wpm))
                        }
                        .foregroundStyle(stageGreen)
                        .chartXAxisLabel("Seconds")
                        .chartYAxisLabel("WPM")
                        .frame(height: 145)
                    }
                }.card(stageSurface)

                audienceReview

                reportPanel

                transcriptPanel

                Button("Delete recording", role: .destructive) { confirmDelete = true }
                    .font(stageBody(14, .subheadline))
                if !error.isEmpty { Text(error).font(stageBody(16, .callout)).foregroundStyle(.red) }
            }
            .frame(maxWidth: 620).padding(20).frame(maxWidth: .infinity)
        }
        .background(stagePaper)
        .font(stageBody(16, .body))
        .foregroundStyle(stageInk)
        .navigationTitle("Session review")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this practice session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete recording", role: .destructive) {
                player?.pause()
                do { try studio.delete(session); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        }
        .onAppear {
            player = AVPlayer(url: studio.videoURL(for: session))
            Task { await studio.finishTranscript(for: session.id) }
        }
        .onDisappear { player?.pause(); player = nil }
    }

    private func playButton(_ player: AVPlayer) -> some View {
        Button("Play recording", systemImage: "play.fill") {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            player.play()
            output = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ")
        }.buttonStyle(.borderedProminent).tint(stageAction)
    }

    private var shareButton: some View {
        ShareLink(item: studio.videoURL(for: session)) { Label("Share", systemImage: "square.and.arrow.up") }
            .buttonStyle(.bordered)
    }

    @ViewBuilder private var metrics: some View {
        metric(session.metrics.wpm, label: "Words per min")
        metric(session.metrics.pauses, label: "Pauses")
        metric(session.metrics.fillers, label: "Est. fillers")
    }

    private func metric(_ value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(stageHeading(24, .title2)).monospacedDigit()
            Text(label).font(stageBody(13, .footnote)).foregroundStyle(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(stagePaper, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Transcript", icon: "text.alignleft")
            if current.cloudTranscriptPending == true {
                ProgressView("Transcribing saved audio…")
            } else if current.cloudTranscript != nil {
                Text("Transcribed with OpenAI").font(stageBody(13, .footnote)).foregroundStyle(.secondary)
            }
            if let failure = current.cloudTranscriptError {
                let detail = current.transcript.isEmpty ? failure : "Showing the on-device transcript. " + failure
                Text(detail).font(stageBody(13, .footnote)).foregroundStyle(.secondary)
            }
            if !current.reviewTranscript.isEmpty {
                Text(current.reviewTranscript).lineSpacing(5).textSelection(.enabled)
            } else if current.cloudTranscriptPending != true {
                Text("No transcript was captured. Your recording is saved.").foregroundStyle(.secondary)
            }
        }.card(stageSurface)
    }

    private var audienceReview: some View {
        let intervals = AudienceFrame.intervals(for: current.audienceFrames ?? [])
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Audience Head Direction", icon: "person.2")
            if !intervals.isEmpty {
                Text("Estimated share facing the camera in each 10-second window. Gaps indicate too few clear readings.")
                    .font(stageBody(13, .footnote)).foregroundStyle(.secondary)
                Chart(intervals) { interval in
                    BarMark(xStart: .value("Start", Double(interval.start)),
                            xEnd: .value("End", min(Double(interval.start + 10), session.duration)),
                            y: .value("Facing camera (%)", interval.percentFacingCamera))
                        .foregroundStyle(stageGreen)
                    if interval.percentFacingCamera == 0 {
                        PointMark(x: .value("Seconds", (Double(interval.start) + min(Double(interval.start + 10), session.duration)) / 2),
                                  y: .value("Facing camera (%)", 0))
                            .foregroundStyle(stageGreen)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: 0...max(10, session.duration))
                .chartXAxisLabel("Seconds")
                .chartYAxisLabel("Facing camera (%)")
                .frame(height: 145)
            } else {
                Text("There weren’t enough clear readings to chart head direction.")
                    .foregroundStyle(.secondary)
            }
        }.card(stageSurface)
    }

    private var reportPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Coaching report", icon: "sparkles")
            if let report = current.report {
                if current.cloudTranscript != nil && current.reportUsesCloudTranscript != true {
                    Text("This report used the original on-device transcript.")
                        .font(stageBody(13, .footnote)).foregroundStyle(.secondary)
                }
                CoachingReport(text: report)
            } else if current.cloudTranscriptPending == true {
                Text("Waiting for the final transcript…").foregroundStyle(.secondary)
            } else if current.reviewTranscript.isEmpty {
                Text("A transcript is needed to generate a report.").foregroundStyle(.secondary)
            } else {
                Text("Get feedback based on your transcript and speaking metrics. StageSight sends both to its cloud service.")
                    .foregroundStyle(.secondary)
                if studio.reportsInProgress.contains(session.id) {
                    HStack { ProgressView(); Text("Generating coaching report…") }
                } else {
                    if let reportError = studio.reportErrors[session.id] {
                        Text(reportError).foregroundStyle(.red)
                    }
                    Button(studio.reportErrors[session.id] == nil ? "Generate report" : "Retry report") {
                        Task { await studio.report(for: session) }
                    }.buttonStyle(.borderedProminent).tint(stageAction)
                }
            }
        }.card(stageSage)
    }

    private func sectionHeading(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(stageHeading(20, .title3))
            .accessibilityAddTraits(.isHeader)
    }

}

private struct CoachingReport: View {
    let text: String

    private struct Section {
        var heading: String?
        var lines: [String] = []
    }

    private var sections: [Section] {
        var result: [Section] = []
        var section = Section()
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != "---" else { continue }
            if line.hasPrefix("#") || (line.hasPrefix("**") && line.dropFirst(2).dropLast(2).contains("*") == false && line.hasSuffix("**")) {
                if section.heading != nil || !section.lines.isEmpty { result.append(section) }
                section = Section(heading: line.trimmingCharacters(in: CharacterSet(charactersIn: "#* ")))
            } else {
                section.lines.append(line)
            }
        }
        if section.heading != nil || !section.lines.isEmpty { result.append(section) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 9) {
                    if let heading = section.heading {
                        Text(heading).font(stageHeading(17, .headline)).accessibilityAddTraits(.isHeader)
                    }
                    ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                        if line.hasPrefix("- ") || line.hasPrefix("* ") {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(stageGreen).accessibilityHidden(true)
                                paragraph(String(line.dropFirst(2)))
                            }
                        } else {
                            paragraph(line)
                        }
                    }
                }.card(stageSurface)
            }
        }.textSelection(.enabled)
    }

    private func paragraph(_ line: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: line, options: options)) ?? AttributedString(line))
            .lineSpacing(4)
    }
}

private struct StageAppearanceButton: View {
    @Binding var darkMode: Bool

    var body: some View {
        Button(darkMode ? "Switch to Light Mode" : "Switch to Dark Mode",
               systemImage: darkMode ? "sun.max" : "moon") {
            darkMode.toggle()
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(stageGreen)
    }
}

private func stageColor(light: UIColor, dark: UIColor) -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? dark : light
    })
}

private let stageAction = Color(red: 0.18, green: 0.40, blue: 0.29)

private let stageInk = stageColor(
    light: UIColor(red: 0.17, green: 0.25, blue: 0.22, alpha: 1),
    dark: UIColor(red: 0.90, green: 0.94, blue: 0.91, alpha: 1)
)
private let stageGreen = stageColor(
    light: UIColor(red: 0.28, green: 0.44, blue: 0.35, alpha: 1),
    dark: UIColor(red: 0.63, green: 0.82, blue: 0.71, alpha: 1)
)
private let stagePaper = stageColor(
    light: UIColor(red: 0.96, green: 0.97, blue: 0.95, alpha: 1),
    dark: UIColor(red: 0.07, green: 0.11, blue: 0.10, alpha: 1)
)
private let stageSurface = stageColor(
    light: .white,
    dark: UIColor(red: 0.11, green: 0.16, blue: 0.14, alpha: 1)
)
private let stageSage = stageColor(
    light: UIColor(red: 0.93, green: 0.95, blue: 0.91, alpha: 1),
    dark: UIColor(red: 0.14, green: 0.22, blue: 0.18, alpha: 1)
)
private let stageHeroEnd = stageColor(
    light: UIColor(red: 0.87, green: 0.91, blue: 0.83, alpha: 1),
    dark: UIColor(red: 0.09, green: 0.15, blue: 0.13, alpha: 1)
)
private let stageFieldFill = stageColor(
    light: UIColor(red: 0.97, green: 0.98, blue: 0.97, alpha: 1),
    dark: UIColor(red: 0.08, green: 0.12, blue: 0.11, alpha: 1)
)

private extension View {
    func card(_ color: Color) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(stageGreen.opacity(0.14)) }
    }
}


private struct UsernameField: View {
    @Binding var username: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Username").font(stageBody(15, .subheadline).weight(.semibold))
            TextField("your_name", text: $username)
                .textInputAutocapitalization(.never).autocorrectionDisabled().stageField()
            Text("3–24 letters, numbers, or underscores.")
                .font(stageBody(13, .footnote)).foregroundStyle(.secondary)
        }
    }
}

private struct UsernameSettings: View {
    @ObservedObject var studio: PracticeStudio
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var error = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    UsernameField(username: $username)
                    if !error.isEmpty { Text(error).foregroundStyle(.red) }
                    Button(saving ? "Saving…" : "Save username") {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                try await studio.updateUsername(username)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }.buttonStyle(.borderedProminent).tint(stageAction).disabled(saving || username.isEmpty)
                }.card(stageSurface).padding(20).disabled(saving)
            }
            .background(stagePaper)
            .navigationTitle("Your profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.disabled(saving) }
        }
        .interactiveDismissDisabled(saving)
        .onAppear { username = studio.username ?? "" }
    }
}

private struct AccountSignIn: View {
    private enum Mode: String {
        case signIn = "Sign in"
        case create = "Create account"
    }

    @ObservedObject var studio: PracticeStudio
    @Binding var darkMode: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode = Mode.signIn
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var message = ""
    @State private var checkEmail = false
    @State private var busy = false
    private let green = stageGreen
    private let sage = stageSage

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if checkEmail {
                        confirmation.transition(panelTransition)
                    } else {
                        header
                        form
                        socialSignIn
                        VStack(spacing: 4) {
                            Text(mode == .signIn ? "New to StageSight?" : "Already have an account?")
                                .foregroundStyle(.secondary)
                            Button(mode == .signIn ? "Create an account" : "Back to sign in") {
                                switchMode(to: mode == .signIn ? .create : .signIn)
                            }
                            .font(stageBody(15, .subheadline).weight(.semibold))
                            .frame(minHeight: 44)
                            .disabled(busy)
                        }
                        .font(stageBody(14, .subheadline))
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(20).frame(maxWidth: 520).frame(maxWidth: .infinity)
            }
            .font(stageBody(16, .body))
            .background(stageSage.ignoresSafeArea())
            .foregroundStyle(stageInk)
            .tint(green)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    StageAppearanceButton(darkMode: $darkMode)
                }
            }
        }
    }

    private var panelTransition: AnyTransition {
        reduceMotion ? .opacity : .offset(y: 10).combined(with: .opacity)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image("OverviewMicrophone")
                .resizable().scaledToFill()
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("StageSight").font(stageHeading(22, .title2))
                Text("Rehearse or record a live talk, get coaching as you speak, and review your delivery afterward.")
                    .font(stageBody(14, .subheadline))
                    .foregroundStyle(green)
            }
        }
        .card(sage)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .signIn ? "Sign in to get started" : "Create your StageSight account")
                .font(stageHeading(23, .title2))
                .accessibilityAddTraits(.isHeader)
                .id(mode).transition(panelTransition)
            VStack(alignment: .leading, spacing: 6) {
                Text("Email").font(stageBody(15, .subheadline))
                TextField("Email address", text: $email)
                    .accessibilityLabel("Email")
                    .keyboardType(.emailAddress).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().stageField()
            }
            if mode == .create {
                UsernameField(username: $username).transition(panelTransition)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Password").font(stageBody(15, .subheadline))
                SecureField("Your password", text: $password)
                    .accessibilityLabel("Password")
                    .textContentType(mode == .create ? .newPassword : .password).stageField()
                if mode == .create {
                    Text("Use at least 8 characters.").font(stageBody(13, .footnote)).foregroundStyle(.secondary)
                        .transition(panelTransition)
                }
            }
            if !message.isEmpty {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(stageBody(13, .footnote)).foregroundStyle(.red)
            }
            Button(action: submit) {
                HStack {
                    if busy { ProgressView().tint(.white) }
                    Text(busy ? (mode == .signIn ? "Signing in…" : "Creating account…") : mode.rawValue)
                }
                .font(stageBody(16, .body).weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).tint(stageAction).controlSize(.large)
                .disabled(busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          password.isEmpty || (mode == .create && (password.count < 8 || username.isEmpty)))
        }.disabled(busy).card(stageSurface)
    }

    private var socialSignIn: some View {
        VStack(spacing: 10) {
            Text("Or continue with")
                .font(stageBody(13, .footnote))
                .foregroundStyle(.secondary)
            Button {
                runSocialSignIn { try await googleCredential() }
            } label: {
                Label("Continue with Google", systemImage: "globe").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

        }
        .disabled(busy)
    }

    private func googleCredential() async throws -> AuthCredential {
        guard let clientID = FirebaseApp.app()?.options.clientID,
              let presenter = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })?
                .keyWindow?.rootViewController else {
            throw StudioError("Google sign-in is unavailable in this build.")
        }
        let scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        guard urlTypes.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(scheme) == true }) else {
            throw StudioError("Google sign-in is unavailable in this build.")
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else {
            throw StudioError("Couldn’t complete Google sign-in. Try again.")
        }
        return GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
    }

    private func runSocialSignIn(_ credential: @escaping @MainActor () async throws -> AuthCredential) {
        guard !busy else { return }
        busy = true
        message = ""
        Task {
            defer { busy = false }
            do {
                let authCredential = try await credential()
                try await studio.signIn(with: authCredential)
            } catch let error as NSError where error.domain == kGIDSignInErrorDomain &&
                error.code == GIDSignInError.Code.canceled.rawValue {
                return
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.largeTitle).foregroundStyle(green).accessibilityHidden(true)
            Text("Check your email").font(stageHeading(30, .largeTitle)).accessibilityAddTraits(.isHeader)
            Text("If you’re new to StageSight, look for the confirmation link we sent to \(email). After confirming, sign in here or on the website.")
                .foregroundStyle(.secondary)
            Button("Back to sign in") {
                switchMode(to: .signIn)
            }.buttonStyle(.borderedProminent).tint(stageAction).controlSize(.large)
        }.card(sage)
    }

    private func switchMode(to next: Mode) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
            mode = next
            password = ""
            message = ""
            checkEmail = false
        }
    }

    private func submit() {
        busy = true
        message = ""
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { busy = false }
            do {
                if mode == .create {
                    if try await studio.createAccount(email: address, password: password, username: username) {
                        email = address
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) { checkEmail = true }
                    }
                } else {
                    try await studio.signIn(email: address, password: password)
                }
                password = ""
            } catch { message = error.localizedDescription }
        }
    }
}

private func stageHeading(_ size: CGFloat, _ style: Font.TextStyle) -> Font {
    stageBody(size, style).weight(.semibold)
}

private func stageBody(_ size: CGFloat, _ style: Font.TextStyle) -> Font {
    .custom("Inter-Regular", size: size, relativeTo: style)
}

private extension View {
    func stageField() -> some View {
        padding(12)
            .background(stageFieldFill, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(stageInk.opacity(0.14)) }
    }
}


private extension View {
    func sessionTag() -> some View {
        font(stageBody(11, .caption2).weight(.semibold))
            .foregroundStyle(stageGreen)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(stageSage, in: Capsule())
    }
}


private extension View {
    @ViewBuilder
    func setupGlass() -> some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        let control = self.padding(.horizontal, 12).padding(.vertical, 8)
        if #available(iOS 26.0, *) {
            control.glassEffect(.regular.tint(stageSage.opacity(0.35)).interactive(), in: shape)
        } else {
            control.background(stageSage, in: shape)
        }
    }
}
