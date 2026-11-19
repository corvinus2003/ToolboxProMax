import AVFoundation
import CoreImage
import PDFKit

/// The kinds of data that travel along the wires.
enum PortType: String, Codable, CaseIterable {
    case image, images, video, audio, pdf, text
    /// Placeholder used by transforms: "whatever visual thing came in" (image, images or video).
    case visual

    var label: String {
        switch self {
        case .image: "Image"
        case .images: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .text: "Text"
        case .visual: "Picture"
        }
    }

    /// Concrete types this port can stand for.
    var concrete: Set<PortType> {
        self == .visual ? [.image, .images, .video] : [self]
    }
}

/// A frame effect, applied to a still image or to every frame of a video.
/// `scale` is how big the working copy is compared to the original (1 at render time, smaller in previews),
/// so effects that think in pixels look the same in the preview as in the final file.
typealias FrameEffect = (CIImage, CGFloat) -> CIImage

struct NamedImage {
    var name: String
    var image: CIImage
    var scale: CGFloat = 1
}

struct VideoClip {
    var url: URL
    var name: String
    var start: Double = 0
    var end: Double? = nil
    var effects: [FrameEffect] = []
}

struct AudioClip {
    var buffer: AVAudioPCMBuffer
    var name: String

    var duration: Double { Double(buffer.frameLength) / buffer.format.sampleRate }
}

enum Value {
    case image(NamedImage)
    case images([NamedImage])
    case video(VideoClip)
    case audio(AudioClip)
    case pdf(PDFDocument, name: String)
    case text(String)

    var type: PortType {
        switch self {
        case .image: .image
        case .images: .images
        case .video: .video
        case .audio: .audio
        case .pdf: .pdf
        case .text: .text
        }
    }

    var name: String {
        switch self {
        case .image(let i): i.name
        case .images(let l): l.first?.name ?? "images"
        case .video(let v): v.name
        case .audio(let a): a.name
        case .pdf(_, let n): n
        case .text: "text"
        }
    }
}

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
