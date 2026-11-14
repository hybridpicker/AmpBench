import AmpText
import SoundStore
import SparkDesign
import SwiftUI
import UniformTypeIdentifiers

/// The sound store's lamp and state at the foot of the sidebar, below the connection. A click opens its sheet.
struct StoreStatus: View {
    @EnvironmentObject private var model: PresetsModel

    private var store: StoreModel { model.store }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.showsStore = true
            } label: {
                HStack(spacing: 8) {
                    LampDot(tone: tone, isOn: isLit)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(tr("Sound store")).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if store.state == .syncing { ProgressView().controlSize(.mini) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hint)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tr("Sound store") + ", " + detail)
            .accessibilityHint(tr("Opens the sound store’s settings."))
            Spacer(minLength: 4)
            if store.isReady {
                Button(tr("Sync")) { store.sync() }
                    .buttonStyle(.hardwareKey(size: .small))
                    .fixedSize()
                    .disabled(store.state == .syncing)
                    .help(tr("Stores this device’s sounds encrypted and fetches the sounds of your other devices."))
            } else {
                Button(tr("Set up")) { model.showsStore = true }
                    .buttonStyle(.hardwareKey(size: .small))
                    .fixedSize()
                    .help(tr("Keeps your sounds encrypted in a place you choose: a folder, your own server or a cloud drive."))
            }
        }
    }

    private var tone: Lamp.Tone {
        if case .failed = store.state { return .hot }
        return .on
    }

    private var isLit: Bool {
        switch store.state {
        case .notSetUp: false
        case .idle: store.lastSync != nil
        case .syncing, .failed: true
        }
    }

    private var detail: String {
        switch store.state {
        case .notSetUp: return tr("not set up")
        case .syncing: return tr("syncing …")
        case .failed: return tr("last sync failed")
        case .idle:
            guard let date = store.lastSync else { return tr("not synced yet") }
            return tr("in step · %@", StoreText.time(date))
        }
    }

    private var hint: String {
        if case .failed(let text) = store.state { return text }
        return store.settings?.summary ?? ""
    }
}

enum StoreText {
    /// "14:05" today, "Nov 13, 14:05" before.
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Texts.locale
        if Calendar.current.isDateInToday(date) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }
}

/// Sets the sound store up and shows what it does: where the encrypted sounds are kept, and the key that opens them.
struct StoreSheet: View {
    @EnvironmentObject private var model: PresetsModel
    @State private var kind = StoreSettings.Kind.folder
    @State private var folderPath = ""
    @State private var folderBookmark: Data?
    @State private var host = ""
    @State private var path = "ampbench-store"
    @State private var url = ""
    @State private var user = ""
    @State private var password = ""
    @State private var keyText = ""
    @State private var shownKey: String?
    @State private var problem: String?
    @State private var choosesFolder = false
    @State private var asksToDisconnect = false

    private var store: StoreModel { model.store }

    /// SSH needs the Mac's `ssh`; the iPad has none.
    private var kinds: [StoreSettings.Kind] {
        #if os(macOS)
        [.folder, .ssh, .http]
        #else
        [.folder, .http]
        #endif
    }

    var body: some View {
        SheetPanel(tr("Sound store")) {
            Text(tr("Your sounds are encrypted on this device and kept in a place you choose. Whoever runs that place sees only unreadable files. Other devices with the same key get the same sounds."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            place
            Divider()
            key
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .failed(let text) = store.state {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let summary = store.lastSummary {
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if store.settings != nil {
                    Button(tr("Disconnect this device …"), role: .destructive) { asksToDisconnect = true }
                }
                Spacer()
                if store.state == .syncing { ProgressView().controlSize(.small) }
                Button(tr("Close"), role: .cancel) { model.showsStore = false }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Save and sync")) { saveAndSync() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.hasKey || store.state == .syncing)
            }
        }
        .frame(minWidth: 460, idealWidth: 540, maxWidth: 620)
        .onAppear(perform: load)
        .fileImporter(isPresented: $choosesFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            folderPath = folder.path
            folderBookmark = StoreProfile.bookmark(for: folder)
        }
        .confirmationDialog(tr("Disconnect this device from the sound store?"), isPresented: $asksToDisconnect) {
            Button(tr("Disconnect"), role: .destructive) {
                store.disconnect()
                load()
            }
            Button(tr("Cancel"), role: .cancel) {}
        } message: {
            Text(tr("The sounds on this device and in the store stay as they are, and the key stays in the keychain. This device just no longer syncs."))
        }
    }

    // MARK: Place

    @ViewBuilder
    private var place: some View {
        Text(tr("Place")).font(.headline)
        Picker(tr("Place"), selection: $kind) {
            ForEach(kinds, id: \.self) { Text(title($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        switch kind {
        case .folder:
            HStack {
                Text(folderPath.isEmpty ? tr("No folder chosen") : folderPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(folderPath.isEmpty ? .secondary : .primary)
                Spacer()
                Button(tr("Choose folder …")) { choosesFolder = true }
            }
            note(tr("Any folder works, also one that a cloud drive keeps in step: iCloud Drive, Google Drive, Dropbox or a network share."))
        case .ssh:
            field(tr("Server, as ssh knows it"), text: $host, prompt: "myserver")
            field(tr("Folder on the server"), text: $path, prompt: "ampbench-store")
            note(tr("Uses this Mac’s ssh with your own keys and ~/.ssh/config. AmpBench stores no login."))
        case .http:
            field(tr("Address"), text: $url, prompt: "https://example.org/ampbench-store/")
            field(tr("User name"), text: $user, prompt: "")
            HStack {
                Text(tr("Password")).frame(width: 150, alignment: .leading)
                SecureField("", text: $password).textFieldStyle(.roundedBorder)
            }
            note(tr("A WebDAV folder or any HTTPS address that takes GET and PUT, such as Nextcloud or your own server. The password is kept in the keychain."))
        }
    }

    private func title(_ kind: StoreSettings.Kind) -> String {
        switch kind {
        case .folder: tr("Folder")
        case .ssh: tr("Server (SSH)")
        case .http: tr("Server (HTTPS)")
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading)
            TextField("", text: text, prompt: Text(verbatim: prompt))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .plainTextInput()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Key

    @ViewBuilder
    private var key: some View {
        Text(tr("Store key")).font(.headline)
        if store.hasKey {
            if let shownKey {
                Text(verbatim: shownKey)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                HStack {
                    Button(tr("Copy")) { Clipboard.copySecret(shownKey) }
                    Button(tr("Hide")) { self.shownKey = nil }
                    Spacer()
                }
                note(tr("Whoever has this key can read your sounds, and without it nobody can, not even you. Keep a copy in your password manager, and enter it on your other devices. Never put it into a file that is shared or published."))
            } else {
                HStack {
                    Label(tr("This device has its key, in the keychain."), systemImage: "key.fill")
                    Spacer()
                    Button(tr("Show key …")) { shownKey = store.revealKey() }
                }
                note(tr("Your other devices need the same key. Show it here and enter it there."))
            }
        } else {
            HStack {
                Button(tr("Create a new key")) { run { try store.createKey() } }
                Text(tr("for a new store")).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                SecureField("", text: $keyText, prompt: Text(verbatim: "AGE-SECRET-KEY-1…"))
                    .textFieldStyle(.roundedBorder)
                Button(tr("Use this key")) {
                    run {
                        try store.useKey(keyText)
                        keyText = ""
                    }
                }
                .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            note(tr("Enter the key of a store you already have, as shown on the device that made it."))
        }
    }

    // MARK: Actions

    private func load() {
        problem = nil
        shownKey = nil
        guard let settings = store.settings else {
            kind = kinds[0]
            return
        }
        kind = kinds.contains(settings.kind) ? settings.kind : kinds[0]
        folderPath = settings.folderPath ?? ""
        folderBookmark = settings.folderBookmark
        host = settings.host ?? ""
        path = settings.path ?? "ampbench-store"
        url = settings.url ?? ""
        user = settings.user ?? ""
        password = store.profile.password ?? ""
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func saveAndSync() {
        let trimmed: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let settings: StoreSettings = switch kind {
        case .folder: StoreSettings(kind: .folder, folderPath: folderPath, folderBookmark: folderBookmark)
        case .ssh: StoreSettings(kind: .ssh, host: trimmed(host), path: trimmed(path))
        case .http: StoreSettings(kind: .http, url: trimmed(url), user: trimmed(user).isEmpty ? nil : trimmed(user))
        }
        run {
            try store.save(settings, password: kind == .http ? password : nil)
            store.sync()
        }
    }
}

private extension View {
    /// Server names and addresses are typed as they are: no capital first letter on the iPad's keyboard.
    @ViewBuilder
    func plainTextInput() -> some View {
        #if os(macOS)
        self
        #else
        textInputAutocapitalization(.never).keyboardType(.URL)
        #endif
    }
}
