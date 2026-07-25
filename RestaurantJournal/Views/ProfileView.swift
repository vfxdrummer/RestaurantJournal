import SwiftUI
import AuthenticationServices
import PhotosUI

/// Account/profile screen. Signed-out is a branded sign-in hero (optional phone/Apple/Google);
/// signed-in shows the account, avatar, and a sign-out. Avatar auto-fills from the provider photo
/// when available, else the user picks one.
struct ProfileView: View {
    @ObservedObject private var auth = SupabaseAuthService.shared
    @ObservedObject private var profile = ProfileStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var showingPhoneAuth = false
    @State private var appleNonce: String?
    @State private var authError: String?
    @State private var photoItem: PhotosPickerItem?
#if CARD_LINKING
    @State private var connectingCard = false
    @State private var cardResult: String?
    @AppStorage("hasConnectedCard") private var hasConnectedCard = false
#endif
    @State private var showDeleteConfirm = false
    @State private var deletingAccount = false
    @State private var accountError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let session = auth.session {
                    signedIn(session)
                } else {
                    signedOut
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPhoneAuth) {
                PhoneAuthView()
            }
        }
    }

    // MARK: - Signed out (branded hero)

    private var signedOut: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 32)

                Image("BrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 5)

                VStack(spacing: 8) {
                    Text("Restaurant Journal")
                        .font(.title.weight(.bold))
                    Text("Sign in to connect a card and import your dining charges.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("You can keep using the journal without an account.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    phoneButton
                    appleButton
                    googleButton
                    if let authError {
                        Text(authError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.top, 8)

                // Backup is a device/iCloud setting, not an account feature — reachable signed out.
                NavigationLink {
                    Form { CloudBackupSectionView() }
                        .navigationTitle("iCloud Backup")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "icloud")
                            .foregroundStyle(.secondary)
                        Text("iCloud Backup")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                }
                .padding(.top, 4)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var phoneButton: some View {
        Button {
            showingPhoneAuth = true
        } label: {
            Label("Continue with phone", systemImage: "phone.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.white)
        }
    }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            let nonce = AppleSignInSupport.randomNonce()
            appleNonce = nonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = AppleSignInSupport.sha256(nonce)
        } onCompletion: { result in
            handleApple(result)
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var googleButton: some View {
        Button {
            Task {
                authError = nil
                do {
                    try await auth.signInWithGoogle()
                } catch {
                    authError = error.localizedDescription
                }
            }
        } label: {
            Label("Continue with Google", systemImage: "globe")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.12))
                )
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Signed in

    @ViewBuilder private func signedIn(_ session: AuthSession) -> some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        ProfileAvatarView(size: 60)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.body)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                                    .background(Circle().fill(.background))
                            }
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayName).font(.headline)
                        Text("Account connected").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            CloudBackupSectionView()

            if profile.avatar == nil {
                Section {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Add a profile photo", systemImage: "photo.badge.plus")
                    }
                } footer: {
                    Text("We couldn't find a photo automatically — pick one from your library.")
                }
            }

#if CARD_LINKING
            Section {
                Button {
                    Task { await connectCard() }
                } label: {
                    if connectingCard {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Connecting…")
                        }
                    } else {
                        Label("Connect a card", systemImage: "creditcard")
                    }
                }
                .disabled(connectingCard)

                if hasConnectedCard {
                    Button(role: .destructive) {
                        Task { await disconnectCard() }
                    } label: {
                        Label("Disconnect card", systemImage: "minus.circle")
                    }
                    .disabled(connectingCard)
                }

                if let cardResult {
                    Text(cardResult).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Cards")
            } footer: {
                Text("Import your dining charges to capture meals you didn't photograph.")
            }
#endif

            Section {
                Button(role: .destructive) {
                    auth.signOut()
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    if deletingAccount {
                        HStack(spacing: 8) { ProgressView(); Text("Deleting…") }
                    } else {
                        Label("Delete Account", systemImage: "trash")
                    }
                }
                .disabled(deletingAccount)
                if let accountError {
                    Text(accountError).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Permanently deletes your account, disconnects any linked cards, and removes your financial data from our servers. Your on-device journal stays on this device.")
            }
        }
        .navigationTitle("Profile")
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    profile.setImage(data: data)
                }
            }
        }
    }

    // MARK: - Cards

#if CARD_LINKING
    private func connectCard() async {
        connectingCard = true
        cardResult = nil
        defer { connectingCard = false }
        do {
            let count = try await PlaidService.shared.connectCard()
            hasConnectedCard = true
            Analytics.log("card_connected")
            let transactions = try await PlaidService.shared.fetchDiningTransactions()
            let created = CardVisitIngestor.ingest(transactions, in: modelContext)
            if created > 0 {
                cardResult = "Added \(created) dining visit\(created == 1 ? "" : "s") from your card."
            } else if count > 0 {
                cardResult = "Charges matched to visits you already have."
            } else {
                cardResult = "Card connected — no dining charges found yet."
            }
        } catch {
            // A user cancelling the Plaid browser isn't an error worth showing.
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                cardResult = error.localizedDescription
            }
        }
    }

    private func disconnectCard() async {
        connectingCard = true
        cardResult = nil
        defer { connectingCard = false }
        do {
            try await PlaidService.shared.disconnectCard()
            CardVisitIngestor.removeCardData(in: modelContext)
            hasConnectedCard = false
            cardResult = "Card disconnected."
        } catch {
            cardResult = error.localizedDescription
        }
    }
#endif

    private func deleteAccount() async {
        deletingAccount = true
        accountError = nil
        defer { deletingAccount = false }
        do {
            try await auth.deleteAccount()
            CardVisitIngestor.removeCardData(in: modelContext)
#if CARD_LINKING
            hasConnectedCard = false
#endif
            // Session is now nil → the view flips back to the signed-out hero.
        } catch {
            accountError = error.localizedDescription
        }
    }

    // MARK: - Apple

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        authError = nil
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let nonce = appleNonce
            else {
                authError = "Couldn't read the Apple credential. Please try again."
                return
            }
            Task {
                do {
                    try await auth.signInWithApple(idToken: idToken, nonce: nonce)
                } catch {
                    authError = error.localizedDescription
                }
            }
        case .failure(let error):
            // Don't surface the user simply cancelling the sheet.
            if (error as? ASAuthorizationError)?.code != .canceled {
                authError = error.localizedDescription
            }
        }
    }
}
