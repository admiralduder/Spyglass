import SwiftUI
import UIKit

/// Loads an image through `FrigateClient` (so auth cookies and self-signed trust apply).
/// Pass `refreshInterval` to keep re-fetching, which turns `latest.jpg` into a live view.
struct RemoteImage: View {
    @Environment(FrigateClient.self) private var client

    let makeURL: () throws -> URL
    var refreshInterval: Duration? = nil
    var contentMode: ContentMode = .fit

    @State private var image: UIImage?
    @State private var error: String?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let error {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).font(.caption2).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(8)
            } else {
                ProgressView()
            }
        }
        .task {
            await load()
            guard let refreshInterval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: refreshInterval)
                await load()
            }
        }
    }

    private func load() async {
        do {
            let data = try await client.data(from: makeURL())
            if let img = UIImage(data: data) {
                image = img
                error = nil
            }
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            // Keep the last good frame on a transient failure.
            if image == nil { self.error = error.localizedDescription }
        }
    }
}
