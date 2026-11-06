import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var draft = APICredentials()
    @State private var editing = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "cloud.fill")
                .font(.system(size: 60))
                .foregroundStyle(LinearGradient(colors: [Brand.accent, Color(red: 1, green: 0.55, blue: 0.2)],
                                                startPoint: .top, endPoint: .bottom))
            VStack(spacing: 6) {
                Text("Cumulus").font(.largeTitle.weight(.bold))
                Text("A small, native SoundCloud player for macOS.").foregroundStyle(.secondary)
            }

            if !app.auth.hasBuiltInKey && (editing || !app.auth.credentials.isComplete) {
                CredentialsForm(draft: $draft)
                    .frame(width: 460)
            }

            VStack(spacing: 10) {
                Button {
                    if !app.auth.hasBuiltInKey { app.auth.updateCredentials(draft) }
                    editing = false
                    Task { await app.login() }
                } label: {
                    HStack {
                        if app.auth.isBusy { ProgressView().controlSize(.small) }
                        Text(app.auth.waitingForBrowser ? "Waiting for browser…" : "Log in with SoundCloud")
                    }
                    .frame(width: 240)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!(app.auth.hasBuiltInKey || draft.isComplete) || app.auth.isBusy)
                .keyboardShortcut(.defaultAction)

                if app.auth.waitingForBrowser {
                    VStack(spacing: 6) {
                        Text("Finish in your browser: approve Cumulus on SoundCloud, then allow it to open the app.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        HStack(spacing: 16) {
                            Button("Open browser again") { app.auth.reopenBrowser() }
                            Button("Cancel") { app.auth.cancelLogin() }
                        }
                        .buttonStyle(.link).font(.callout)
                    }
                    .frame(maxWidth: 420)
                }
                if !app.auth.hasBuiltInKey && app.auth.credentials.isComplete && !editing {
                    Button("Change API credentials") { editing = true }.buttonStyle(.link).font(.callout)
                }
                if let e = app.loginError {
                    Text(e).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 460)
                }
            }
            Spacer()
            Text("Your login happens on secure.soundcloud.com. Cumulus never sees your password; tokens stay in your Keychain.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 460)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear { draft = app.auth.credentials }
    }
}

struct CredentialsForm: View {
    @Binding var draft: APICredentials

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SoundCloud API app").font(.headline)
            Text("Register an app at soundcloud.com/you/apps and set its redirect URI to exactly the value below. Then paste its client ID and secret here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("Open soundcloud.com/you/apps", destination: URL(string: "https://soundcloud.com/you/apps")!)
                .font(.callout)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Client ID").foregroundStyle(.secondary)
                    TextField("", text: $draft.clientID).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Client secret").foregroundStyle(.secondary)
                    SecureField("", text: $draft.clientSecret).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Redirect URI").foregroundStyle(.secondary)
                    TextField("", text: $draft.redirectURI).textFieldStyle(.roundedBorder)
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        TabView {
            PlaybackSettings().tabItem { Label("Playback", systemImage: "play.circle") }
            AccountSettings().tabItem { Label("Account", systemImage: "person.crop.circle") }
            if !app.auth.hasBuiltInKey {
                APISettings().tabItem { Label("API", systemImage: "key") }
            }
        }
        .frame(width: 500)
    }
}

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var s = app.settings
        @Bindable var p = app.player
        Form {
            Picker("Stream quality", selection: $s.quality) {
                ForEach(StreamQuality.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Autoplay similar tracks when the queue ends", isOn: $s.autoplay)
            Toggle("Resume where I left off on launch", isOn: $s.resumeSession)
            Section("Downloads") {
                Toggle("Play the downloaded copy when I have one", isOn: $s.preferDownloads)
                LabeledContent("Download folder") {
                    HStack {
                        Text(app.downloader.folder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change…") { chooseFolder() }
                        Button("Reveal") { System.reveal(app.downloader.folder) }
                    }
                }
            }
            Toggle("Show mini player in the menu bar", isOn: $s.showMenuBar)
            Picker("Playback speed", selection: $p.speed) {
                ForEach([0.5, 0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { Text(ExtraControls.speedLabel($0)).tag($0) }
            }
            LabeledContent("Image cache") {
                Button("Clear") { ImageLoader.shared.clear() }
            }
            LabeledContent("History") {
                Button("Clear") { app.player.clearHistory() }
            }
            Section {
                Text("Space plays and pauses. ⌘← and ⌘→ skip, ⌥⌘← and ⌥⌘→ jump 15 seconds, ⌘↑ and ⌘↓ change volume, ⌘L likes, ⌘O opens a link. Media keys and Control Center work too.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            app.settings.downloadFolderPath = url.path
        }
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            if app.auth.isLoggedIn {
                HStack(spacing: 12) {
                    Artwork(url: app.library.me?.avatar(.medium), size: 48, circle: true, placeholder: "person.fill")
                    VStack(alignment: .leading) {
                        Text(app.library.me?.displayName ?? "Signed in").font(.headline)
                        if let f = app.library.me?.followersCount {
                            Text("\(compactCount(f)) followers").foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Log Out") { app.logout() }
                }
            } else {
                Text("Not logged in.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 160)
    }
}

private struct APISettings: View {
    @Environment(AppModel.self) private var app
    @State private var draft = APICredentials()

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            CredentialsForm(draft: $draft)
            Button("Save") { app.auth.updateCredentials(draft) }
                .disabled(draft == app.auth.credentials || !draft.isComplete)
        }
        .padding(20)
        .onAppear { draft = app.auth.credentials }
    }
}
