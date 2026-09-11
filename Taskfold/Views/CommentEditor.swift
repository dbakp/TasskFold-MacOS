import SwiftUI
import AppKit

/// A native plain-text editor that accepts images specifically when Paste is invoked.
/// Ordinary text editing, selection, and clipboard behavior stay with NSTextView.
struct CommentEditor: NSViewRepresentable {
    @Binding var text: String
    let pasteImage: (Data) -> Void
    let pasteError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = ImagePasteTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 3, height: 5)
        editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier("commentEditor")
        editor.setAccessibilityLabel("Write a comment")
        editor.onImage = pasteImage
        editor.onError = pasteError
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ImagePasteTextView else { return }
        editor.onImage = pasteImage
        editor.onError = pasteError
        if editor.string != text { editor.string = text }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommentEditor
        init(_ parent: CommentEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
    final class ImagePasteTextView: NSTextView {
        var onImage: ((Data) -> Void)?
        var onError: ((String) -> Void)?
        override func paste(_ sender: Any?) {
            let board = NSPasteboard.general
            if let data = board.data(forType: .png) {
                onImage?(data)
            } else if let image = NSImage(pasteboard: board) {
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    onError?("This clipboard image could not be read."); return
                }
                onImage?(png)
            } else { super.paste(sender) }
        }
        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(paste(_:)), NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
            return super.validateUserInterfaceItem(item)
        }
    }
}
