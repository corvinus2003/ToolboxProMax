import Foundation

/// Ready-made chains you can drop into the graph.
struct Workflow: Identifiable {
    struct Step { let kind: String; var params: [String: ParamValue] = [:] }
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let steps: [Step]

    static let all: [Workflow] = [
        Workflow(id: "yt-video", title: "Download a YouTube video", symbol: "play.rectangle.fill",
                 summary: "Paste a link, press Render, get an MP4.",
                 steps: [Step(kind: "download"), Step(kind: "exportVideo", params: ["format": .text("original")])]),
        Workflow(id: "yt-audio", title: "YouTube to audio", symbol: "music.note",
                 summary: "Just the sound, as an M4A.",
                 steps: [Step(kind: "download", params: ["mode": .text("audio")]), Step(kind: "normalize"), Step(kind: "exportAudio")]),
        Workflow(id: "extract", title: "Extract audio from a video", symbol: "waveform",
                 summary: "Pull the soundtrack out of any movie file.",
                 steps: [Step(kind: "video"), Step(kind: "extractAudio"), Step(kind: "exportAudio")]),
        Workflow(id: "gif", title: "Video to GIF", symbol: "photo.badge.arrow.down",
                 summary: "The first five seconds, as a looping GIF.",
                 steps: [Step(kind: "video"), Step(kind: "trimVideo", params: ["end": .number(5)]),
                         Step(kind: "exportVideo", params: ["format": .text("gif")])]),
        Workflow(id: "photos-pdf", title: "Photos to PDF", symbol: "doc.richtext",
                 summary: "A folder of pictures becomes one numbered PDF.",
                 steps: [Step(kind: "images"), Step(kind: "imagesToPDF"), Step(kind: "pageNumbers"), Step(kind: "exportPDF")]),
        Workflow(id: "retro", title: "Retro dithered video", symbol: "circle.grid.3x3.fill",
                 summary: "Make any clip look like an old handheld.",
                 steps: [Step(kind: "video"), Step(kind: "resize", params: ["percent": .number(50)]),
                         Step(kind: "dither", params: ["palette": .text("gameboy")]), Step(kind: "exportVideo")]),
        Workflow(id: "lift", title: "Cut out a subject", symbol: "person.crop.rectangle",
                 summary: "Remove the background from a photo.",
                 steps: [Step(kind: "image"), Step(kind: "lift"), Step(kind: "exportImage", params: ["format": .text("png")])]),
        Workflow(id: "ocr", title: "Copy text from a photo", symbol: "text.viewfinder",
                 summary: "Screenshots, receipts, scans → text.",
                 steps: [Step(kind: "image"), Step(kind: "ocr"), Step(kind: "exportText")]),
        Workflow(id: "web", title: "Shrink photos for the web", symbol: "arrow.down.right.and.arrow.up.left",
                 summary: "A batch of photos, 1600 px wide, light JPEGs.",
                 steps: [Step(kind: "images"), Step(kind: "resize", params: ["mode": .text("width"), "width": .number(1600)]),
                         Step(kind: "exportImage", params: ["quality": .number(0.8)])]),
        Workflow(id: "ascii", title: "ASCII art poster", symbol: "character.textbox",
                 summary: "A photo redrawn in colored letters.",
                 steps: [Step(kind: "image"), Step(kind: "ascii"), Step(kind: "exportImage", params: ["format": .text("png")])]),
    ]
}
