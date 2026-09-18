import SwiftUI

// Compatibility for the existing Plaza call sites; both surfaces use the shared system.
typealias PlazaSticker = Sticker
typealias PlazaStickerImage = StickerImage

struct PlazaStickerPicker: View {
    var inline = false
    var position: StickerPickerPosition?
    var onPick: (Sticker) -> Void
    var body: some View {
        StickerPicker(inline: inline, primary: PlazaPalette.primary, position: position, onPick: onPick)
    }
}
