import AppKit
import Foundation

public struct PasteboardClipboardImageSource: ClipboardImageSource {
    public init() {}

    @MainActor
    public func readImage() throws -> EncodedImage {
        let pasteboard = NSPasteboard.general
        if let png = pasteboard.data(forType: .png) {
            return EncodedImage(data: png, contentType: "image/png", fileExtension: "png")
        }
        if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
            return EncodedImage(data: jpeg, contentType: "image/jpeg", fileExtension: "jpg")
        }
        if let tiff = pasteboard.data(forType: .tiff), let image = NSImage(data: tiff) {
            return try Self.encodePNG(image)
        }
        guard let image = NSImage(pasteboard: pasteboard) else { throw R2Error.clipboardEmpty }
        return try Self.encodePNG(image)
    }

    private static func encodePNG(_ image: NSImage) throws -> EncodedImage {
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw R2Error.unsupportedImage
        }
        return EncodedImage(data: png, contentType: "image/png", fileExtension: "png")
    }
}
