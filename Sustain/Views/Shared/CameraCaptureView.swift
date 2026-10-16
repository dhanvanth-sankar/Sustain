import AVFoundation
import SwiftUI

/// The branded camera viewfinder — reticle corners, "Point at your plate," a
/// teal-ringed shutter button — every marketing screenshot and the video ad
/// show for the AI photo-estimate feature (`App Store Assets/Marketing
/// Screenshots/07-ai-camera-viewfinder.png`; `marketing/v3_build/assets/
/// 08-photo-viewfinder.png`). None of that was ever real in-app UI: the actual
/// camera step was — until this file — a bare `UIImagePickerController` with
/// Apple's stock, unbranded system camera chrome (see `ImagePicker.swift`).
/// `marketing/VIDEO_AD_HANDOFF.md` §8.6a documents the viewfinder screenshot as
/// a composited mockup built in a Python script specifically *because* no real
/// equivalent existed to screenshot. This closes that gap: what ships now is
/// what the marketing has been showing all along, not a fabricated ideal of it.
///
/// Built with first-party `AVFoundation` (`AVCaptureSession` +
/// `AVCaptureVideoPreviewLayer` + `AVCapturePhotoOutput`), matching the
/// project's zero-third-party-SPM-dependency posture (`PROJECT_HANDOFF.md`
/// Decision 2) — no new package. `ImagePicker.swift`'s `UIImagePickerController`
/// wrapper is unchanged and still used for the photo-library path, since a
/// custom viewfinder only makes sense for the live-camera case; picking an
/// existing photo has no equivalent "point your camera" moment to brand.
///
/// **2026-08-01, safe-area fix (fourth attempt)**: reported directly from
/// device screenshots, the close button overlapped the status bar/Dynamic
/// Island. Three attempts using SwiftUI's own safe-area mechanisms each
/// failed on a real device for the same underlying reason — this view has to
/// render a full-bleed camera preview, and SwiftUI's safe-area value reads as
/// zero anywhere inside a subtree that's ignoring the safe area, which is
/// every part of this view. The close button now pads itself using
/// `windowSafeAreaInsets` (read from the UIKit key window, outside SwiftUI's
/// layout system entirely); see that property's doc comment for each failed
/// approach and exactly why it reported zero.
struct CameraCaptureView: View {
    // Caught during manual testing (2026-08-03, section 6.7): this view is
    // shared by three features now — the original protein-photo estimate,
    // progress photos, and lab result import — but the viewfinder caption
    // and permission-denied copy were both hardcoded to the protein-estimate
    // wording ("Point at your plate," "...to estimate protein from a photo
    // of your food"). That's simply wrong when someone's about to photograph
    // themselves for a progress photo or a lab report, not food. Defaults
    // preserve the exact existing copy, so the two call sites that actually
    // are the protein estimate (`LogProteinView`, `DashboardView`) need no
    // changes; `ProgressPhotosView` and `LabResultsView` now pass their own.
    //
    // Declared BEFORE `onImagePicked` below — a real compile error, caught on
    // the next build after adding these: the synthesized memberwise init
    // orders its parameters by declaration order, and trailing-closure call
    // sites (`CameraCaptureView(...) { image in ... }`, used everywhere this
    // view is constructed) always bind to the *last* parameter. With these
    // two declared after `onImagePicked`, the trailing closure was being
    // matched against `permissionDeniedMessage` (a String) instead, which is
    // exactly the "incorrect argument labels" error Xcode reported.
    var instructionText: String = "Point at your plate"
    var permissionDeniedMessage: String = "Sustain uses your camera to estimate protein from a photo of your food. Enable camera access in Settings to use this."
    let onImagePicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var controller = CameraCaptureController()
    @State private var focusRingPosition: CGPoint?
    // Regenerated on every tap so the `.task(id:)` driving the ring's
    // auto-dismiss always restarts, even if someone taps the exact same spot
    // twice in a row (a plain `focusRingPosition` change wouldn't fire a new
    // task in that case, since the value wouldn't actually change).
    @State private var focusRingToken = UUID()

    /// The real device safe-area insets, read from the UIKit key window
    /// rather than from SwiftUI.
    ///
    /// This exists because every SwiftUI-native way of asking the same
    /// question returns zero inside this particular view, and three separate
    /// attempts to fix the close button's status-bar collision with those
    /// mechanisms each failed on a real device:
    ///
    /// 1. Relying on sibling views (only the background/preview calling
    ///    `.ignoresSafeArea()`, close button using plain `.padding`) — the
    ///    bleeding siblings still grew the enclosing `ZStack` to full-bleed,
    ///    so the close button positioned against the expanded frame.
    /// 2. `.safeAreaPadding` on the close button, under a whole-view
    ///    `.ignoresSafeArea()` — `.safeAreaPadding` reads the environment's
    ///    safe-area value, which that same `.ignoresSafeArea()` had already
    ///    zeroed for the entire subtree.
    /// 3. `GeometryReader.safeAreaInsets` at the view root — a
    ///    `GeometryReader` reports the insets of the region *it* occupies, and
    ///    the `.ignoresSafeArea()` applied to that same reader made it occupy
    ///    the full bleed area, so it too reported zero. (`0 + 12` is exactly
    ///    the 12pt gap visible in the device screenshot that caught it.)
    ///
    /// The common thread: this view has to render a genuinely full-bleed
    /// camera preview, and SwiftUI's safe-area value is scoped to a subtree
    /// that is, by design, ignoring the safe area. UIKit's window insets are
    /// a property of the window itself, so they're unaffected by anything in
    /// the SwiftUI layout tree and report the true values (roughly 59pt top
    /// on a Dynamic Island phone, 47pt on a notched one, 20pt on an SE)
    /// regardless of how this view lays itself out.
    ///
    /// The fallback matters for correctness, not just safety: returning
    /// `.zero` if no key window is found would silently reintroduce the
    /// original bug, so it falls back to 44pt top / 20pt bottom — enough to
    /// clear the status bar on any device this app supports (iOS 17+), erring
    /// toward slightly too much padding rather than an overlap.
    private static var windowSafeAreaInsets: UIEdgeInsets {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return keyWindow?.safeAreaInsets ?? UIEdgeInsets(top: 44, left: 0, bottom: 20, right: 0)
    }

    var body: some View {
        // Everything here is deliberately full-bleed (`.ignoresSafeArea()` on
        // the whole `ZStack`), and the two overlays that must stay clear of
        // system UI pad themselves using `Self.windowSafeAreaInsets` — a
        // value read straight from the UIKit key window, NOT from SwiftUI's
        // safe-area environment. See that property's doc comment and this
        // struct's header for the three failed attempts that led here; the
        // short version is that every SwiftUI-native mechanism for this
        // (`.safeAreaPadding`, `GeometryReader.safeAreaInsets`, sibling views
        // independently respecting the safe area) reports zero once anything
        // in the same subtree ignores the safe area, which this view
        // fundamentally has to do to render a full-bleed camera preview.
        ZStack {
            Color.black

            if controller.isAuthorized {
                // Tap-to-focus, added 2026-08-03 per manual testing feedback
                // — the system Camera app supports this and its absence here
                // was conspicuous by comparison. `CameraPreviewLayerView`
                // owns the gesture (rather than a SwiftUI `.onTapGesture`
                // here) because converting a tap into a focus point requires
                // `AVCaptureVideoPreviewLayer.captureDevicePointConverted`,
                // which needs the actual preview layer instance — that's
                // UIKit-side state a SwiftUI gesture on this view wouldn't
                // have access to without re-deriving the same geometry by
                // hand and risking it drifting out of sync with the real
                // layer.
                CameraPreviewLayerView(session: controller.session) { layerPoint, devicePoint in
                    controller.focus(at: devicePoint)
                    focusRingPosition = layerPoint
                    focusRingToken = UUID()
                }

                if let ringPosition = focusRingPosition {
                    Circle()
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 70, height: 70)
                        .position(ringPosition)
                        .allowsHitTesting(false)
                        .task(id: focusRingToken) {
                            // Auto-dismiss after a beat, matching the system
                            // Camera app's own focus-square behavior. Keyed
                            // to `focusRingToken` (not a plain `.onAppear` +
                            // timer) so a second tap while the ring is still
                            // visible cancels this wait and restarts it at
                            // the new position, instead of two overlapping
                            // timers racing to clear the same state.
                            //
                            // Real compile error, caught on first build: the
                            // `if let focusRingPosition { ... }` shorthand
                            // used previously shadowed the `@State` property
                            // with a local immutable `let` of the same name
                            // for the rest of this block — so `focusRingPosition
                            // = nil` right here was trying to assign to that
                            // local constant, not the state property. Explicit
                            // `if let ringPosition = focusRingPosition` avoids
                            // the shadow entirely.
                            try? await Task.sleep(for: .seconds(0.6))
                            guard !Task.isCancelled else { return }
                            focusRingPosition = nil
                        }
                }

                // Top/bottom gradient scrims, matching what the marketing
                // mockup this view is standing in for always specified
                // (`marketing/VIDEO_AD_HANDOFF.md` §8.6a: "a top/bottom
                // gradient scrim so that chrome stays legible over any
                // photo") but the real build never actually had. Without
                // this, the white reticle/text/buttons sit directly on the
                // raw camera feed and wash out completely against a bright
                // background (a white plate, a light countertop) — exactly
                // the kind of surface someone photographing food is likely
                // to be pointed at.
                VStack {
                    LinearGradient(
                        colors: [.black.opacity(0.45), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 140)
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 220)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)

                reticle
                    .padding(.horizontal, 32)
                    .padding(.top, 100)
                    .padding(.bottom, 160)

                VStack {
                    Spacer()
                    Text(instructionText)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                        .padding(.bottom, 28)

                    shutterButton
                        // Clears the home indicator on devices that have one,
                        // same mechanism and same reasoning as the close
                        // button below.
                        .padding(.bottom, Self.windowSafeAreaInsets.bottom + 24)
                }
            } else {
                permissionDeniedState
            }

            VStack {
                HStack {
                    closeButton
                    Spacer()
                }
                Spacer()
            }
            .padding(.top, Self.windowSafeAreaInsets.top + 12)
            .padding(.leading, Self.windowSafeAreaInsets.left + 12)
        }
        .ignoresSafeArea()
        // Forced dark, regardless of the device's own light/dark setting —
        // matches every native full-screen camera UI (the system Camera app
        // never switches to a light appearance), and specifically makes
        // `.ultraThinMaterial` on the close button render as frosted-dark
        // glass rather than picking up a light-mode tint that wouldn't read
        // against a camera feed.
        .environment(\.colorScheme, .dark)
        .statusBarHidden(false)
        .task {
            await controller.start()
        }
        .onDisappear {
            controller.stop()
        }
        .onChange(of: controller.capturedImage) { _, newImage in
            guard let newImage else { return }
            onImagePicked(newImage)
            dismiss()
        }
    }

    // Four independent corner brackets rather than a single stroked rounded
    // rectangle — matches the marketing screenshot's open-cornered reticle
    // (each corner is a short two-segment "L," not a continuous frame), which
    // reads as a camera-app viewfinder convention, not an arbitrary box.
    private var reticle: some View {
        GeometryReader { proxy in
            let corner: CGFloat = 28
            let lineWidth: CGFloat = 2.5
            ForEach(0..<4, id: \.self) { index in
                let isTop = index < 2
                let isLeading = index % 2 == 0
                Path { path in
                    let x: CGFloat = isLeading ? 0 : proxy.size.width
                    let y: CGFloat = isTop ? 0 : proxy.size.height
                    let dx: CGFloat = isLeading ? corner : -corner
                    let dy: CGFloat = isTop ? corner : -corner
                    path.move(to: CGPoint(x: x, y: y + dy))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x + dx, y: y))
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
    }

    private var shutterButton: some View {
        Button {
            controller.capturePhoto()
        } label: {
            ZStack {
                Circle()
                    .stroke(Theme.primary, lineWidth: 4)
                    .frame(width: 74, height: 74)
                Circle()
                    .fill(.white)
                    .frame(width: 62, height: 62)
            }
        }
        .disabled(controller.isCapturing)
        .accessibilityLabel("Take photo")
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                // `.ultraThinMaterial` instead of a flat translucent black —
                // a frosted-glass circle picks up whatever's actually behind
                // it (matching the system camera app's own chrome, and every
                // other native full-screen camera-style control), which
                // reads as considered polish rather than a plain dark dot
                // regardless of what's in frame.
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
        .accessibilityLabel("Cancel")
    }

    private var permissionDeniedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.7))
            Text("Camera access needed")
                .font(.headline)
                .foregroundStyle(.white)
            Text(permissionDeniedMessage)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.primary)
        }
    }
}

/// Thin `UIViewRepresentable` wrapper so `AVCaptureVideoPreviewLayer` — a
/// `CALayer`, not a `UIView` — can participate in SwiftUI layout. Mirrors
/// `ImagePicker.swift`'s existing pattern of a small, single-purpose UIKit
/// bridge rather than a heavier abstraction.
private struct CameraPreviewLayerView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Added 2026-08-03 for tap-to-focus. Passes both the tap's point in the
    /// view's own coordinate space (for `CameraCaptureView` to position the
    /// focus-ring overlay) and the corresponding device point (for
    /// `CameraCaptureController.focus(at:)`, which AVFoundation expects in
    /// `{0,0}`–`{1,1}` device space, not screen points).
    var onTap: (_ layerPoint: CGPoint, _ devicePoint: CGPoint) -> Void = { _, _ in }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tapGesture)
        view.isUserInteractionEnabled = true
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    final class Coordinator: NSObject {
        var onTap: (_ layerPoint: CGPoint, _ devicePoint: CGPoint) -> Void
        init(onTap: @escaping (_ layerPoint: CGPoint, _ devicePoint: CGPoint) -> Void) {
            self.onTap = onTap
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PreviewUIView else { return }
            let layerPoint = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            onTap(layerPoint, devicePoint)
        }
    }
}

/// Owns the `AVCaptureSession` lifecycle and photo capture. `@Observable` so
/// `CameraCaptureView` re-renders on authorization/capture state changes
/// without a manual Combine subscription. Session start/stop and configuration
/// happen off the main thread on a dedicated serial queue, per Apple's own
/// guidance (`AVCaptureSession.startRunning()` is a blocking call) — mirrors
/// this app's existing "never block the main thread on I/O" posture from
/// `SustainApp`'s async `ModelContainer` setup.
@Observable
final class CameraCaptureController: NSObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.sustainapp.glp1.camera-session")
    private var isConfigured = false
    /// Kept around specifically so `focus(at:)` has something to configure —
    /// `AVCaptureDevice.default(...)` is cheap enough to call again, but
    /// re-fetching it on every tap would still mean two different
    /// `AVCaptureDevice` instances could end up modified independently if the
    /// available default ever changed mid-session (unlikely on a fixed back
    /// wide-angle camera, but free to avoid entirely by storing the one
    /// actually added to the session in `configureIfNeeded()`).
    private var captureDevice: AVCaptureDevice?

    var isAuthorized = false
    var isCapturing = false
    var capturedImage: UIImage?

    func start() async {
        isAuthorized = await requestAccessIfNeeded()
        guard isAuthorized else { return }
        sessionQueue.async { [weak self] in
            self?.configureIfNeeded()
            self?.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    func capturePhoto() {
        guard !isCapturing else { return }
        isCapturing = true
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .auto
        sessionQueue.async { [weak self] in
            self?.photoOutput.capturePhoto(with: settings, delegate: self ?? AVCapturePhotoCaptureDelegateNoop())
        }
    }

    /// Added 2026-08-03 (tap-to-focus). `devicePoint` is already in
    /// AVFoundation's `{0,0}`–`{1,1}` normalized device space — see
    /// `CameraPreviewLayerView.Coordinator.handleTap` for the conversion
    /// from an actual screen tap. Locks focus and exposure to that point
    /// with `.autoFocus`/`.autoExpose` (a one-shot re-focus, matching the
    /// system Camera app's tap behavior) rather than
    /// `.continuousAutoFocus`/`.continuousAutoExposure`, since a repeated
    /// continuous mode would keep hunting after the tap instead of settling
    /// on the point the person actually chose.
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                // Focus is a nice-to-have on top of a working camera, not a
                // critical path — silently keeping whatever focus/exposure
                // was already in effect is a far better failure mode here
                // than surfacing an error over what's otherwise a fully
                // working capture flow.
            }
        }
    }

    private func requestAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            captureDevice = device
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        session.commitConfiguration()
        isConfigured = true
    }
}

extension CameraCaptureController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        defer { Task { @MainActor [weak self] in self?.isCapturing = false } }
        guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else { return }
        Task { @MainActor [weak self] in
            self?.capturedImage = image
        }
    }
}

/// Never actually invoked (the `self ?? ...` in `capturePhoto()` only exists to
/// satisfy the non-optional delegate parameter if `self` were ever nil, which
/// can't happen given the closure captures `self` weakly but the object owns
/// the queue it's dispatching onto) — a harmless, silent fallback rather than
/// a force-unwrap, since a crash inside a photo-capture callback would be a far
/// worse failure mode than a single silently-dropped capture.
private final class AVCapturePhotoCaptureDelegateNoop: NSObject, AVCapturePhotoCaptureDelegate {}

#Preview {
    CameraCaptureView(onImagePicked: { _ in })
}
