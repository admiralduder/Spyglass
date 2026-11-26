import SwiftUI

/// Turn event types (person, car, …) on or off for the camera timeline and its event list.
struct EventTypesView: View {
    @Environment(FrigateClient.self) private var client
    @State private var labels: [String] = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Toggle(isOn: binding(for: TimelineModel.motionLabel)) {
                    Label("Motion", systemImage: "wave.3.right")
                }
                // The accent is white in dark mode, which hides the knob; switches use green.
                .tint(.green)
            } footer: {
                Text("Motion shows as a yellow bar on the timeline. Tap it to play from there.")
            }

            Section {
                if labels.isEmpty {
                    if let error {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                } else {
                    ForEach(labels, id: \.self) { label in
                        Toggle(isOn: binding(for: label)) {
                            Label(label.prettyName, systemImage: LabelIcon.symbol(for: label))
                        }
                        .tint(.green)
                    }
                }
            } header: {
                Text("Objects")
            } footer: {
                Text("Only the types turned on appear on the timeline and in its event list.")
            }

            Section {
                Button("Show All") { client.settings.hiddenEventLabels = [] }
                    .disabled(client.settings.hiddenEventLabels.isEmpty)
            }
        }
        .navigationTitle("Event Types")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                // Include hidden labels too, in case the server no longer lists one.
                let found = try await client.labels()
                labels = Array(Set(found).union(client.settings.hiddenEventLabels)
                    .subtracting([TimelineModel.motionLabel])).sorted()
                if labels.isEmpty { error = "No event types yet." }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func binding(for label: String) -> Binding<Bool> {
        Binding {
            !client.settings.hiddenEventLabels.contains(label)
        } set: { isOn in
            if isOn {
                client.settings.hiddenEventLabels.remove(label)
            } else {
                client.settings.hiddenEventLabels.insert(label)
            }
        }
    }
}
