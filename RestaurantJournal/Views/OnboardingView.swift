import SwiftUI

/// First-run introduction: brand, value, and photo-permission priming — ending in a single
/// "Get Started" that hands off to the (user-initiated) first scan. No sign-in here by design;
/// the account/card ask comes later, after the user has seen the magic.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0
    private let lastPage = 2

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if page < lastPage {
                    Button("Skip") { onFinish() }
                        .padding()
                }
            }
            .frame(height: 44)

            TabView(selection: $page) {
                brandPage.tag(0)
                featuresPage.tag(1)
                privacyPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))

            Button {
                if page < lastPage {
                    withAnimation { page += 1 }
                } else {
                    Analytics.log("onboarding_completed")
                    onFinish()
                }
            } label: {
                Text(page < lastPage ? "Next" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Pages

    private var brandPage: some View {
        VStack(spacing: 20) {
            Spacer()
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
            VStack(spacing: 8) {
                Text("Restaurant Journal")
                    .font(.largeTitle.weight(.bold))
                Text("Your dining life, remembered.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Spacer()
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer()
            Text("How it works")
                .font(.title.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .center)
            feature(
                icon: "photo.on.rectangle.angled",
                title: "Finds your visits",
                subtitle: "Automatically detects the places you've eaten from photos you already have."
            )
            feature(
                icon: "mic.fill",
                title: "Capture the memory",
                subtitle: "Add notes and voice memos to any visit, in your own words."
            )
            feature(
                icon: "map.fill",
                title: "See it all",
                subtitle: "Explore your dining map and ask questions about where you've been."
            )
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var privacyPage: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            VStack(spacing: 12) {
                Text("Private by design")
                    .font(.title.weight(.bold))
                Text("Restaurant Journal analyzes your photos right on your device to find where you've dined — your photos never leave your phone.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("Next, iOS will ask for photo access. Full access finds every visit automatically. Limited access works too — you pick which photos to include, and can add more anytime.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Spacer()
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }

    private func feature(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
