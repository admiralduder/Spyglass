import SwiftUI

struct SettingsView: View {
    @Environment(FrigateClient.self) private var client

    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var allowSelfSigned = false
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle, testing, ok(String), failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.10:5000", text: $url)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username (optional)", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password (optional)", text: $password)
                        .textContentType(.password)
                    Toggle("Allow self-signed certificate", isOn: $allowSelfSigned)
                    Button {
                        Task { await saveAndTest() }
                    } label: {
                        HStack {
                            Text("Save & Connect")
                            Spacer()
                            switch status {
                            case .idle: EmptyView()
                            case .testing: ProgressView()
                            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            }
                        }
                    }
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || status == .testing)
                } header: {
                    Text("Server")
                } footer: {
                    switch status {
                    case .ok(let msg): Text(msg)
                    case .failed(let msg): Text(msg).foregroundStyle(.red)
                    default: Text("Port 5000 needs no login. Port 8971 needs your Frigate username and password.")
                    }
                }

                Section("Appearance") {
                    Picker("Appearance", selection: Bindable(client.settings).appearance) {
                        ForEach(ServerSettings.Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if client.settings.isConfigured {
                    Section("Cameras") {
                        NavigationLink("Camera Order") { CameraOrderView() }
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                let s = client.settings
                url = s.serverURL
                username = s.username
                password = s.password
                allowSelfSigned = s.allowSelfSignedCertificates
            }
        }
    }

    private func saveAndTest() async {
        let s = client.settings
        s.serverURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        s.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        s.password = password
        s.allowSelfSignedCertificates = allowSelfSigned
        client.reset()

        guard s.isConfigured else {
            status = .failed("That doesn't look like a valid address.")
            return
        }
        status = .testing
        do {
            let version = try await client.loadVersion()
            let cfg = try await client.loadConfig()
            _ = try? await client.anyEvents()
            status = .ok("Connected to Frigate \(version) · \(cfg.cameraNames.count) cameras")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
