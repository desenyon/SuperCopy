import Foundation
import Testing
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import SuperCopyCore

@Suite("Image capture")
struct ImageTests {
    @Test func fullImageIsPreservedWhilePreviewAndOCRStayBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SuperCopyImageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try #require(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        context.textPosition = CGPoint(x: 80, y: 400)
        let text = NSAttributedString(string: "SUPERCOPY 4291", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 80, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let store = try HistoryStore(root: root, embeddings: nil)
        let original = ClipboardSnapshot(items: [.init([.init(type: UTType.png.identifier, data: data as Data)])])
        let id = try #require(try await store.insert(original))
        #expect(try await store.enrichNextImage())
        #expect(try await store.restore(id: id) == original.items)
        let entry = try #require(try await store.entry(id: id))
        #expect(entry.kind == .image)
        #expect(entry.text.contains("4291"))
        #expect(try await store.search("4291").first?.id == id)
        let thumbnail = try #require(entry.thumbnailPath)
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: thumbnail) as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(decoded.width, decoded.height) <= 320)
    }
}
