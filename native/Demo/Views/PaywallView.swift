import SwiftUI

/// The paywall (spec §2.9): the Pro hero, what's included, and the Yearly / Monthly trial on iPhone.
struct PaywallView: View {
    let why: String
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var store = Store.shared
    @State private var year = true
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 0) {
                    hero
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Pro.features) { f in
                            HStack(alignment: .top, spacing: 14) {
                                TileIcon(f.icon, f.color, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.title).font(.system(size: 17, weight: .semibold))
                                    Text(f.sub).font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 8)
                            .animation(.easeOut(duration: 0.35).delay(0.12 + Double(f.id) * 0.045), value: shown)
                        }
                    }
                    .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 24)
                }
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) { bar }

            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 36, height: 36).background(BarFill.color, in: Circle())
            }
            .buttonStyle(PressScale())
            .padding(.trailing, 18).padding(.top, 8)
            .accessibilityLabel("Close")
        }
        .background {
            LinearGradient(colors: [Color(hex: 0xB9A6FF).opacity(0.28), Color(uiColor: .systemBackground)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
                .ignoresSafeArea()
        }
        .onAppear { Haptics.tap(); shown = true; Task { await store.start(session: session) } }
        // becoming Pro closes it
        .onChange(of: session.plan.isPro) { _, pro in if pro { dismiss() } }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(hex: 0xFFC2DA), Color(hex: 0xB9A6FF)], startPoint: .topLeading, endPoint: .bottomTrailing))
                ProMark(size: 34)
            }
            .frame(width: 84, height: 84)
            .shadow(color: Color(hex: 0x9678DC).opacity(0.3), radius: 16, y: 8)
            .padding(.bottom, 6)
            Text("*[demo] Pro").font(.system(size: 32, weight: .bold)).tracking(-0.5)
            Text("Everything you need to take a song from the first line to the finished demo.")
                .font(.system(size: 17)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !why.isEmpty {
                Text(Pro.message(why)).font(.system(size: 15, weight: .medium)).multilineTextAlignment(.center).padding(.top, 4)
            }
        }
        .padding(.horizontal, 32).padding(.top, 56)
    }

    @ViewBuilder private var bar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                planCard(true, "Yearly", store.price(year: true) + " a year", badge: "Save 35%")
                planCard(false, "Monthly", store.price(year: false) + " a month", badge: nil)
            }
            .accessibilityElement(children: .contain)
            Button { Task { await store.buy(year: year, session: session) } } label: {
                Text(store.busy == "buy" ? "One moment…" : "Start \(Pro.trialDays)-Day Free Trial")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.onTint)
                    .frame(maxWidth: .infinity, minHeight: 52).background(Theme.tint, in: Capsule())
            }
            .buttonStyle(PressScale())
            .disabled(store.busy != nil)
            Text("\(Pro.trialDays) days free for new subscribers, then \(store.price(year: year))\(year ? " a year" : " a month"), charged to your Apple ID. Renews automatically unless you cancel at least 24 hours before the period ends, in Settings › Apple ID › Subscriptions.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Button(store.busy == "restore" ? "Restoring…" : "Restore Purchases") { Task { await store.restore(session: session) } }
                    .disabled(store.busy != nil)
                Button("Terms of Use") { openURL(URL(string: "https://hellodemo.app/terms.html")!) }
                Button("Privacy Policy") { openURL(URL(string: "https://hellodemo.app/privacy.html")!) }
            }
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary).tint(Color.secondary)
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
        .background(.bar)
    }

    private func planCard(_ isYear: Bool, _ title: String, _ price: String, badge: String?) -> some View {
        let on = year == isYear
        return Button {
            guard !on else { return }
            Haptics.tap(); withAnimation(.snappy) { year = isYear }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(on ? Theme.tint : Color.secondary.opacity(0.4), lineWidth: 1.5)
                    if on { Circle().fill(Theme.tint); Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.onTint) }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 16, weight: .semibold))
                        if let badge {
                            Text(badge).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.proGreen, in: Capsule())
                        }
                    }
                    Text(price).font(.system(size: 13.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(BarFill.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? Theme.tint : .clear, lineWidth: 2))
        }
        .buttonStyle(PressScale())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
