import CoreImage
import Vision

/// The bits Cojo would need a whole ML stack for, and a Mac just has.
enum VisionOps {
    private static let warmLock = NSLock()
    nonisolated(unsafe) private static var warmed = false

    /// The accurate text model takes ~25 s to load the first time in each launch, so load it quietly
    /// in the background as soon as a Read Text node shows up. Previews use the fast model meanwhile.
    static func warmUp() {
        warmLock.lock(); defer { warmLock.unlock() }
        guard !warmed else { return }
        warmed = true
        Task.detached(priority: .background) {
            let blank = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
            _ = try? recognizeText(blank, fast: false)
        }
    }

    /// Reads printed or handwritten text in an image (Live Text).
    static func recognizeText(_ image: CIImage, fast: Bool) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(ciImage: image)
        try handler.perform([request])
        let observations = request.results ?? []
        // keep reading order: top to bottom, then left to right
        let sorted = observations.sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY
                : $0.boundingBox.minX < $1.boundingBox.minX
        }
        return sorted.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Cuts the main subject out of a photo, like long-pressing a photo on an iPhone.
    static func liftSubject(_ image: CIImage, background: String, cropToSubject: Bool) throws -> CIImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: image)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ToolError("No subject found in this picture")
        }
        let maskBuffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        let sx = image.extent.width / mask.extent.width, sy = image.extent.height / mask.extent.height
        mask = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        let backdrop: CIImage = switch background {
        case "white": CIImage(color: .white).cropped(to: image.extent)
        case "black": CIImage(color: .black).cropped(to: image.extent)
        case "blur": image.clampedToExtent().applyingGaussianBlur(sigma: max(8, image.extent.width / 60)).cropped(to: image.extent)
        default: CIImage(color: .clear).cropped(to: image.extent)
        }
        var out = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: backdrop, kCIInputMaskImageKey: mask,
        ])
        if cropToSubject {
            let box = VNImageRectForNormalizedRect(boundingBox(of: maskBuffer), Int(image.extent.width), Int(image.extent.height))
            if box.width > 1, box.height > 1 { out = CI.normalized(out.cropped(to: box.integral)) }
        }
        return out
    }

    /// Normalized bounding box of the non-zero area of a one-channel float mask.
    private static func boundingBox(of buffer: CVPixelBuffer) -> CGRect {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float
        else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<w where row[x] > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        // buffer rows go top-down; Vision rects are bottom-up
        return CGRect(x: CGFloat(minX) / CGFloat(w), y: 1 - CGFloat(maxY + 1) / CGFloat(h),
                      width: CGFloat(maxX - minX + 1) / CGFloat(w), height: CGFloat(maxY - minY + 1) / CGFloat(h))
    }
}
