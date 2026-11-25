import SwiftUI

/// Black full-screen viewer for a camera. It stays in whatever orientation the phone
/// is in; turn the phone to watch in landscape.
/// Tap the picture to show or hide the controls.
struct FullScreenCamera<Content: View, Controls: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: () -> Content
    @ViewBuilder var controls: () -> Controls

    @State private var showsControls = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() } }

            if showsControls {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.body.weight(.semibold))
                                .frame(width: 40, height: 40)
                                .background(.black.opacity(0.55), in: Circle())
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Exit Full Screen")
                    }
                    Spacer()
                    controls()
                }
                .padding()
                .transition(.opacity)
            }
        }
        // Controls are always light-on-dark here, whatever the app's appearance.
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

/// The small button in the corner of a camera picture that opens full screen.
struct FullScreenButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.subheadline.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.55), in: Circle())
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Full Screen")
    }
}
