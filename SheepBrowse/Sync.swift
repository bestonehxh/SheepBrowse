import AppKit
import SheepSync
import SwiftUI

/// SheepBrowse's side of SheepSync (Settings → Sync): favorites, saved passwords and settings follow the
/// user to every Mac, end-to-end encrypted, stored in the user's own Google Drive (`appDataFolder`).
/// The vault key file is the Sheep family's shared one, so the passphrase is the same as SheepTerm's.
///
/// Records (ids are part of the vault format — never rename one):
/// - `favorites` — the whole favorites tree (folders make per-item records awkward; last writer wins).
/// - `password:<uuid>` — one saved login.
/// - `setting:<key>` — the preferences in `syncedSettings`.
///
/// Not synced, on purpose: history and open tabs (this Mac's), cookies (sign in on each Mac), downloads.
/// Off until the user signs in: the engine makes no network call before that.
@MainActor
final class SyncController: SyncDataSource {
    static let shared = SyncController()

    let engine: SyncEngine
    static let syncedSettings = [
        "blockAds", "adBlockAllowedSites", "sleepAfterMinutes", "searchSuggestions", "restoreSession",
        "trustedCertificates", "passwordNever", "zoomBySite", "showFavoritesBar",
    ]

    /// True while changes from the cloud are being written here, so the stores' own change
    /// notifications do not schedule a sync of them.
    private var applying = false
    private var lastSettings: [String: Data] = [:]
    private var lastActivationSync = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let secret = (info["SheepSyncGoogleClientSecret"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let id = info["SheepSyncGoogleClientID"] as? String ?? ""
        // A Desktop client cannot finish sign-in without its secret: a build without Secrets.xcconfig shows
        // "not available" instead of a Sign In button that fails half-way.
        let usable = !secret.isEmpty && !secret.hasPrefix("$(") ? id : ""
        engine = SyncEngine(configuration: SyncConfiguration(
            appName: "SheepBrowse", google: GoogleClient(clientID: usable, clientSecret: secret),
            keychainService: "Bestchaan.SheepBrowse", stateDirectory: AppFiles.directory,
            deviceName: Host.current().localizedName ?? "Mac"))
        engine.openURL = { url in
            // Google's sign-in page for Sync opens here, in a tab (the loopback answer comes back to the engine).
            (BrowserWindowController.frontmost ?? BrowserWindowController.newWindow())?.open(url, typed: false, disposition: .newTab)
        }
        engine.dataSource = self
    }

    func start() {
        let changed: @MainActor () -> Void = { [weak self] in
            guard let self, !self.applying else { return }
            self.engine.noteLocalChange()
        }
        for name in [BookmarkStore.didChange, PasswordStore.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { changed() }
            })
        }
        lastSettings = Self.currentSettings()
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.applying else { return }
                let now = Self.currentSettings()
                guard now != self.lastSettings else { return }
                self.lastSettings = now
                self.engine.noteLocalChange()
            }
        })
        // Coming back to the app is when another Mac's edits are most likely waiting — at most once a minute.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastActivationSync) > 60 else { return }
                self.lastActivationSync = Date()
                Task { await self.engine.syncNow() }
            }
        })
        engine.start()
    }

    private static func currentSettings() -> [String: Data] {
        var out: [String: Data] = [:]
        for key in syncedSettings {
            guard let value = UserDefaults.standard.object(forKey: key),
                  let data = try? PropertyListSerialization.data(fromPropertyList: ["v": value], format: .binary, options: 0) else { continue }
            out[key] = data
        }
        return out
    }

    // MARK: Records out

    func syncSnapshot() -> SyncSnapshot {
        var records: [String: Data] = [:]
        if let data = try? JSONEncoder().encode(BookmarkStore.shared.bar) { records["favorites"] = data }
        let passwords = PasswordStore.shared.all
        let failed = PasswordStore.shared.loadFailed
        if !failed {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            for entry in passwords {
                if let data = try? encoder.encode(entry) { records["password:\(entry.id.uuidString)"] = data }
            }
        }
        for (key, data) in Self.currentSettings() { records["setting:\(key)"] = data }
        return SyncSnapshot(records: records, unavailablePrefixes: failed ? ["password:"] : [])
    }

    // MARK: Records in

    func syncApply(_ changes: [String: Data?], firstJoin: Bool) -> SyncApplyResult {
        applying = true
        defer {
            applying = false
            lastSettings = Self.currentSettings()
        }
        if firstJoin {
            // The cloud's copy is about to replace this Mac's favorites: keep them aside.
            try? FileManager.default.removeItem(at: AppFiles.url("bookmarks-before-sync.json"))
            try? FileManager.default.copyItem(at: AppFiles.url("bookmarks.json"), to: AppFiles.url("bookmarks-before-sync.json"))
        }
        var failed = Set<String>()
        var upserts: [SavedPassword] = []
        var deletes = Set<UUID>()
        var settingsChanged = false

        for (id, value) in changes {
            if id == "favorites" {
                guard let value else {
                    BookmarkStore.shared.replaceAll([])
                    continue
                }
                if let nodes = try? JSONDecoder().decode([Bookmark].self, from: value) {
                    BookmarkStore.shared.replaceAll(nodes)
                } else {
                    failed.insert(id)
                }
            } else if id.hasPrefix("password:") {
                guard let uuid = UUID(uuidString: String(id.dropFirst("password:".count))) else { continue }
                if let value {
                    if let entry = try? JSONDecoder().decode(SavedPassword.self, from: value) { upserts.append(entry) } else { failed.insert(id) }
                } else {
                    deletes.insert(uuid)
                }
            } else if id.hasPrefix("setting:") {
                let key = String(id.dropFirst("setting:".count))
                guard Self.syncedSettings.contains(key) else { continue }
                if let value {
                    guard let plist = try? PropertyListSerialization.propertyList(from: value, format: nil) as? [String: Any],
                          let setting = plist["v"] else {
                        failed.insert(id)
                        continue
                    }
                    UserDefaults.standard.set(setting, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                settingsChanged = true
            }
        }
        if !upserts.isEmpty || !deletes.isEmpty {
            _ = PasswordStore.shared.all
            if PasswordStore.shared.loadFailed {
                // Writing now would replace the unreadable vault with only these entries.
                failed.formUnion(upserts.map { "password:\($0.id.uuidString)" })
                failed.formUnion(deletes.map { "password:\($0.uuidString)" })
            } else {
                PasswordStore.shared.applySynced(upserts: upserts, deletes: deletes)
            }
        }
        if settingsChanged {
            WebEngine.shared.refreshBlockList()
            BrowserWindowController.all.forEach { $0.refreshChrome() }
        }
        return SyncApplyResult(failed: failed)
    }
}

// MARK: - Settings → Sync

struct SyncSettingsView: View {
    /// false inside the account card (it shows the account above).
    var showsHeader = true
    private var engine: SyncEngine { SyncController.shared.engine }
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Form {
            Section {
                switch engine.phase {
                case .notConfigured:
                    Label("Sync is not available in this build.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                case .signedOut:
                    Text("Sign in with Google to keep your favorites, saved passwords and settings the same on every Mac. They are encrypted on this Mac with your passphrase before they leave it, and stored in your own Google Drive.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Sign In with Google…") { Task { await engine.signIn() } }
                        .buttonStyle(.glassProminent)
                case .signingIn:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in the tab that opened…")
                        Spacer()
                        Button("Cancel") { engine.cancelSignIn() }
                    }
                case .checkingVault:
                    HStack { ProgressView().controlSize(.small); Text("Looking for your vault…") }
                case .needsNewPassphrase:
                    Text("Choose a passphrase. You will need it on every Mac (and in the other Sheep apps). It cannot be recovered.")
                        .font(.callout).foregroundStyle(.secondary)
                    SecureField("Passphrase", text: $passphrase)
                    SecureField("Confirm", text: $confirm)
                    Button("Create Vault") { create() }
                        .disabled(passphrase.count < 8 || passphrase != confirm || working)
                        .buttonStyle(.glassProminent)
                case .needsPassphrase:
                    Text("Enter the passphrase you chose for Sync (the same one as in SheepTerm).")
                        .font(.callout).foregroundStyle(.secondary)
                    SecureField("Passphrase", text: $passphrase)
                    Button("Unlock") { unlock() }
                        .disabled(passphrase.isEmpty || working)
                        .buttonStyle(.glassProminent)
                case .ready:
                    if showsHeader { LabeledContent("Account", value: engine.account ?? "—") }
                    LabeledContent("Last synced") {
                        if engine.isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(engine.lastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                        }
                    }
                    if !engine.isOnline {
                        Label("Offline — changes will sync when you are back online.", systemImage: "wifi.slash")
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Sync Now") { Task { await engine.syncNow() } }
                        Spacer()
                        Button("Sign Out", role: .destructive) { Task { await engine.signOut() } }
                    }
                }
                if let message = error ?? engine.lastError {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            } header: { if showsHeader { Text("Sync") } } footer: {
                Text("Synced: favorites, passwords, ad-blocker and site settings, trusted certificates. Not synced: history, open tabs, cookies.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private func create() {
        working = true
        Task {
            do {
                try await engine.createVault(passphrase: passphrase)
                passphrase = ""; confirm = ""; error = nil
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func unlock() {
        working = true
        Task {
            do {
                try await engine.unlock(passphrase: passphrase)
                passphrase = ""; error = nil
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
