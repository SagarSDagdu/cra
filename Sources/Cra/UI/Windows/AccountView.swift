import SwiftUI

/// Sign in / create account / Google, and the signed-in card with backups.
struct AccountView: View {
    @Environment(AccountStore.self) private var account
    @Environment(SidebarStore.self) private var store
    let onGoogle: () -> Void
    let onRestore: (SidebarDocument) -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var creating = false
    @State private var restoreCandidate: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let user = account.user {
                HStack(spacing: 12) {
                    avatar(user)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name ?? user.email).font(.system(size: 15, weight: .semibold))
                        Text(user.email).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(user.authProvider == "google" ? "Google account" : "Email account").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Sign Out") { Task { await account.signOut() } }
                }
                Divider()
                HStack {
                    Text("Sidebar backups").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Back Up Now") {
                        Task { await account.backupSidebar(store.document, tabCount: store.allTabs().count) }
                    }
                }
                if account.backups.isEmpty {
                    Text("No backups yet. Settings sync automatically; the sidebar is backed up every 10 minutes while signed in.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(account.backups, id: \.device) { b in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(b.device + (b.device == AccountStore.deviceID ? " (this Mac)" : "")).font(.system(size: 13))
                                Text("\(b.tabCount) tabs · \(b.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore…") { restoreCandidate = b.device }
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    BrandMark(size: 32)
                    Text(creating ? "Create your Cra account" : "Sign in to Cra").font(.system(size: 15, weight: .semibold))
                }
                Text("Syncs your settings and keeps a backup of your sidebar.").font(.system(size: 12)).foregroundStyle(.secondary)
                if creating {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                }
                TextField("Email", text: $email).textFieldStyle(.roundedBorder).textContentType(.username)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).textContentType(.password)
                    .onSubmit { submit() }
                if let err = account.lastError { Text(err).font(.system(size: 12)).foregroundStyle(.red) }
                HStack {
                    Button(creating ? "Already have an account" : "Create an account") { creating.toggle(); account.lastError = nil }
                        .buttonStyle(.link).font(.system(size: 12))
                    Spacer()
                    if account.isBusy { ProgressView().controlSize(.small) }
                    Button(creating ? "Create Account" : "Sign In") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(email.isEmpty || password.isEmpty || account.isBusy)
                }
                if account.googleConfigured {
                    Divider()
                    Button { onGoogle() } label: {
                        HStack { Image(systemName: "g.circle.fill"); Text("Continue with Google") }.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await account.refreshBackups(); await account.refreshGoogleConfig() }
        .alert("Replace your sidebar?", isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } })) {
            Button("Restore", role: .destructive) {
                guard let device = restoreCandidate else { return }
                Task {
                    if let doc = await account.fetchBackup(device: device) { onRestore(doc) }
                    restoreCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) { restoreCandidate = nil }
        } message: {
            Text("Spaces, pinned tabs and folders on this Mac will be replaced by the backup. The archive is kept.")
        }
    }

    private func submit() {
        Task {
            if creating { await account.signUp(email: email, password: password, name: name) }
            else { await account.signIn(email: email, password: password) }
        }
    }

    @ViewBuilder private func avatar(_ user: AccountUser) -> some View {
        if let s = user.profileImageUrl, let url = URL(string: s) {
            AsyncImage(url: url) { img in img.resizable() } placeholder: { Color.secondary.opacity(0.2) }
                .frame(width: 40, height: 40).clipShape(Circle())
        } else {
            Text(String((user.name ?? user.email).prefix(1)).uppercased())
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color(hex: "#6944AE")))
                .foregroundStyle(.white)
        }
    }
}
