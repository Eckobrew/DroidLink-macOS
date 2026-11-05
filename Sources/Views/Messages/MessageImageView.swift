import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct MessageImageView: View {
    let attachment: MessageAttachment
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let data = appState.imagePreviews[attachment.url], let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 300, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contextMenu {
                        Button("Save Image…") {
                            let panel = NSSavePanel()
                            panel.allowedContentTypes = [.jpeg]
                            panel.nameFieldStringValue = "Message.jpg"
                            if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url, options: .atomic) }
                        }
                    }
            } else if let error = appState.imageErrors[attachment.url] {
                VStack { Text(error).font(.caption); Button("Retry") { appState.retryImage(attachment.url) } }
                    .frame(width: 220, height: 90)
            } else {
                ProgressView("Loading image…").frame(width: 220, height: 90)
            }
        }
        .task(id: attachment.url) { appState.requestImage(attachment.url) }
    }
}

enum MessageImageEncoder {
    static func jpeg(from url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 3_000_000 else { throw CocoaError(.fileReadTooLarge) }
        return data as Data
    }
}
