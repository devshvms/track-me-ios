import AVFoundation
import SwiftUI
import UIKit

nonisolated enum OnboardingClipKind: String {
    case welcome
    case together
}

/** Pure policy shared by the view and forced reduced-motion/decode-failure tests. */
nonisolated enum OnboardingClipPolicy {
    static func shouldRenderVideo(
        reduceMotion: Bool,
        assetAvailable: Bool,
        playerFailed: Bool
    ) -> Bool {
        !reduceMotion && assetAvailable && !playerFailed
    }

    static func shouldPlay(isActive: Bool, sceneIsActive: Bool, canRender: Bool) -> Bool {
        isActive && sceneIsActive && canRender
    }
}

/// Theme-aware, silent onboarding loop that always keeps the existing vector art underneath it.
struct OnboardingClip<Fallback: View>: View {
    let kind: OnboardingClipKind
    let isActive: Bool
    private let fallback: Fallback

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var playerFailed = false
    @State private var renderedFirstFrame = false

    init(
        kind: OnboardingClipKind,
        isActive: Bool,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.kind = kind
        self.isActive = isActive
        self.fallback = fallback()
    }

    private var resourceName: String {
        "onboarding_\(kind.rawValue)_\(colorScheme == .dark ? "dark" : "light")"
    }

    private var assetURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "mp4")
    }

    private var canRenderVideo: Bool {
        OnboardingClipPolicy.shouldRenderVideo(
            reduceMotion: reduceMotion,
            assetAvailable: assetURL != nil,
            playerFailed: playerFailed
        )
    }

    var body: some View {
        ZStack {
            fallback
                .opacity(renderedFirstFrame && canRenderVideo ? 0 : 1)

            if canRenderVideo, let assetURL {
                OnboardingLoopingPlayerView(
                    assetURL: assetURL,
                    shouldPlay: OnboardingClipPolicy.shouldPlay(
                        isActive: isActive,
                        sceneIsActive: scenePhase == .active,
                        canRender: canRenderVideo
                    ),
                    onFirstFrame: { renderedFirstFrame = true },
                    onFailure: { playerFailed = true }
                )
                .id(resourceName)
                .opacity(renderedFirstFrame ? 1 : 0)
                .allowsHitTesting(false)
            }
        }
        .onChange(of: resourceName) { _, _ in
            playerFailed = false
            renderedFirstFrame = false
        }
        .accessibilityHidden(true)
    }
}

private struct OnboardingLoopingPlayerView: UIViewRepresentable {
    let assetURL: URL
    let shouldPlay: Bool
    let onFirstFrame: () -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> OnboardingPlayerSurfaceView {
        let view = OnboardingPlayerSurfaceView()
        context.coordinator.configure(
            url: assetURL,
            surface: view,
            onFirstFrame: onFirstFrame,
            onFailure: onFailure
        )
        return view
    }

    func updateUIView(_ uiView: OnboardingPlayerSurfaceView, context: Context) {
        uiView.onFirstFrame = onFirstFrame
        context.coordinator.onFailure = onFailure
        if shouldPlay {
            context.coordinator.player?.play()
        } else {
            context.coordinator.player?.pause()
        }
    }

    static func dismantleUIView(_ uiView: OnboardingPlayerSurfaceView, coordinator: Coordinator) {
        coordinator.shutdown(surface: uiView)
    }

    final class Coordinator {
        fileprivate var player: AVQueuePlayer?
        fileprivate var onFailure: (() -> Void)?
        private var looper: AVPlayerLooper?
        private var playerStatusObservation: NSKeyValueObservation?
        private var failedItemObserver: NSObjectProtocol?

        func configure(
            url: URL,
            surface: OnboardingPlayerSurfaceView,
            onFirstFrame: @escaping () -> Void,
            onFailure: @escaping () -> Void
        ) {
            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = true
            queuePlayer.actionAtItemEnd = .none
            let templateItem = AVPlayerItem(url: url)

            player = queuePlayer
            looper = AVPlayerLooper(player: queuePlayer, templateItem: templateItem)
            self.onFailure = onFailure
            surface.onFirstFrame = onFirstFrame
            surface.attach(player: queuePlayer)

            playerStatusObservation = queuePlayer.observe(\.status, options: [.initial, .new]) {
                [weak self] player, _ in
                guard player.status == .failed else { return }
                DispatchQueue.main.async { self?.onFailure?() }
            }
            failedItemObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: nil,
                queue: .main
            ) { [weak self, weak queuePlayer] notification in
                guard let failedItem = notification.object as? AVPlayerItem,
                      queuePlayer?.items().contains(where: { $0 === failedItem }) == true else { return }
                self?.onFailure?()
            }
        }

        func shutdown(surface: OnboardingPlayerSurfaceView) {
            player?.pause()
            player?.removeAllItems()
            player = nil
            looper = nil
            playerStatusObservation = nil
            if let failedItemObserver {
                NotificationCenter.default.removeObserver(failedItemObserver)
            }
            failedItemObserver = nil
            surface.attach(player: nil)
        }
    }
}

private final class OnboardingPlayerSurfaceView: UIView {
    var onFirstFrame: (() -> Void)?
    private var readyObservation: NSKeyValueObservation?

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        playerLayer.backgroundColor = UIColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(player: AVPlayer?) {
        readyObservation = nil
        playerLayer.player = player
        guard player != nil else { return }
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) {
            [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.onFirstFrame?() }
        }
    }
}
