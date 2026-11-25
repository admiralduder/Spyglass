import SwiftUI
import UIKit

extension View {
    /// Pinch to zoom in (up to 6×); move your fingers while pinching to pan.
    /// While zoomed, drag with one finger to pan, and double-tap to zoom in 2× or back out.
    ///
    /// On its own, the view zooms inside its own frame. Inside a `zoomViewport`
    /// (full screen), it zooms out to fill that whole area instead.
    func pinchToZoom() -> some View { modifier(PinchToZoom()) }

    /// Makes this area the place zoomed content can fill, and handles the zoom gestures
    /// for any `pinchToZoom()` content inside it.
    func zoomViewport(_ zoom: ZoomModel) -> some View { modifier(ZoomViewport(zoom: zoom)) }
}

/// Zoom and pan for one viewport.
@MainActor @Observable
final class ZoomModel {
    static let maxScale: CGFloat = 6

    fileprivate(set) var scale: CGFloat = 1
    fileprivate(set) var offset: CGSize = .zero
    /// The viewport's size, and the content's frame within it (before zooming).
    fileprivate var viewport: CGSize = .zero { didSet { if oldValue != viewport { reset() } } }
    fileprivate var content: CGRect = .zero

    @ObservationIgnored private var pinchStart: (scale: CGFloat, offset: CGSize, point: CGPoint)?
    @ObservationIgnored private var lastDrag: CGSize?

    var isZoomed: Bool { scale > 1.01 }
    private var isPinching: Bool { pinchStart != nil }

    func reset() {
        scale = 1
        offset = .zero
    }

    // MARK: Gestures

    /// `magnification` is relative to the pinch's start; `point` is between the fingers.
    fileprivate func pinchChanged(magnification: CGFloat, point: CGPoint) {
        let start = pinchStart ?? (scale, offset, point)
        pinchStart = start
        // Allow a little rubber band below 1× while pinching.
        let target = min(Self.maxScale, max(0.8, start.scale * magnification))
        transform(to: target, from: start, at: point)
    }

    fileprivate func pinchEnded() {
        pinchStart = nil
        withAnimation(.snappy(duration: 0.25)) {
            if scale < 1.05 { reset() } else { offset = clamped(offset) }
        }
    }

    fileprivate func dragChanged(_ translation: CGSize) {
        // Applies only the movement since last time, so lifting a finger
        // at the end of a pinch doesn't make the picture jump.
        let last = lastDrag ?? translation
        lastDrag = translation
        guard isZoomed, !isPinching else { return }
        offset = clamped(CGSize(width: offset.width + translation.width - last.width,
                                height: offset.height + translation.height - last.height))
    }

    fileprivate func dragEnded() { lastDrag = nil }

    fileprivate func doubleTapped(at point: CGPoint) {
        withAnimation(.snappy(duration: 0.3)) {
            if isZoomed { reset() } else { transform(to: 2, from: (1, .zero, point), at: point) }
        }
    }

    // MARK: Math (all in viewport coordinates)

    /// Scales so the content that was under `start.point` is now under `point`.
    /// Moving the fingers together pans; spreading them zooms around them.
    private func transform(to newScale: CGFloat, from start: (scale: CGFloat, offset: CGSize, point: CGPoint),
                           at point: CGPoint) {
        let center = CGPoint(x: content.midX, y: content.midY)
        let ratio = newScale / start.scale
        scale = newScale
        offset = clamped(CGSize(
            width: point.x - center.x - (start.point.x - center.x - start.offset.width) * ratio,
            height: point.y - center.y - (start.point.y - center.y - start.offset.height) * ratio))
    }

    /// Where zoomed content is bigger than the viewport, it must cover it (no empty edges).
    /// Where it's still smaller, it stays between its own spot and the middle.
    private func clamped(_ o: CGSize) -> CGSize {
        CGSize(width: clamp(o.width, center: content.midX, length: content.width * scale, viewport: viewport.width),
               height: clamp(o.height, center: content.midY, length: content.height * scale, viewport: viewport.height))
    }

    private func clamp(_ value: CGFloat, center: CGFloat, length: CGFloat, viewport: CGFloat) -> CGFloat {
        let lower: CGFloat, upper: CGFloat
        if length >= viewport {
            lower = viewport - center - length / 2
            upper = length / 2 - center
        } else {
            lower = min(0, viewport / 2 - center)
            upper = max(0, viewport / 2 - center)
        }
        return min(upper, max(lower, value))
    }
}

private let viewportSpace = "zoomViewport"

private extension EnvironmentValues {
    @Entry var zoomModel: ZoomModel?
}

/// Handles the gestures and clips to its frame; zoomed content inside fills this area.
private struct ZoomViewport: ViewModifier {
    let zoom: ZoomModel

    func body(content: Content) -> some View {
        content
            .environment(\.zoomModel, zoom)
            .coordinateSpace(.named(viewportSpace))
            .contentShape(Rectangle())
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { zoom.viewport = $0 }
            .modifier(PinchGesture(changed: zoom.pinchChanged, ended: zoom.pinchEnded))
            // One-finger panning only while zoomed, so it doesn't block swipe-back otherwise.
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { zoom.dragChanged($0.translation) }
                    .onEnded { _ in zoom.dragEnded() },
                including: zoom.isZoomed ? .all : .subviews)
            .onTapGesture(count: 2) { zoom.doubleTapped(at: $0) }
    }
}

/// Zooms the content using the surrounding viewport's zoom, or its own if there isn't one.
private struct PinchToZoom: ViewModifier {
    @Environment(\.zoomModel) private var outerZoom
    @State private var ownZoom = ZoomModel()

    func body(content: Content) -> some View {
        if let outerZoom {
            zoomed(content, by: outerZoom)
        } else {
            zoomed(content, by: ownZoom).zoomViewport(ownZoom)
        }
    }

    private func zoomed(_ content: Content, by zoom: ZoomModel) -> some View {
        content
            .scaleEffect(zoom.scale)
            .offset(zoom.offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Measured outside the zoom effects, so this is the unzoomed frame.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(viewportSpace)) } action: {
                zoom.content = $0
            }
    }
}

/// A pinch that also reports where the fingers are, so moving them pans.
/// Uses UIKit's pinch on iOS 18 and later; iOS 17 only has SwiftUI's, which can zoom
/// toward where the pinch started but can't follow the fingers.
private struct PinchGesture: ViewModifier {
    let changed: (_ magnification: CGFloat, _ point: CGPoint) -> Void
    let ended: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.gesture(UIKitPinch(changed: changed, ended: ended))
        } else {
            content.gesture(
                MagnifyGesture()
                    .onChanged { value in
                        // startLocation is where the pinch began, in the view's coordinates.
                        changed(value.magnification, value.startLocation)
                    }
                    .onEnded { _ in ended() }
            )
        }
    }
}

@available(iOS 18, *)
private struct UIKitPinch: UIGestureRecognizerRepresentable {
    let changed: (CGFloat, CGPoint) -> Void
    let ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        UIPinchGestureRecognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPinchGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            // With one finger lifted mid-pinch, the point jumps; wait for both again.
            guard recognizer.numberOfTouches >= 2 else { return }
            changed(recognizer.scale, context.converter.localLocation)
        case .ended, .cancelled, .failed:
            ended()
        default:
            break
        }
    }
}
