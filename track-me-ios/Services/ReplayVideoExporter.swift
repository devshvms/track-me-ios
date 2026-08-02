import AVFoundation
import CoreGraphics
import CoreLocation
import UIKit
import MapKit

enum ReplayVideoExporterError: Error {
    case invalidRoute
    case writerFailed(String)
    case cancelled
}

enum ReplayVideoExporter {
    static func export(
        points: [GPSPoint],
        stats: ReplayStats,
        config: ReplayExportConfig,
        outputDirectory: URL,
        mapSnapshot: UIImage?,
        routeProjection: [(CGFloat, CGFloat)]?,
        onProgress: @escaping (Float) -> Void
    ) async throws -> URL {
        guard points.count >= 2 else { throw ReplayVideoExporterError.invalidRoute }
        return try await Task.detached(priority: .userInitiated) {
            try await encode(points: points, stats: stats, config: config, outputDirectory: outputDirectory,
                             mapSnapshot: mapSnapshot, routeProjection: routeProjection, onProgress: onProgress)
        }.value
    }

    /// Captures only the supplied route and returns MapKit's authoritative
    /// pixel projection alongside the bitmap. Callers should pass privacy-
    /// trimmed points, never the live user-facing map.
    static func captureRouteSnapshot(points: [GPSPoint], size: CGSize) async -> (UIImage?, [(CGFloat, CGFloat)]?) {
        guard !points.isEmpty else { return (nil, nil) }
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        var minLat = coordinates[0].latitude, maxLat = minLat
        var minLon = coordinates[0].longitude, maxLon = minLon
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude); maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude); maxLon = max(maxLon, coordinate.longitude)
        }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.0001, (maxLat - minLat) * 1.5), longitudeDelta: max(0.0001, (maxLon - minLon) * 1.5)))
        options.size = size
        options.scale = await MainActor.run {
            (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.scale ?? 2
        }
        return await withCheckedContinuation { continuation in
            MKMapSnapshotter(options: options).start { snapshot, error in
                guard let snapshot, error == nil else { continuation.resume(returning: (nil, nil)); return }
                let projection = coordinates.map { point in
                    let pixel = snapshot.point(for: point)
                    return (pixel.x / options.size.width, pixel.y / options.size.height)
                }
                continuation.resume(returning: (snapshot.image, projection))
            }
        }
    }

    private static func encode(
        points: [GPSPoint], stats: ReplayStats, config: ReplayExportConfig, outputDirectory: URL,
        mapSnapshot: UIImage?, routeProjection: [(CGFloat, CGFloat)]?, onProgress: @escaping (Float) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let output = outputDirectory.appendingPathComponent("TrackMe_Replay_\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: config.width,
            kCVPixelBufferHeightKey as String: config.height,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw ReplayVideoExporterError.writerFailed("Unable to add video input") }
        writer.add(input)
        guard writer.startWriting() else { throw ReplayVideoExporterError.writerFailed(writer.error?.localizedDescription ?? "Unable to start writer") }
        writer.startSession(atSourceTime: .zero)

        let frameCount = config.targetDurationSeconds * config.fps
        var lastPublished: Float = -1
        do {
            for frame in 0..<frameCount {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 5_000_000)
                    try Task.checkCancellation()
                }
                guard let pool = adaptor.pixelBufferPool else { throw ReplayVideoExporterError.writerFailed("Missing pixel buffer pool") }
                var pixelBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else {
                    throw ReplayVideoExporterError.writerFailed("Unable to allocate frame buffer")
                }
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
                guard let base = CVPixelBufferGetBaseAddress(pixelBuffer), let context = CGContext(
                    data: base, width: config.width, height: config.height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                    throw ReplayVideoExporterError.writerFailed("Unable to create frame context")
                }
                let progress = ReplayStatsInterpolation.progressForFrame(points: points, frame: frame, frameCount: frameCount)
                let frameStats = ReplayStatsInterpolation.replayStatsAtProgress(points: points, progress: progress, fallback: stats)
                ReplayFrameRenderer.render(context: context, points: points, progress: Double(progress), persona: config.persona,
                                           stats: frameStats, config: config, mapSnapshot: mapSnapshot, routeProjection: routeProjection)
                let time = CMTime(value: Int64(frame), timescale: Int32(config.fps))
                guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                    throw ReplayVideoExporterError.writerFailed(writer.error?.localizedDescription ?? "Unable to append frame")
                }
                let current = Float(frame + 1) / Float(frameCount)
                if current - lastPublished >= 0.02 || frame == frameCount - 1 {
                    lastPublished = current
                    await MainActor.run { onProgress(current) }
                }
            }
            input.markAsFinished()
            await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
            guard writer.status == .completed else { throw ReplayVideoExporterError.writerFailed(writer.error?.localizedDescription ?? "Video encoding failed") }
            return output
        } catch is CancellationError {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: output); throw ReplayVideoExporterError.cancelled
        } catch {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: output)
            if error is ReplayVideoExporterError { throw error }
            throw ReplayVideoExporterError.writerFailed(error.localizedDescription)
        }
    }
}
