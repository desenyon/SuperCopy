import Foundation
import AppKit
import NaturalLanguage
import Vision
import ImageIO
import UniformTypeIdentifiers
import Accelerate

public protocol EmbeddingProvider: AnyObject {
    func vector(for text: String) -> [Float]?
    var available: Bool { get }
}

public final class LocalEmbedding: EmbeddingProvider {
    private lazy var model = NLEmbedding.sentenceEmbedding(for: .english)
    public init() {}
    public var available: Bool { model != nil }
    public func vector(for text: String) -> [Float]? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let result = model?.vector(for: String(text.prefix(1600))) else { return nil }
        return VectorMath.normalized(result.map(Float.init))
    }
}

public enum VectorMath {
    public static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return vector.map { $0 / norm }
    }
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        return vDSP.dot(a, b)
    }
    static func encode(_ vector: [Float]?) -> Data? { vector?.withUnsafeBytes { Data($0) } }
    static func decode(_ data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
        }
    }
}

public enum ImageRecognition {
    public static func recognize(at url: URL) -> String {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = ContentAnalysis.downsample(source, maximum: 1600) else { return "" }
            return ContentAnalysis.recognize(image)
        }
    }
}

struct ContentAnalysis {
    var title: String
    var text: String
    var kind: ClipKind
    var thumbnail: Data?
    var imageForOCR: CGImage?

    static func analyze(_ snapshot: ClipboardSnapshot) -> ContentAnalysis {
        let files = snapshot.items.compactMap(\.fileURL)
        var text = snapshot.items.compactMap { item -> String? in
            if let data = item.data(for: "public.utf8-plain-text") { return String(data: data, encoding: .utf8) }
            if let data = item.data(for: "public.utf16-external-plain-text") { return String(data: data, encoding: .utf16) }
            if let data = item.data(for: "public.rtf"),
               let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                return attributed.string
            }
            if let data = item.data(for: "public.url") { return String(data: data, encoding: .utf8) }
            return nil
        }.joined(separator: "\n")
        var kind: ClipKind = files.isEmpty ? (text.isEmpty ? .other : .text) : .file
        var image: CGImage?
        if let file = files.first {
            let type = UTType(filenameExtension: file.pathExtension)
            if type?.conforms(to: .audio) == true { kind = .audio }
            if type?.conforms(to: .image) == true {
                kind = .image
                if let source = CGImageSourceCreateWithURL(file as CFURL, nil) { image = downsample(source, maximum: 1600) }
            }
            text = files.map(\.lastPathComponent).joined(separator: "\n") + (text.isEmpty ? "" : "\n\(text)")
        } else {
            for item in snapshot.items {
                for rep in item.representations where UTType(rep.type)?.conforms(to: .image) == true {
                    if let source = CGImageSourceCreateWithData(rep.data as CFData, nil), let decoded = downsample(source, maximum: 1600) {
                        image = decoded; kind = .image; break
                    }
                }
                if image != nil { break }
            }
            if image == nil && snapshot.items.contains(where: { $0.representations.contains { UTType($0.type)?.conforms(to: .audio) == true } }) { kind = .audio }
        }
        text = String(text.prefix(32_000)).replacingOccurrences(of: "\0", with: "")
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let fallback: String
        switch kind {
        case .image: fallback = "Image"
        case .audio: fallback = "Audio"
        case .file: fallback = "Files"
        case .text: fallback = "Text"
        case .other: fallback = snapshot.items.first?.representations.first?.type ?? "Clipboard item"
        }
        let title = firstLine.isEmpty ? fallback : String(firstLine.prefix(240))
        return ContentAnalysis(title: title, text: text, kind: kind, thumbnail: image.flatMap(thumbnail), imageForOCR: image)
    }

    static func downsample(_ source: CGImageSource, maximum: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
    static func thumbnail(_ image: CGImage) -> Data? {
        let scale = min(1, 320 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, small, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            return String((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(32_000))
        } catch { return "" }
    }
}
