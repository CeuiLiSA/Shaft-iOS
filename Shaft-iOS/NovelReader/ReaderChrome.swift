import SwiftUI

// Reader chrome — 1:1 port of layout_reader_top_bar / layout_reader_bottom_bar
// / layout_reader_search_overlay: dark scrim bars with white icons, top bar
// 56pt (back / title / annotations / bookmark / more), bottom bar = 48pt
// progress row + 56pt button row (series·chapters·settings·day-night·search·
// more), search overlay with regex toggle and hit counter. The host animates
// show/hide at 220 ms (upstream ReaderChrome).

private let barScrim = Color.black.opacity(0.62)

struct ReaderTopBar: View {
    let title: String
    let isBookmarked: Bool
    let bookmarkBusy: Bool
    var onBack: () -> Void
    var onAnnotations: () -> Void
    var onBookmark: () -> Void
    var onMore: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            barButton("chevron.left", action: onBack)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
            barButton("highlighter", action: onAnnotations)
            barButton(isBookmarked ? "heart.fill" : "heart",
                      tint: isBookmarked ? Color(hex: 0xFA3A3A) : .white,
                      action: onBookmark)
                .disabled(bookmarkBusy)
            barButton("ellipsis", action: onMore)
        }
        .padding(.horizontal, 4)
        .frame(height: 56)
        .background(barScrim)
    }

    private func barButton(_ symbol: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .contentShape(.rect)
        }
    }
}

struct ReaderBottomBar: View {
    @Environment(OnboardingStore.self) private var l10n

    /// Paged mode: 0-based current page + total; scroll mode: fraction 0…1.
    let isVertical: Bool
    let currentPage: Int
    let totalPages: Int
    let scrollFraction: Double
    let isDarkTheme: Bool
    let hasSeries: Bool

    var onPrevChapter: () -> Void
    var onNextChapter: () -> Void
    var onSeekCommit: (Int) -> Void
    var onScrollSeekCommit: (Double) -> Void
    var onChapters: () -> Void
    var onSeries: () -> Void
    var onSettings: () -> Void
    var onThemeToggle: () -> Void
    var onSearch: () -> Void
    var onMore: () -> Void

    @State private var dragValue: Double?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                rowButton("backward.end", size: 40, action: onPrevChapter)
                slider
                Text(progressLabel)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(minWidth: 72)
                rowButton("forward.end", size: 40, action: onNextChapter)
            }
            .padding(.horizontal, 8)
            .frame(height: 48)

            HStack(spacing: 0) {
                if hasSeries {
                    menuButton("books.vertical", l10n.t(.nrBtnSeries), action: onSeries)
                }
                menuButton("list.bullet", l10n.t(.nrBtnChapters), action: onChapters)
                menuButton("textformat.size", l10n.t(.nrBtnSettings), action: onSettings)
                menuButton(isDarkTheme ? "sun.max" : "moon",
                           l10n.t(isDarkTheme ? .nrBtnThemeDay : .nrBtnThemeNight),
                           action: onThemeToggle)
                menuButton("magnifyingglass", l10n.t(.nrBtnSearch), action: onSearch)
                menuButton("ellipsis.circle", l10n.t(.nrBtnMore), action: onMore)
            }
            .frame(height: 56)
        }
        .background(barScrim)
    }

    private var progressLabel: String {
        if isVertical {
            let f = dragValue ?? scrollFraction
            return "\(Int((f * 100).rounded()))%"
        }
        guard totalPages > 0 else { return l10n.t(.nrProgressEmpty) }
        let page = dragValue.map { Int($0.rounded()) } ?? currentPage
        return "\(page + 1) / \(totalPages)"
    }

    private var slider: some View {
        let range: ClosedRange<Double> = isVertical ? 0...1 : 0...Double(max(totalPages - 1, 1))
        let bound = Binding<Double>(
            get: { dragValue ?? (isVertical ? scrollFraction : Double(currentPage)) },
            set: { dragValue = $0 }
        )
        return Slider(value: bound, in: range) { editing in
            if !editing, let v = dragValue {
                if isVertical {
                    onScrollSeekCommit(v)
                } else {
                    onSeekCommit(Int(v.rounded()))
                }
                dragValue = nil
            }
        }
        .tint(.white)
        .disabled(!isVertical && totalPages <= 1)
    }

    private func rowButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(.rect)
        }
    }

    private func menuButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                Text(label)
                    .font(.system(size: 10))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
    }
}

struct ReaderSearchOverlayBar: View {
    @Environment(OnboardingStore.self) private var l10n

    @Binding var query: String
    let currentIndex: Int
    let total: Int
    @Binding var regexEnabled: Bool
    var onSubmit: () -> Void
    var onPrev: () -> Void
    var onNext: () -> Void
    var onList: () -> Void
    var onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            TextField("", text: $query, prompt: Text(l10n.t(.nrSearchHint)).foregroundStyle(.white.opacity(0.53)))
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(.white)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .onSubmit(onSubmit)
                .frame(maxWidth: .infinity)
            Text(countLabel)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .frame(minWidth: 56)
            if total > 0 {
                Button(action: onList) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 44)
                }
            }
            Button(action: onPrev) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 44)
            }
            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 44)
            }
            Button {
                regexEnabled.toggle()
            } label: {
                Text(l10n.t(.nrSearchRegex))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        regexEnabled ? Color(hex: 0x5B6EFF) : Color.white.opacity(0.2),
                        in: .rect(cornerRadius: 4)
                    )
            }
            .padding(.trailing, 8)
        }
        .frame(minHeight: 56)
        .background(barScrim)
        .onAppear { focused = true }
    }

    private var countLabel: String {
        if query.isEmpty { return "" }
        if total == 0 { return l10n.t(.nrSearchNoResult) }
        return "\(currentIndex + 1) / \(total)"
    }
}
