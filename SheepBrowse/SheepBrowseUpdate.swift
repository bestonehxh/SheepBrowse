import AppKit

// SheepBrowse's half of the in-app updater — the only file tying the generic updater in Update/ (copied
// unchanged from SheepTerm) to this app. The updater checks the public repository's latest GitHub
// Release, verifies the zip's Ed25519 signature, and installs it.

extension UpdateConfig {
    /// The private half of this key is in the release Mac's login Keychain (service below, account
    /// `ed25519`, made once by SheepTerm's Tools/update-keygen.sh). `.ship.conf` carries the same value as
    /// UPDATE_SIGN_PUBLIC_KEY; signing refuses a key that differs.
    static let sheepBrowse = UpdateConfig(
        appName: "SheepBrowse",
        repository: "bestonehxh/SheepBrowse",
        tagScheme: .build,
        publicKeyBase64: "KrdtwDJZAj0BeTcIufoeWf1kMI63xSBUWa1drCY6DdA=",
        signingKeychainService: "Bestchaan.SheepBrowse.update-signing"
    )
}

@MainActor
enum AppUpdater {
    /// A browser has nothing to lose on quit: the session (tabs) is saved by the normal quit path.
    /// The family's centred alert (NSAlert left-aligns long text on macOS 26).
    static let shared = Updater(config: .sheepBrowse, hooks: UpdateHooks(presenter: CenteredUpdatePresenter()))

    /// Checks are always automatic in the Sheep family (no switch): clear any stored choice, then start.
    static func start() {
        UserDefaults.standard.removeObject(forKey: UpdateCore.autoCheckKey)
        shared.start()
    }
}
