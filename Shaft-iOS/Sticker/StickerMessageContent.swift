import SwiftUI

/// Android's 64dp, bubble-free image and adjacent time chip; 128px local source.
struct StickerMessageContent: View {
    let id: String
    let time: String
    var failed = false
    var repository: StickerRepository = .shared
    @Environment(OnboardingStore.self) private var language
    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            StickerImage(id: id, resourceSize: 128, repository: repository).frame(width: 64, height: 64)
            HStack(spacing: 3) {
                if failed { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.v3Danger) }
                Text(time).font(.custom("Montserrat-Regular", size: 11))
            }
            .foregroundStyle(Theme.v3Text2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.v3Surface2, in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(StickerCopy(tag: language.activeTag).text("title")), \(time)")
    }
}
