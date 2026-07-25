import SwiftUI

/// Wraps the app in a branded splash that fades away shortly after launch.
struct AppRootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var showSplash = true

    var body: some View {
        ZStack {
            RootView()
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            // Snappy fade-in, then a comfortable hold before dismissing.
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation(.easeInOut(duration: 0.55)) { showSplash = false }
        }
        .task {
            // Keep iCloud-restore resilient: re-link restored photos, capture cloud identifiers, and
            // backfill cover thumbnails. Bounded and self-quiescing, so it's cheap on later launches.
            await SyncMaintenance.run(context: modelContext)
        }
    }
}

/// Launch branding: cream backdrop, the logo mark, the "Restaurant Journal" wordmark, and the
/// "EAT. EXPERIENCE. REMEMBER." tagline — matched to the brand art.
struct SplashView: View {
    @State private var appear = false

    var body: some View {
        ZStack {
            Color("BrandCream").ignoresSafeArea()

            // The app-icon mark, rounded to the iOS "squircle" so it reads as the app icon rather
            // than a hard-edged square (matches the rounded treatment in onboarding/welcome).
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 31, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 5)

            // Only the wordmark + tagline animate in, below the (static) logo.
            VStack(spacing: 10) {
                (
                    Text("Restaurant").foregroundStyle(Color("BrandGreen"))
                    + Text(" Journal").foregroundStyle(Color("AccentColor"))
                )
                .font(.system(.largeTitle, design: .serif).weight(.semibold))

                Text("EAT. EXPERIENCE. REMEMBER.")
                    .font(.footnote.weight(.medium))
                    .tracking(2.5)
                    .foregroundStyle(Color("BrandGreen").opacity(0.65))
            }
            .multilineTextAlignment(.center)
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 132 : 140)
        }
        .task {
            withAnimation(.easeOut(duration: 0.5)) { appear = true }
        }
    }
}

#Preview {
    SplashView()
}
