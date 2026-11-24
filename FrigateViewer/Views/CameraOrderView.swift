import SwiftUI

/// Drag cameras to set the order used on the Cameras tab and in the Events filter.
struct CameraOrderView: View {
    @Environment(FrigateClient.self) private var client
    @State private var names: [String] = []
    @State private var error: String?

    var body: some View {
        List {
            if names.isEmpty {
                if let error {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            } else {
                Section {
                    ForEach(names, id: \.self) { name in
                        Text(name.prettyName)
                    }
                    .onMove { from, to in
                        names.move(fromOffsets: from, toOffset: to)
                        client.settings.cameraOrder = names
                    }
                } footer: {
                    Text("Drag the handles to change the order on the Cameras tab.")
                }

                Section {
                    Button("Reset to A–Z") {
                        client.settings.cameraOrder = []
                        names = client.cameraNames
                    }
                    .disabled(client.settings.cameraOrder.isEmpty)
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Camera Order")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if client.config == nil {
                do { try await client.loadConfig() } catch { self.error = error.localizedDescription }
            }
            names = client.cameraNames
        }
    }
}
