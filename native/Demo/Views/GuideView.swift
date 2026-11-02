import SwiftUI

/// The "How *[demo] works" song, read with its pictures (the web's guideView). Shown in place of the lyrics
/// while the guide's words are untouched. The pictures only live here: they aren't part of the song's text,
/// so Copy Lyrics, exports and Perform never see them.
struct GuideView: View {
    let header: AnyView
    var topInset: CGFloat = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, -20).padding(.bottom, 4)
                ForEach(Array(GuideContent.blocks.enumerated()), id: \.offset) { i, b in
                    block(b, first: i == 0)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, topInset)
            .padding(.bottom, 120)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private func block(_ b: GuideContent.Block, first: Bool) -> some View {
        switch b {
        case .heading(let t):
            Text("[\(t)]")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Color(hex: 0x8E8E96))
                .padding(.top, first ? 0 : 20)
                .padding(.bottom, 2)
        case .text(let t):
            Text(t)
                .font(.system(size: 19))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 7)
        case .picture(let name, let caption):
            VStack(alignment: .leading, spacing: 6) {
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 11, trailing: 14))
            .background(panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        case .question(let q, let a):
            VStack(alignment: .leading, spacing: 2) {
                Text(q).font(.system(size: 19, weight: .semibold))
                Text(a).font(.system(size: 19)).foregroundStyle(.secondary).lineSpacing(5)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        }
    }

    /// The share page's soft pastel, dimmed in dark mode so the pictures sit on it like on paper.
    private var panel: LinearGradient {
        let dark = scheme == .dark
        let c: [Color] = dark
            ? [Color(red: 150/255, green: 120/255, blue: 1).opacity(0.2), Color(red: 1, green: 120/255, blue: 160/255).opacity(0.14), Color(red: 1, green: 190/255, blue: 120/255).opacity(0.12)]
            : [Color(hex: 0xF4EEFF), Color(hex: 0xFFEFF4), Color(hex: 0xFFF6E8)]
        return LinearGradient(colors: c, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
