import SwiftUI

struct EventsView: View {
    @Environment(FrigateClient.self) private var client
    @State private var camera: String?
    @State private var label: String?
    @State private var labels: [String] = []

    var body: some View {
        NavigationStack {
            Group {
                if client.settings.isConfigured {
                    ScrollView {
                        EventList(camera: camera, label: label, limit: 50, embedded: false)
                            .id("\(camera ?? "*")|\(label ?? "*")|\(client.settings.serverURL)")
                            .padding()
                    }
                } else {
                    ContentUnavailableView("No Server", systemImage: "server.rack",
                                           description: Text("Add your Frigate server in Settings."))
                }
            }
            .navigationTitle("Events")
            .navigationDestination(for: FrigateEvent.self) { EventDetailView(event: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
            .task(id: client.settings.serverURL) {
                guard client.settings.isConfigured else { return }
                if client.config == nil { _ = try? await client.loadConfig() }
                labels = (try? await client.labels()) ?? []
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Camera", selection: $camera) {
                Text("All Cameras").tag(String?.none)
                ForEach(client.cameraNames, id: \.self) {
                    Text($0.prettyName).tag(String?.some($0))
                }
            }
            Picker("Object", selection: $label) {
                Text("All Objects").tag(String?.none)
                ForEach(labels, id: \.self) {
                    Text($0.prettyName).tag(String?.some($0))
                }
            }
        } label: {
            Image(systemName: camera == nil && label == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }
}

/// A paged list of events. Used by the Events tab and under each live camera.
struct EventList: View {
    @Environment(FrigateClient.self) private var client
    var camera: String? = nil
    var label: String? = nil
    var limit = 50
    /// When embedded, don't page and don't add pull-to-refresh.
    var embedded = false

    @State private var events: [FrigateEvent] = []
    @State private var loaded = false
    @State private var canLoadMore = true
    @State private var error: String?

    var body: some View {
        LazyVStack(spacing: 10) {
            if let error, events.isEmpty {
                Text(error).foregroundStyle(.secondary).padding()
                Button("Try Again") { Task { await reload() } }
            } else if loaded && events.isEmpty {
                Text("No events").foregroundStyle(.secondary).padding()
            }
            ForEach(events) { event in
                NavigationLink(value: event) {
                    EventRow(event: event, showCamera: camera == nil)
                }
                .buttonStyle(.plain)
                .onAppear {
                    if !embedded, event.id == events.last?.id { Task { await loadMore() } }
                }
            }
            if !loaded { ProgressView().padding() }
        }
        .task { if !loaded { await reload() } }
        .refreshable { await reload() }
    }

    private func reload() async {
        do {
            let page = try await client.events(camera: camera, label: label, limit: limit)
            events = page
            canLoadMore = page.count == limit
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func loadMore() async {
        guard canLoadMore, let last = events.last else { return }
        canLoadMore = false
        if let page = try? await client.events(camera: camera, label: label, before: last.startTime, limit: limit) {
            let known = Set(events.map(\.id))
            events += page.filter { !known.contains($0.id) }
            canLoadMore = page.count == limit
        }
    }
}

struct EventRow: View {
    @Environment(FrigateClient.self) private var client
    let event: FrigateEvent
    var showCamera = true

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(makeURL: { try client.thumbnailURL(event: event) }, contentMode: .fill)
                .frame(width: 96, height: 72)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: LabelIcon.symbol(for: event.label))
                    Text(event.label.prettyName).font(.headline)
                    if let score = event.score {
                        Text(score, format: .percent.precision(.fractionLength(0)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if event.isInProgress {
                        Text("LIVE").font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.red, in: Capsule()).foregroundStyle(.white)
                    }
                }
                if showCamera {
                    Text(event.camera.prettyName).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(event.startDate, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                if !event.zones.isEmpty {
                    Text(event.zones.map(\.prettyName).joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

enum LabelIcon {
    static func symbol(for label: String) -> String {
        switch label {
        case "person": "figure.walk"
        case "car", "truck", "motorcycle", "bus": "car.fill"
        case "bicycle": "bicycle"
        case "dog", "cat": "pawprint.fill"
        case "bird": "bird.fill"
        case "package": "shippingbox.fill"
        case "face": "face.smiling"
        case "license_plate": "rectangle.and.text.magnifyingglass"
        default: "viewfinder"
        }
    }
}
