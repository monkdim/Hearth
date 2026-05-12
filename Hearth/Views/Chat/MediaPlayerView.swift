import AppKit
import AVKit
import SwiftUI

/// Renders generated media inline in the chat. Image → static image with
/// context-menu actions. Video → AVPlayerView. Audio → custom inline player.
struct MediaPlayerView: View {
    enum Kind {
        case image(path: String)
        case video(path: String)
        case audio(path: String)
    }

    let kind: Kind

    var body: some View {
        switch kind {
        case .image(let path):
            ImageMedia(path: path)
        case .video(let path):
            VideoMedia(path: path)
        case .audio(let path):
            AudioMedia(path: path)
        }
    }
}

// MARK: - Image

private struct ImageMedia: View {
    let path: String

    var body: some View {
        if let nsImage = NSImage(contentsOfFile: path) {
            SwiftUI.Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 480)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                )
                .contextMenu {
                    revealButton(path: path)
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.writeObjects([nsImage])
                    } label: { Label("Copy Image", systemImage: "doc.on.doc") }
                }
        } else {
            unavailable("Image")
        }
    }
}

// MARK: - Video

private struct VideoMedia: View {
    let path: String
    @State private var player: AVPlayer? = nil

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: 480)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                    )
                    .contextMenu {
                        revealButton(path: path)
                    }
            } else {
                unavailable("Video")
            }
        }
        .onAppear {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                player = AVPlayer(url: url)
            }
        }
    }
}

// MARK: - Audio

private struct AudioMedia: View {
    let path: String
    @State private var player: AVPlayer? = nil
    @State private var isPlaying: Bool = false
    @State private var duration: TimeInterval = 0
    @State private var current: TimeInterval = 0
    @State private var observer: Any?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(filename)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(format(current)) / \(format(duration))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progressFraction)
                    .progressViewStyle(.linear)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 440)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .contextMenu {
            revealButton(path: path)
        }
        .onAppear { setupPlayer() }
        .onDisappear { teardownPlayer() }
    }

    private var filename: String {
        (path as NSString).lastPathComponent
    }

    private var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(current / duration, 0), 1)
    }

    private func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func setupPlayer() {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let avPlayer = AVPlayer(url: url)
        player = avPlayer
        Task {
            do {
                let dur = try await avPlayer.currentItem?.asset.load(.duration)
                await MainActor.run {
                    duration = dur?.seconds ?? 0
                }
            } catch {}
        }
        observer = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            current = time.seconds
            if let item = avPlayer.currentItem, time >= item.duration, item.duration.seconds > 0 {
                isPlaying = false
                avPlayer.seek(to: .zero)
            }
        }
    }

    private func teardownPlayer() {
        if let observer, let player {
            player.removeTimeObserver(observer)
        }
        observer = nil
        player?.pause()
        player = nil
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }
}

// MARK: - Shared

@ViewBuilder
private func revealButton(path: String) -> some View {
    Button {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    } label: { Label("Reveal in Finder", systemImage: "folder") }
}

@ViewBuilder
private func unavailable(_ label: String) -> some View {
    Text("(\(label.lowercased()) unavailable)")
        .font(.caption)
        .foregroundStyle(.secondary)
}
