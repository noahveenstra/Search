import CryptoKit
import Foundation
import Security
import WebKit

// One person's browser, on every Mac signed into the same iCloud account.
//
// The GitHub repository is the app. This is the browsing: tabs, history,
// bookmarks, spaces, what is hidden, extensions, cookies, and passwords.
// Passwords are encrypted in this folder; the key lives in iCloud Keychain,
// not in the file. Nothing here is committed or released. A test run never
// reaches it.
//
// When the two Macs don't match, the rule is the same for all of it.
// Something only one Mac has is kept. The same thing changed on both keeps
// the later change, and a deletion wins only when it is later than that
// change. Open tabs are the exception: the Mac that last touched that
// space's tabs wins, because closing a tab is a choice. An identical row
// is left alone so two Macs don't hand the same tabs back and forth.

final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    @Published var detail = "Looking for iCloud Drive…"
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            Store.settings.set(enabled, forKey: Self.enabledKey)
            if enabled { Task { @MainActor in CloudSync.shared.schedule() } }
        }
    }

    private static let enabledKey = "sync"
    private weak var browser: Browser?
    private var wait: DispatchWorkItem?
    private var working = false
    private var again = false
    private var started = false

    private init() {
        enabled = Store.settings.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    @MainActor
    func start(browser: Browser) {
        guard !started else { return }
        started = true
        self.browser = browser
        guard !Store.testing else { return }
        Vault.shareAcrossDevices()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in CloudSync.shared.schedule() } }
        schedule()
    }

    /// A local file just changed. Coalesced: a minute of browsing syncs
    /// once, not once per page.
    nonisolated func notice() {
        Task { @MainActor in
            guard !Store.testing, self.enabled else { return }
            self.schedule()
        }
    }

    /// Quitting doesn't get the two-second wait. The session is already on
    /// disk; this only copies it up.
    @MainActor
    func pushSessionsNow() {
        guard !Store.testing, enabled, let cloud = Self.cloudRoot() else { return }
        var state = State.load(Store.folder)
        Self.pushSessions(local: Store.folder, cloud: cloud, device: Self.deviceID, state: &state)
        state.save(Store.folder)
    }

    @MainActor
    private func schedule(after seconds: Double = 2) {
        guard enabled, !Store.testing else { return }
        wait?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reconcile() }
        }
        wait = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// File copies used to run here, on the main thread. An iCloud file that
    /// is not on this Mac yet makes that copy sleep inside the kernel until
    /// the download finishes, and the window stops answering. The pass now
    /// runs off to the side. A folder that is still in iCloud is not copied;
    /// iCloud is asked to fetch it, and the pass tries again later.
    @MainActor
    private func reconcile() {
        guard enabled, !Store.testing else { return }
        guard !working else { again = true; return }
        guard let cloud = Self.cloudRoot() else {
            detail = "Turn on iCloud Drive and this Mac will keep the others up to date"
            return
        }
        working = true
        let local = Store.folder
        let device = Self.deviceID
        let jars = browser.map(Self.jarIDs) ?? []
        DispatchQueue.global(qos: .utility).async {
            var state = State.load(local)
            let changed = Self.exchange(local: local, cloud: cloud, device: device, state: &state, jars: jars)
            state.save(local)
            Task { @MainActor in
                CloudSync.shared.finish(changed, cloud: cloud)
            }
        }
    }

    @MainActor
    private func finish(_ changed: Changed, cloud: URL) {
        if changed.history { browser?.history.reload() }
        if changed.bookmarks { browser?.bookmarks.reload() }
        if changed.hidden { browser?.curtain.reload() }
        if changed.spaces { browser?.adoptSpaces() }
        if changed.prefs, let prefs = changed.prefsBody { apply(prefs) }
        for space in changed.sessions { browser?.adoptSyncedSession(space) }
        if changed.extensions, #available(macOS 15.4, *) { Extensions.shared.adoptSyncedCopies() }
        if changed.logins { browser?.relist() }
        let jars = changed.cookies
        Task { await Self.syncCookieJars(pull: jars, cloud: cloud) }
        if changed.paused {
            detail = "iCloud is still downloading some of this browser's files. Search will pick them up when they arrive."
        } else {
            detail = Self.describe(cloud: cloud)
            if changed.passwordKeyMissing {
                detail += " Saved passwords are waiting for iCloud Keychain."
            }
        }
        working = false
        if changed.paused {
            again = false
            schedule(after: 30)
        } else if again {
            again = false
            schedule()
        }
    }

    @MainActor
    private func apply(_ body: PrefBody) {
        guard let browser else { return }
        if browser.prefs.usesSpaces != body.spaces { browser.prefs.usesSpaces = body.spaces }
        if Vault.never != Set(body.never) { Vault.never = Set(body.never) }
    }

    // MARK: - where it lives

    static var deviceID: String {
        if let saved = Store.settings.string(forKey: "sync.device"), !saved.isEmpty { return saved }
        let made = UUID().uuidString
        Store.settings.set(made, forKey: "sync.device")
        return made
    }

    /// The iCloud Drive folder Finder shows, under a name of this app's own.
    /// No entitlement: the app isn't sandboxed, and this is the user's Drive.
    static func cloudRoot() -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &directory), directory.boolValue else {
            return nil
        }
        let folder = base.appendingPathComponent("Search by Noah", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return folder
    }

    private static func describe(cloud: URL) -> String {
        let names = deviceNames(cloud: cloud).filter { $0.id != deviceID }.map(\.name)
        if names.isEmpty {
            return "On iCloud Drive. Another Mac on this account picks it up from Settings, or on its own"
        }
        let who = names.prefix(3).joined(separator: ", ")
        return "Up to date with \(who)"
    }

    private static func deviceNames(cloud: URL) -> [(id: String, name: String)] {
        let folder = cloud.appendingPathComponent("devices", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls.compactMap { url in
            guard let card = decode(DeviceCard.self, url) else { return nil }
            return (url.deletingPathExtension().lastPathComponent, card.name)
        }
    }

    // MARK: - one pass

    struct Changed {
        var history = false
        var bookmarks = false
        var hidden = false
        var spaces = false
        var extensions = false
        var prefs = false
        var prefsBody: PrefBody?
        var sessions: [UUID] = []
        var cookies: [String] = []
        var logins = false
        var passwordKeyMissing = false
        /// A file was still only in iCloud, so this pass left it alone.
        var paused = false
    }

    /// Set for the duration of one pass when a file was left in iCloud.
    /// One pass runs at a time.
    private static var cloudPaused = false

    /// `jars` is empty in the check that runs without opening a window.
    /// Those ids are the space ids whose cookie files should be looked at.
    /// The window's own objects stay on the main thread.
    @discardableResult
    static func exchange(local: URL, cloud: URL, device: String, state: inout State, jars: [String] = []) -> Changed {
        cloudPaused = false
        var changed = Changed()
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let name = Host.current().localizedName ?? "Mac"
        let cardURL = cloud.appendingPathComponent("devices/\(device).json")
        if stillInCloud(cardURL) {
            notePaused(cardURL)
        } else {
            let card = decode(DeviceCard.self, cardURL)
            if card?.name != name || (card?.seen.timeIntervalSinceNow ?? -999) < -60 {
                put(encode(DeviceCard(name: name, seen: Date())), cardURL)
            }
        }

        if let body = mergePrefs(local: local, cloud: cloud, device: device, state: &state) {
            changed.prefs = true
            changed.prefsBody = body
        }
        changed.spaces = mergeSpaces(local: local, cloud: cloud, device: device, state: &state)
        changed.history = mergeHistory(local: local, cloud: cloud, device: device, state: &state)
        changed.bookmarks = mergeBookmarks(local: local, cloud: cloud, device: device, state: &state)
        changed.hidden = mergeHidden(local: local, cloud: cloud, device: device, state: &state)
        changed.extensions = mergeExtensions(local: local, cloud: cloud, state: &state)
        changed.sessions = mergeSessions(local: local, cloud: cloud, device: device, state: &state)
        if !jars.isEmpty {
            changed.cookies = mergeCookies(jars: jars, cloud: cloud, device: device, state: &state)
            let passwords = mergePasswords(cloud: cloud, state: &state)
            changed.logins = passwords.changed
            changed.passwordKeyMissing = passwords.waiting
        }
        changed.paused = cloudPaused
        return changed
    }

    // MARK: - history

    struct Visit: Codable, Equatable {
        var url: String
        var key: String
        var title: String
        var count: Int
        var last: Date
    }

    static func mergeVisits(_ local: [Visit], _ remote: [Visit], gone: [String: Date]) -> [Visit] {
        var byKey: [String: Visit] = [:]
        func take(_ visit: Visit) {
            if let when = gone[visit.key], when >= visit.last { return }
            if var have = byKey[visit.key] {
                let newer = visit.last >= have.last ? visit : have
                var kept = newer
                kept.count = max(have.count, visit.count)
                if kept.title.isEmpty { kept.title = have.title.isEmpty ? visit.title : have.title }
                byKey[visit.key] = kept
            } else {
                byKey[visit.key] = visit
            }
        }
        local.forEach(take)
        remote.forEach(take)
        return byKey.values.sorted { $0.last > $1.last }.prefix(2_000).map { $0 }
    }

    private static func mergeHistory(local: URL, cloud: URL, device: String, state: inout State) -> Bool {
        let file = local.appendingPathComponent("history.json")
        let remoteURL = cloud.appendingPathComponent("history.json")
        if stillInCloud(remoteURL) { notePaused(remoteURL); return false }
        if FileManager.default.fileExists(atPath: file.path), decode([Visit].self, file) == nil { return false }
        let localVisits = decode([Visit].self, file) ?? []
        let remote = decode(Marked<[Visit]>.self, remoteURL)
        var gone = remote?.gone ?? [:]
        for key in state.historyKeys where !localVisits.contains(where: { $0.key == key }) {
            gone[key] = Date()
        }
        let merged = mergeVisits(localVisits, remote?.body ?? [], gone: gone)
        let wroteLocal = writeIfDifferent(merged, file)
        publish(merged, gone: prune(gone), stamps: [:], device: device, url: remoteURL)
        state.historyKeys = merged.map(\.key)
        return wroteLocal
    }

    // MARK: - bookmarks

    struct Placed {
        var node: Bookmark
        var parent: UUID?
        var index: Int
    }

    static func flatten(_ nodes: [Bookmark], parent: UUID? = nil) -> [UUID: Placed] {
        var out: [UUID: Placed] = [:]
        for (index, node) in nodes.enumerated() {
            var copy = node
            let children = copy.children
            copy.children = nil
            out[node.id] = Placed(node: copy, parent: parent, index: index)
            if let children {
                for (id, placed) in flatten(children, parent: node.id) { out[id] = placed }
            }
        }
        return out
    }

    static func rebuild(_ placed: [UUID: Placed]) -> [Bookmark] {
        func children(of parent: UUID?) -> [Bookmark] {
            placed.values.filter { $0.parent == parent }.sorted { $0.index < $1.index }.map { item in
                var node = item.node
                let nested = children(of: node.id)
                if node.url == nil || !nested.isEmpty { node.children = nested }
                return node
            }
        }
        return children(of: nil)
    }

    static func mergeMarks(
        _ local: [Bookmark], _ remote: [Bookmark],
        localStamps: [String: Date], remoteStamps: [String: Date], gone: [String: Date]
    ) -> [Bookmark] {
        let left = flatten(local)
        let right = flatten(remote)
        var placed: [UUID: Placed] = [:]
        for id in Set(left.keys).union(right.keys) {
            let key = id.uuidString
            let lStamp = localStamps[key] ?? .distantPast
            let rStamp = remoteStamps[key] ?? .distantPast
            if let when = gone[key], when >= max(lStamp, rStamp) { continue }
            switch (left[id], right[id]) {
            case let (l?, r?): placed[id] = lStamp >= rStamp ? l : r
            case let (l?, nil): placed[id] = l
            case let (nil, r?): placed[id] = r
            case (nil, nil): break
            }
        }
        return rebuild(placed)
    }

    private static func mergeBookmarks(local: URL, cloud: URL, device: String, state: inout State) -> Bool {
        let file = local.appendingPathComponent("bookmarks.json")
        let remoteURL = cloud.appendingPathComponent("bookmarks.json")
        if stillInCloud(remoteURL) { notePaused(remoteURL); return false }
        if FileManager.default.fileExists(atPath: file.path), decode([Bookmark].self, file) == nil { return false }
        let localMarks = decode([Bookmark].self, file) ?? []
        let remote = decode(Marked<[Bookmark]>.self, remoteURL)
        var gone = remote?.gone ?? [:]
        let localIDs = Set(flatten(localMarks).keys.map(\.uuidString))
        for id in state.bookmarkIDs where !localIDs.contains(id) { gone[id] = Date() }
        var stamps = remote?.stamps ?? [:]
        for (id, placed) in flatten(localMarks) {
            let key = id.uuidString
            let hash = markHash(placed.node, parent: placed.parent, index: placed.index)
            if state.bookmarkHashes[key] != hash {
                stamps[key] = Date()
                state.bookmarkHashes[key] = hash
            } else if stamps[key] == nil {
                stamps[key] = state.bookmarkStamps[key] ?? .distantPast
            }
        }
        let merged = mergeMarks(localMarks, remote?.body ?? [], localStamps: stamps, remoteStamps: remote?.stamps ?? [:], gone: gone)
        let wrote = writeIfDifferent(merged, file)
        publish(merged, gone: prune(gone), stamps: stamps, device: device, url: remoteURL)
        state.bookmarkIDs = flatten(merged).keys.map(\.uuidString)
        state.bookmarkStamps = stamps
        return wrote
    }

    private static func markHash(_ node: Bookmark, parent: UUID?, index: Int) -> String {
        let kids = (node.children ?? []).map(\.id.uuidString).joined(separator: ",")
        return "\(node.title)\u{1}\(node.url ?? "")\u{1}\(parent?.uuidString ?? "")\u{1}\(index)\u{1}\(kids)"
    }

    // MARK: - spaces, hidden, prefs

    static func mergeSpaceLists(_ newer: [Space], _ older: [Space], gone: [String: Date]) -> [Space] {
        func live(_ space: Space) -> Bool {
            gone[space.id.uuidString] == nil
        }
        var result = newer.filter(live)
        let ids = Set(result.map(\.id))
        for space in older where !ids.contains(space.id) && live(space) { result.append(space) }
        let first = result.first(where: \.isFirst) ?? Space(id: Space.firstID, name: "Personal", colour: 0)
        return [first] + result.filter { !$0.isFirst }
    }

    private static func mergeSpaces(local: URL, cloud: URL, device: String, state: inout State) -> Bool {
        let file = local.appendingPathComponent("spaces.json")
        let remoteURL = cloud.appendingPathComponent("spaces.json")
        if stillInCloud(remoteURL) { notePaused(remoteURL); return false }
        let localSpaces = decode([Space].self, file) ?? []
        let remote = decode(Marked<[Space]>.self, remoteURL)
        var gone = remote?.gone ?? [:]
        let ids = Set(localSpaces.map(\.id.uuidString))
        for id in state.spaceIDs where !ids.contains(id) { gone[id] = Date() }
        let localDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let remoteDate = remote?.updated ?? .distantPast
        let merged = localDate >= remoteDate
            ? mergeSpaceLists(localSpaces, remote?.body ?? [], gone: gone)
            : mergeSpaceLists(remote?.body ?? [], localSpaces, gone: gone)
        let wrote = writeIfDifferent(merged, file)
        publish(merged, gone: prune(gone), stamps: [:], device: device, url: remoteURL)
        state.spaceIDs = merged.map(\.id.uuidString)
        return wrote
    }

    struct VeilRow: Codable, Equatable {
        var selector: String
        var label: String
        var note: String?
        var date: Date
    }

    static func mergeVeils(
        _ local: [String: [VeilRow]], _ remote: [String: [VeilRow]], gone: [String: Date]
    ) -> [String: [VeilRow]] {
        let hosts = Set(local.keys).union(remote.keys)
        var out: [String: [VeilRow]] = [:]
        for host in hosts {
            var bySelector: [String: VeilRow] = [:]
            for row in (local[host] ?? []) + (remote[host] ?? []) {
                let key = host + "\n" + row.selector
                if let when = gone[key], when >= row.date { continue }
                if let have = bySelector[row.selector], have.date >= row.date { continue }
                bySelector[row.selector] = row
            }
            if !bySelector.isEmpty { out[host] = bySelector.values.sorted { $0.date < $1.date } }
        }
        return out
    }

    private static func mergeHidden(local: URL, cloud: URL, device: String, state: inout State) -> Bool {
        let file = local.appendingPathComponent("hidden.json")
        let remoteURL = cloud.appendingPathComponent("hidden.json")
        if stillInCloud(remoteURL) { notePaused(remoteURL); return false }
        let localRows = decode([String: [VeilRow]].self, file) ?? [:]
        let remote = decode(Marked<[String: [VeilRow]]>.self, remoteURL)
        var gone = remote?.gone ?? [:]
        func keys(_ rows: [String: [VeilRow]]) -> Set<String> {
            Set(rows.flatMap { host, list in list.map { host + "\n" + $0.selector } })
        }
        for key in state.hiddenKeys where !keys(localRows).contains(key) { gone[key] = Date() }
        let merged = mergeVeils(localRows, remote?.body ?? [:], gone: gone)
        let wrote = writeIfDifferent(merged, file)
        publish(merged, gone: prune(gone), stamps: [:], device: device, url: remoteURL)
        state.hiddenKeys = Array(keys(merged))
        return wrote
    }

    struct PrefBody: Codable, Equatable {
        var spaces: Bool
        var never: [String]
        /// When the spaces switch last moved. Missing in a file written
        /// before it was kept; the file's own date stands in.
        var spacesAt: Date?
        /// When each "never ask" site was added. A site only one Mac has
        /// is kept; a removal wins only if it is later than the add.
        var neverAt: [String: Date]?

        enum CodingKeys: String, CodingKey {
            case spaces, never, spacesAt, neverAt
        }

        init(spaces: Bool, never: [String], spacesAt: Date?, neverAt: [String: Date]?) {
            self.spaces = spaces
            self.never = never
            self.spacesAt = spacesAt
            self.neverAt = neverAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            spaces = try c.decode(Bool.self, forKey: .spaces)
            never = try c.decodeIfPresent([String].self, forKey: .never) ?? []
            spacesAt = try c.decodeIfPresent(Date.self, forKey: .spacesAt)
            neverAt = try c.decodeIfPresent([String: Date].self, forKey: .neverAt)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(spaces, forKey: .spaces)
            try c.encode(never, forKey: .never)
            try c.encodeIfPresent(spacesAt, forKey: .spacesAt)
            try c.encodeIfPresent(neverAt, forKey: .neverAt)
        }
    }

    /// Sites told "never ask", from both Macs. A removal is a date in `gone`.
    static func mergeNever(
        _ local: [String], _ remote: [String],
        localAt: [String: Date], remoteAt: [String: Date], gone: [String: Date]
    ) -> [String] {
        var kept: [String] = []
        for host in Set(local).union(remote) {
            let latest = max(localAt[host] ?? .distantPast, remoteAt[host] ?? .distantPast)
            if let when = gone[host], when >= latest { continue }
            kept.append(host)
        }
        return kept.sorted()
    }

    private static func mergePrefs(local: URL, cloud: URL, device: String, state: inout State) -> PrefBody? {
        let file = local.appendingPathComponent("prefs-sync.json")
        let remoteURL = cloud.appendingPathComponent("prefs.json")
        if stillInCloud(remoteURL) { notePaused(remoteURL); return nil }
        let neverNow = (Store.settings.stringArray(forKey: Vault.neverKey) ?? []).sorted()
        let current = PrefBody(
            spaces: Store.settings.bool(forKey: "spaces"),
            never: neverNow,
            spacesAt: Store.settings.object(forKey: "sync.spacesAt") as? Date,
            neverAt: state.neverStamps
        )
        let remote = decode(Marked<PrefBody>.self, remoteURL)
        let localDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        var gone = remote?.gone ?? [:]
        if !state.neverKeys.isEmpty {
            for host in state.neverKeys where !neverNow.contains(host) { gone[host] = Date() }
        }
        var localAt = state.neverStamps
        for host in neverNow where !state.neverKeys.contains(host) { localAt[host] = Date() }
        let remoteAt = remote?.body.neverAt ?? Dictionary(
            uniqueKeysWithValues: (remote?.body.never ?? []).map { ($0, remote?.updated ?? .distantPast) }
        )
        let never = mergeNever(neverNow, remote?.body.never ?? [], localAt: localAt, remoteAt: remoteAt, gone: gone)
        var stamps: [String: Date] = [:]
        for host in never {
            stamps[host] = max(localAt[host] ?? .distantPast, remoteAt[host] ?? .distantPast)
        }
        let localSpacesAt = current.spacesAt ?? localDate
        let remoteSpacesAt = remote?.body.spacesAt ?? remote?.updated ?? .distantPast
        let spaces = localSpacesAt >= remoteSpacesAt ? current.spaces : (remote?.body.spaces ?? current.spaces)
        let body = PrefBody(
            spaces: spaces,
            never: never,
            spacesAt: max(localSpacesAt, remoteSpacesAt),
            neverAt: stamps
        )
        writeIfDifferent(body, file)
        publish(body, gone: prune(gone), stamps: [:], device: device, url: remoteURL)
        state.neverKeys = never
        state.neverStamps = stamps
        let same = body.spaces == current.spaces && body.never == current.never
        return same ? nil : body
    }

    // MARK: - tabs

    struct RemoteSession: Codable {
        var updated: Date
        var tabs: [Session.Entry]
        var active: Int
    }

    /// The newest row for a space, unless it is the same row already open.
    static func winningSession(_ candidates: [RemoteSession], local: Session.Shape, localUpdated: Date) -> RemoteSession? {
        guard let newest = candidates.max(by: { $0.updated < $1.updated }) else { return nil }
        let same = newest.tabs.map(\.url) == local.tabs.map(\.url) && newest.active == local.active
        if same || newest.updated <= localUpdated { return nil }
        return newest
    }

    private static func mergeSessions(local: URL, cloud: URL, device: String, state: inout State) -> [UUID] {
        pushSessions(local: local, cloud: cloud, device: device, state: &state)
        let folder = cloud.appendingPathComponent("sessions", isDirectory: true)
        guard let devices = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        var byName: [String: [RemoteSession]] = [:]
        for deviceFolder in devices {
            guard let files = try? FileManager.default.contentsOfDirectory(at: deviceFolder, includingPropertiesForKeys: nil) else { continue }
            for file in files {
                if stillInCloud(file) { notePaused(file); continue }
                guard let session = decode(RemoteSession.self, file) else { continue }
                byName[file.lastPathComponent, default: []].append(session)
            }
        }
        var adopted: [UUID] = []
        for (name, candidates) in byName {
            let file = local.appendingPathComponent(name)
            let shape = decode(Session.Shape.self, file) ?? Session.Shape(tabs: [], active: 0)
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard let winner = winningSession(candidates, local: shape, localUpdated: modified) else { continue }
            let next = Session.Shape(tabs: winner.tabs, active: winner.active)
            put(encode(next), file)
            state.hashes["session:" + name] = digest(encode(next) ?? Data())
            adopted.append(spaceID(forSessionName: name))
        }
        return adopted
    }

    static func pushSessions(local: URL, cloud: URL, device: String, state: inout State) {
        for file in sessionFiles(in: local) {
            guard let data = try? Data(contentsOf: file),
                  let shape = try? JSONDecoder().decode(Session.Shape.self, from: data) else { continue }
            let hash = digest(data)
            let key = "session:" + file.lastPathComponent
            if state.hashes[key] == hash { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let remote = RemoteSession(updated: modified, tabs: shape.tabs, active: shape.active)
            let dest = cloud.appendingPathComponent("sessions/\(device)/\(file.lastPathComponent)")
            put(encode(remote), dest)
            state.hashes[key] = hash
        }
    }

    static func spaceID(forSessionName name: String) -> UUID {
        if name == "session.json" { return Space.firstID }
        let stem = name.replacingOccurrences(of: "session-", with: "").replacingOccurrences(of: ".json", with: "")
        return UUID(uuidString: stem) ?? Space.firstID
    }

    private static func sessionFiles(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { name in
                let file = name.lastPathComponent
                return file == "session.json" || (file.hasPrefix("session-") && file.hasSuffix(".json"))
            } ?? []
    }

    // MARK: - extensions

    struct Stamp: Codable {
        var updated: Date
        var hash: String
    }

    struct ExtensionNote: Codable, Equatable {
        var hash: String
        var updated: Date
        var record: Installed?
    }

    struct ExtensionBook: Codable, Equatable {
        var notes: [String: ExtensionNote]
        var gone: [String: Date]
    }

    enum ExtensionSide: Equatable { case local, remote, drop }

    /// One extension only one Mac installed is kept. The same extension
    /// changed on both keeps the later copy. A removal wins only when it
    /// is later than both copies.
    static func chooseExtensions(
        local: [String: ExtensionNote], remote: [String: ExtensionNote], gone: [String: Date]
    ) -> [String: ExtensionSide] {
        var out: [String: ExtensionSide] = [:]
        for id in Set(local.keys).union(remote.keys) {
            let left = local[id]?.updated ?? .distantPast
            let right = remote[id]?.updated ?? .distantPast
            if let when = gone[id], when >= left, when >= right {
                out[id] = .drop
                continue
            }
            switch (local[id], remote[id]) {
            case (_?, nil): out[id] = .local
            case (nil, _?): out[id] = .remote
            case let (l?, r?): out[id] = l.updated >= r.updated ? .local : .remote
            case (nil, nil): break
            }
        }
        return out
    }

    private static func mergeExtensions(local: URL, cloud: URL, state: inout State) -> Bool {
        let source = local.appendingPathComponent("Extensions", isDirectory: true)
        let dest = cloud.appendingPathComponent("Extensions", isDirectory: true)
        let bookURL = cloud.appendingPathComponent("extensions.json")
        if stillInCloud(bookURL) { notePaused(bookURL); return false }
        let localInstalled = readInstalled(source)
        let remoteInstalled = readInstalled(dest)
        let book = decode(ExtensionBook.self, bookURL)
        let legacy = book == nil ? decode(Stamp.self, bookURL) : nil
        var gone = book?.gone ?? [:]
        let localIDs = extensionIDs(in: source)
        if !state.extensionIDs.isEmpty {
            for id in state.extensionIDs where !localIDs.contains(id) { gone[id] = Date() }
        }
        var localNotes: [String: ExtensionNote] = [:]
        for id in localIDs {
            let folder = source.appendingPathComponent(id, isDirectory: true)
            let hash = treeHash(folder)
            let folderDate = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let record = localInstalled[id]
            let signature = record.map { digest(encode($0) ?? Data()) } ?? ""
            let updated: Date
            if let prior = state.extensionFolderHashes[id] {
                let same = prior == hash && state.extensionRecords[id] == signature
                updated = same ? (state.extensionStamps[id] ?? folderDate) : Date()
            } else {
                updated = folderDate
            }
            localNotes[id] = ExtensionNote(hash: hash, updated: updated, record: record)
        }
        var remoteNotes = book?.notes.filter { isExtensionFolder($0.key) } ?? [:]
        for id in extensionIDs(in: dest) where remoteNotes[id] == nil {
            let folder = dest.appendingPathComponent(id, isDirectory: true)
            let folderDate = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            remoteNotes[id] = ExtensionNote(
                hash: treeHash(folder),
                updated: legacy.map { max($0.updated, folderDate) } ?? folderDate,
                record: remoteInstalled[id]
            )
        }
        let choice = chooseExtensions(local: localNotes, remote: remoteNotes, gone: gone)
        var changed = false
        var notes: [String: ExtensionNote] = [:]
        var records: [String: Installed] = [:]
        for (id, side) in choice {
            switch side {
            case .drop:
                if FileManager.default.fileExists(atPath: source.appendingPathComponent(id).path) {
                    try? FileManager.default.removeItem(at: source.appendingPathComponent(id))
                    changed = true
                }
                try? FileManager.default.removeItem(at: dest.appendingPathComponent(id))
            case .local:
                let folder = dest.appendingPathComponent(id, isDirectory: true)
                let same = remoteNotes[id]?.hash == localNotes[id]?.hash
                    && FileManager.default.fileExists(atPath: folder.path)
                if same || copyFolder(id, from: source, to: dest) {
                    if let note = localNotes[id] { notes[id] = note }
                    if let record = localInstalled[id] ?? remoteInstalled[id] { records[id] = record }
                } else {
                    cloudPaused = true
                    if let note = remoteNotes[id] { notes[id] = note }
                    if let record = remoteInstalled[id] ?? localInstalled[id] { records[id] = record }
                }
            case .remote:
                let folder = source.appendingPathComponent(id, isDirectory: true)
                let same = localNotes[id]?.hash == remoteNotes[id]?.hash
                    && FileManager.default.fileExists(atPath: folder.path)
                if same || copyFolder(id, from: dest, to: source) {
                    if !same { changed = true }
                    if let note = remoteNotes[id] { notes[id] = note }
                    if let record = remoteInstalled[id] ?? localInstalled[id] { records[id] = record }
                } else {
                    cloudPaused = true
                    if let note = localNotes[id] { notes[id] = note }
                    if let record = localInstalled[id] { records[id] = record }
                }
            }
        }
        let list = records.values.sorted { $0.name < $1.name }
        if writeIfDifferent(list, source.appendingPathComponent("installed.json")) { changed = true }
        _ = writeIfDifferent(list, dest.appendingPathComponent("installed.json"))
        let next = ExtensionBook(notes: notes, gone: prune(gone))
        if book != next { put(encode(next), bookURL) }
        state.extensionIDs = notes.keys.sorted()
        state.extensionFolderHashes = notes.mapValues(\.hash)
        state.extensionStamps = notes.mapValues(\.updated)
        state.extensionRecords = records.mapValues { digest(encode($0) ?? Data()) }
        state.extensionHash = digest(Data(state.extensionIDs.joined(separator: "\n").utf8))
        state.extensionSeen = notes.values.map(\.updated).max() ?? .distantPast
        return changed
    }

    private static func extensionIDs(in root: URL) -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard isExtensionFolder(name) else { return nil }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return nil }
            return name
        }
    }

    private static func readInstalled(_ root: URL) -> [String: Installed] {
        var out: [String: Installed] = [:]
        for item in decode([Installed].self, root.appendingPathComponent("installed.json")) ?? [] {
            out[item.id] = item
        }
        return out
    }

    /// Chrome's own id: 32 letters, a through p. iCloud names a conflict
    /// "that id 2", and copying the conflict is what froze the window.
    static func isExtensionFolder(_ name: String) -> Bool {
        name.count == 32 && name.utf8.allSatisfy { $0 >= 97 && $0 <= 112 }
    }

    /// True when the file is an iCloud placeholder whose bytes are not
    /// on this Mac. Reading or copying it waits inside the kernel.
    static func stillInCloud(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return false }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        if let values = try? url.resourceValues(forKeys: keys),
           values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus == .notDownloaded {
            return true
        }
        guard directory.boolValue,
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        else { return false }
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isUbiquitousItem == true,
                  values.ubiquitousItemDownloadingStatus == .notDownloaded else { continue }
            return true
        }
        return false
    }

    private static func notePaused(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        cloudPaused = true
    }

    @discardableResult
    private static func copyFolder(_ id: String, from root: URL, to destRoot: URL) -> Bool {
        let source = root.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        if stillInCloud(source) {
            notePaused(source)
            return false
        }
        try? FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        let dest = destRoot.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path), treeHash(dest) == treeHash(source) { return true }
        let temporary = destRoot.appendingPathComponent(".next-\(id)")
        try? FileManager.default.removeItem(at: temporary)
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: temporary, to: dest)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    // MARK: - cookies

    struct Crumb: Codable, Equatable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Date?
        var secure: Bool
        var seen: Date

        var id: String { "\(name)\n\(domain)\n\(path)" }
    }

    struct CookieMark: Codable, Equatable {
        var value: String
        var seen: Date
    }

    /// A cookie this Mac has not changed keeps the date it already had, so a
    /// newer value from the other Mac is not overwritten just because we
    /// looked at ours. The first time both have it and they differ, the copy
    /// already in iCloud wins — there is no earlier date to trust.
    static func datedCrumbs(
        _ local: [Crumb], remote: [Crumb], marks: [String: CookieMark]
    ) -> [Crumb] {
        let others = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        let now = Date()
        return local.map { crumb in
            var copy = crumb
            if let mark = marks[crumb.id] {
                copy.seen = mark.value == crumb.value ? mark.seen : now
            } else if let other = others[crumb.id] {
                copy.seen = other.value == crumb.value ? other.seen : .distantPast
            } else {
                copy.seen = now
            }
            return copy
        }
    }

    static func mergeCrumbs(_ local: [Crumb], _ remote: [Crumb], gone: [String: Date]) -> [Crumb] {
        var byID: [String: Crumb] = [:]
        for crumb in local + remote {
            if let when = gone[crumb.id], when >= crumb.seen { continue }
            if let have = byID[crumb.id], have.seen >= crumb.seen { continue }
            byID[crumb.id] = crumb
        }
        return Array(byID.values)
    }

    /// Writes each jar up and returns the space ids whose jar arrived newer
    /// from another Mac, for the caller to hand to WebKit.
    private static func mergeCookies(jars: [String], cloud: URL, device: String, state: inout State) -> [String] {
        var due: [String] = []
        for id in jars {
            let remoteURL = cloud.appendingPathComponent("cookies/\(id).json")
            if stillInCloud(remoteURL) { notePaused(remoteURL); continue }
            let remote = decode(Marked<[Crumb]>.self, remoteURL)
            // The local jar is read asynchronously below; here we only notice
            // a remote jar we haven't applied. The push happens in pullCookies
            // once WebKit has answered, and again on the next pass.
            if let remote, remote.device != device, state.cookieSeen[id] != remote.updated {
                due.append(id)
            }
        }
        return due
    }

    @MainActor
    private static func jarIDs(_ browser: Browser) -> [String] {
        jars(browser).map(\.0)
    }

    @MainActor
    private static func jars(_ browser: Browser) -> [(String, WKWebsiteDataStore)] {
        var out: [(String, WKWebsiteDataStore)] = [(Space.firstID.uuidString, WKWebsiteDataStore.default())]
        let sharing = Set(browser.spaces.filter { $0.sharesSignIns == true }.map(\.id))
        for space in browser.spaces where space.id != Space.firstID && !sharing.contains(space.id) {
            out.append((space.id.uuidString, WKWebsiteDataStore(forIdentifier: space.id)))
        }
        return out
    }

    @MainActor
    private static func syncCookieJars(pull ids: [String], cloud: URL) async {
        await pullCookies(ids, cloud: cloud)
        await pushCookies(cloud: cloud, device: deviceID)
    }

    @MainActor
    private static func pullCookies(_ ids: [String], cloud: URL) async {
        guard let browser = CloudSync.shared.browser else { return }
        let stores = Dictionary(uniqueKeysWithValues: jars(browser))
        for id in ids {
            guard let store = stores[id], let remote = decode(Marked<[Crumb]>.self, cloud.appendingPathComponent("cookies/\(id).json")) else { continue }
            let have = datedCrumbs(await cookies(of: store), remote: remote.body, marks: stateMarks(for: id))
            let merged = mergeCrumbs(have, remote.body, gone: remote.gone)
            for crumb in merged where !have.contains(where: { $0.id == crumb.id && $0.value == crumb.value }) {
                guard let cookie = HTTPCookie(properties: crumb.properties) else { continue }
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    store.httpCookieStore.setCookie(cookie) { done.resume() }
                }
            }
            var state = State.load(Store.folder)
            state.cookieSeen[id] = remote.updated
            state.cookieMarks[id] = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, CookieMark(value: $0.value, seen: $0.seen)) })
            state.cookieIDs[id] = merged.map(\.id)
            state.save(Store.folder)
        }
    }

    private static func stateMarks(for jar: String) -> [String: CookieMark] {
        State.load(Store.folder).cookieMarks[jar] ?? [:]
    }

    /// Called once a pass has the stores. Pushes the jars WebKit actually holds.
    @MainActor
    static func pushCookies(cloud: URL, device: String) async {
        guard let browser = shared.browser, !Store.testing, shared.enabled else { return }
        var state = State.load(Store.folder)
        for (id, store) in jars(browser) {
            let remoteURL = cloud.appendingPathComponent("cookies/\(id).json")
            if stillInCloud(remoteURL) { notePaused(remoteURL); continue }
            let remote = decode(Marked<[Crumb]>.self, remoteURL)
            let have = datedCrumbs(
                await cookies(of: store), remote: remote?.body ?? [], marks: state.cookieMarks[id] ?? [:]
            )
            var gone = remote?.gone ?? [:]
            let ids = Set(have.map(\.id))
            for known in state.cookieIDs[id] ?? [] where !ids.contains(known) { gone[known] = Date() }
            let merged = mergeCrumbs(have, remote?.body ?? [], gone: gone)
            publish(merged, gone: prune(gone), stamps: [:], device: device, url: remoteURL)
            state.cookieMarks[id] = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, CookieMark(value: $0.value, seen: $0.seen)) })
            state.cookieIDs[id] = merged.map(\.id)
        }
        state.save(Store.folder)
    }

    @MainActor
    private static func cookies(of store: WKWebsiteDataStore) async -> [Crumb] {
        let found: [HTTPCookie] = await withCheckedContinuation { done in
            store.httpCookieStore.getAllCookies { done.resume(returning: $0) }
        }
        let now = Date()
        return found.map {
            Crumb(
                name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                expires: $0.expiresDate, secure: $0.isSecure, seen: now
            )
        }
    }

    // MARK: - passwords

    struct LoginRow: Codable, Equatable {
        var host: String
        var user: String
        var password: String
        var changed: Date
        var used: Date?
        var clear: Bool

        var id: String { host + "\u{1}" + user }
    }

    struct LoginBook: Codable, Equatable {
        var rows: [LoginRow]
        var gone: [String: Date]
    }

    /// Logins only one Mac has are kept. The same account with two passwords
    /// keeps the one changed later. A deletion wins only when it is later
    /// than the password it removes. Equal dates keep the first one seen,
    /// which is this Mac's.
    static func mergeLogins(_ local: [LoginRow], _ remote: [LoginRow], gone: [String: Date]) -> [LoginRow] {
        var byID: [String: LoginRow] = [:]
        for row in local + remote {
            if let when = gone[row.id], when >= row.changed { continue }
            if let have = byID[row.id], have.changed >= row.changed { continue }
            byID[row.id] = row
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private struct PasswordResult {
        var changed = false
        var waiting = false
    }

    /// The file in iCloud Drive is ciphertext. The key is one synchronizable
    /// keychain item. A Mac that can see the file but not yet the key waits,
    /// and does not write a second key over the first.
    private static func mergePasswords(cloud: URL, state: inout State) -> PasswordResult {
        guard !Store.testing else { return PasswordResult() }
        let keyURL = cloud.appendingPathComponent("logins.key")
        let blobURL = cloud.appendingPathComponent("logins.bin")
        if stillInCloud(keyURL) || stillInCloud(blobURL) {
            if stillInCloud(keyURL) { notePaused(keyURL) }
            if stillInCloud(blobURL) { notePaused(blobURL) }
            var result = PasswordResult()
            result.waiting = true
            return result
        }
        let cloudID = (try? String(contentsOf: keyURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = PasswordResult()
        guard let key = SyncKey.matching(cloudID, cloudHasFile: FileManager.default.fileExists(atPath: blobURL.path)) else {
            result.waiting = cloudID != nil || FileManager.default.fileExists(atPath: blobURL.path)
            return result
        }
        if cloudID != key.id {
            try? key.id.write(to: keyURL, atomically: true, encoding: .utf8)
            let seen = (try? String(contentsOf: keyURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if seen != key.id {
                result.waiting = true
                return result
            }
        }
        let remote = (try? Data(contentsOf: blobURL)).flatMap { SyncKey.open($0, key: key.bytes) }
        if FileManager.default.fileExists(atPath: blobURL.path), remote == nil {
            result.waiting = true
            return result
        }
        let localRows = Vault.all().map {
            LoginRow(host: $0.host, user: $0.user, password: $0.password, changed: $0.changed, used: $0.used, clear: $0.clear)
        }
        var gone = remote?.gone ?? [:]
        let localIDs = Set(localRows.map(\.id))
        if !state.loginIDs.isEmpty {
            for id in state.loginIDs where !localIDs.contains(id) { gone[id] = Date() }
        }
        let merged = mergeLogins(localRows, remote?.rows ?? [], gone: gone)
        let mergedIDs = Set(merged.map(\.id))
        let byLocal = Dictionary(uniqueKeysWithValues: localRows.map { ($0.id, $0) })
        for row in merged {
            if let have = byLocal[row.id],
               have.password == row.password, have.changed == row.changed, have.clear == row.clear, have.used == row.used {
                continue
            }
            let wrote = Vault.save(
                host: row.host, user: row.user, password: row.password,
                used: row.used, clear: row.clear, changed: row.changed, keepChanged: true, quiet: true
            )
            if wrote { result.changed = true }
        }
        for row in localRows where !mergedIDs.contains(row.id) {
            Vault.forget(host: row.host, user: row.user, quiet: true)
            result.changed = true
        }
        let book = LoginBook(rows: merged, gone: prune(gone))
        if remote != book, let sealed = SyncKey.seal(book, key: key.bytes) {
            put(sealed, blobURL)
        }
        state.loginIDs = merged.map(\.id)
        return result
    }

    private struct SyncKey {
        var id: String
        var bytes: SymmetricKey

        static func matching(_ cloudID: String?, cloudHasFile: Bool) -> SyncKey? {
            if let have = load() {
                if let cloudID, cloudID != have.id { return nil }
                return have
            }
            if cloudID != nil || cloudHasFile { return nil }
            return make()
        }

        private static func load() -> SyncKey? {
            var out: CFTypeRef?
            let status = SecItemCopyMatching([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecReturnData as String: true,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary, &out)
            guard status == errSecSuccess, let row = out as? [String: Any],
                  let data = row[kSecValueData as String] as? Data, data.count == 32,
                  let id = row[kSecAttrComment as String] as? String, !id.isEmpty
            else { return nil }
            return SyncKey(id: id, bytes: SymmetricKey(data: data))
        }

        private static func make() -> SyncKey? {
            let key = SymmetricKey(size: .bits256)
            let id = UUID().uuidString
            let data = key.withUnsafeBytes { Data($0) }
            let added = SecItemAdd([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrComment as String: id,
                kSecValueData as String: data,
                kSecAttrSynchronizable as String: kCFBooleanTrue,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrLabel as String: "Search by Noah",
            ] as CFDictionary, nil) == errSecSuccess
            return added ? SyncKey(id: id, bytes: key) : nil
        }

        static func seal(_ book: LoginBook, key: SymmetricKey) -> Data? {
            guard let data = try? JSONEncoder().encode(book),
                  let box = try? AES.GCM.seal(data, using: key) else { return nil }
            return box.combined
        }

        static func open(_ data: Data, key: SymmetricKey) -> LoginBook? {
            guard let box = try? AES.GCM.SealedBox(combined: data),
                  let clear = try? AES.GCM.open(box, using: key) else { return nil }
            return try? JSONDecoder().decode(LoginBook.self, from: clear)
        }

        private static let service = "com.noahveenstra.search.sync"
        private static let account = "sync-key"
    }

    // MARK: - files

    struct Marked<Body: Codable>: Codable {
        var updated: Date
        var device: String
        var gone: [String: Date]
        var stamps: [String: Date]
        var body: Body
    }

    struct DeviceCard: Codable {
        var name: String
        var seen: Date
    }

    struct State: Codable {
        var historyKeys: [String] = []
        var bookmarkIDs: [String] = []
        var bookmarkHashes: [String: String] = [:]
        var bookmarkStamps: [String: Date] = [:]
        var spaceIDs: [String] = []
        var hiddenKeys: [String] = []
        var hashes: [String: String] = [:]
        var extensionHash = ""
        var extensionSeen = Date.distantPast
        var cookieSeen: [String: Date] = [:]
        var cookieMarks: [String: [String: CookieMark]] = [:]
        var cookieIDs: [String: [String]] = [:]
        var loginIDs: [String] = []
        var neverKeys: [String] = []
        var neverStamps: [String: Date] = [:]
        var extensionIDs: [String] = []
        var extensionFolderHashes: [String: String] = [:]
        var extensionStamps: [String: Date] = [:]
        var extensionRecords: [String: String] = [:]

        enum CodingKeys: String, CodingKey {
            case historyKeys, bookmarkIDs, bookmarkHashes, bookmarkStamps, spaceIDs, hiddenKeys, hashes
            case extensionHash, extensionSeen, cookieSeen, cookieMarks, cookieIDs, loginIDs
            case neverKeys, neverStamps, extensionIDs, extensionFolderHashes, extensionStamps, extensionRecords
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            historyKeys = try c.decodeIfPresent([String].self, forKey: .historyKeys) ?? []
            bookmarkIDs = try c.decodeIfPresent([String].self, forKey: .bookmarkIDs) ?? []
            bookmarkHashes = try c.decodeIfPresent([String: String].self, forKey: .bookmarkHashes) ?? [:]
            bookmarkStamps = try c.decodeIfPresent([String: Date].self, forKey: .bookmarkStamps) ?? [:]
            spaceIDs = try c.decodeIfPresent([String].self, forKey: .spaceIDs) ?? []
            hiddenKeys = try c.decodeIfPresent([String].self, forKey: .hiddenKeys) ?? []
            hashes = try c.decodeIfPresent([String: String].self, forKey: .hashes) ?? [:]
            extensionHash = try c.decodeIfPresent(String.self, forKey: .extensionHash) ?? ""
            extensionSeen = try c.decodeIfPresent(Date.self, forKey: .extensionSeen) ?? .distantPast
            cookieSeen = try c.decodeIfPresent([String: Date].self, forKey: .cookieSeen) ?? [:]
            cookieMarks = try c.decodeIfPresent([String: [String: CookieMark]].self, forKey: .cookieMarks) ?? [:]
            cookieIDs = try c.decodeIfPresent([String: [String]].self, forKey: .cookieIDs) ?? [:]
            loginIDs = try c.decodeIfPresent([String].self, forKey: .loginIDs) ?? []
            neverKeys = try c.decodeIfPresent([String].self, forKey: .neverKeys) ?? []
            neverStamps = try c.decodeIfPresent([String: Date].self, forKey: .neverStamps) ?? [:]
            extensionIDs = try c.decodeIfPresent([String].self, forKey: .extensionIDs) ?? []
            extensionFolderHashes = try c.decodeIfPresent([String: String].self, forKey: .extensionFolderHashes) ?? [:]
            extensionStamps = try c.decodeIfPresent([String: Date].self, forKey: .extensionStamps) ?? [:]
            extensionRecords = try c.decodeIfPresent([String: String].self, forKey: .extensionRecords) ?? [:]
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(historyKeys, forKey: .historyKeys)
            try c.encode(bookmarkIDs, forKey: .bookmarkIDs)
            try c.encode(bookmarkHashes, forKey: .bookmarkHashes)
            try c.encode(bookmarkStamps, forKey: .bookmarkStamps)
            try c.encode(spaceIDs, forKey: .spaceIDs)
            try c.encode(hiddenKeys, forKey: .hiddenKeys)
            try c.encode(hashes, forKey: .hashes)
            try c.encode(extensionHash, forKey: .extensionHash)
            try c.encode(extensionSeen, forKey: .extensionSeen)
            try c.encode(cookieSeen, forKey: .cookieSeen)
            try c.encode(cookieMarks, forKey: .cookieMarks)
            try c.encode(cookieIDs, forKey: .cookieIDs)
            try c.encode(loginIDs, forKey: .loginIDs)
            try c.encode(neverKeys, forKey: .neverKeys)
            try c.encode(neverStamps, forKey: .neverStamps)
            try c.encode(extensionIDs, forKey: .extensionIDs)
            try c.encode(extensionFolderHashes, forKey: .extensionFolderHashes)
            try c.encode(extensionStamps, forKey: .extensionStamps)
            try c.encode(extensionRecords, forKey: .extensionRecords)
        }

        static func load(_ folder: URL) -> State {
            decode(State.self, folder.appendingPathComponent("sync-state.json")) ?? State()
        }

        func save(_ folder: URL) {
            put(CloudSync.encode(self), folder.appendingPathComponent("sync-state.json"))
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        // A placeholder's bytes are not here. Data(contentsOf:) would wait
        // in the kernel until iCloud produced them.
        if stillInCloud(url) { notePaused(url); return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    @discardableResult
    static func writeIfDifferent<T: Codable & Equatable>(_ value: T, _ url: URL) -> Bool {
        if let have = decode(T.self, url), have == value { return false }
        put(encode(value), url)
        return true
    }

    static func publish<T: Codable & Equatable>(
        _ body: T, gone: [String: Date], stamps: [String: Date], device: String, url: URL
    ) {
        if let have = decode(Marked<T>.self, url), have.body == body, have.gone == gone, have.stamps == stamps {
            return
        }
        put(encode(Marked(updated: Date(), device: device, gone: gone, stamps: stamps, body: body)), url)
    }

    static func put(_ data: Data?, _ url: URL) {
        guard let data else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func prune(_ gone: [String: Date]) -> [String: Date] {
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        return gone.filter { $0.value >= cutoff }
    }

    static func treeHash(_ root: URL) -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return "missing" }
        var lines: [String] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasPrefix(".staging-") {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            lines.append("\(relative) \(values?.fileSize ?? 0)")
        }
        return digest(Data(lines.sorted().joined(separator: "\n").utf8))
    }

    static func replaceTree(from source: URL, to dest: URL) {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let parent = dest.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".next-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: temporary, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    // MARK: - the check

    static func selfTest() -> Bool {
        testSync()
    }

    private static func testSync() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                fputs("sync: \(message)\n", stderr)
                ok = false
            }
        }
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_000_100)
        let local = [Visit(url: "https://a.example/", key: "a.example", title: "A", count: 2, last: early)]
        let remote = [Visit(url: "https://a.example/", key: "a.example", title: "A2", count: 5, last: later)]
        let merged = mergeVisits(local, remote, gone: [:])
        check(merged.count == 1 && merged[0].count == 5 && merged[0].title == "A2", "history keeps the later visit and the higher count")
        let dropped = mergeVisits(local, remote, gone: ["a.example": later])
        check(dropped.isEmpty, "a forgotten page stays forgotten")

        let leftID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let rightID = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let left = [Bookmark(id: leftID, title: "Left", url: "https://left.example/", children: nil)]
        let right = [Bookmark(id: rightID, title: "Right", url: "https://right.example/", children: nil)]
        let both = mergeMarks(left, right, localStamps: [leftID.uuidString: later], remoteStamps: [rightID.uuidString: later], gone: [:])
        check(Set(both.map(\.title)) == ["Left", "Right"], "bookmarks from both Macs stay")
        let renamed = mergeMarks(
            [Bookmark(id: leftID, title: "New", url: "https://left.example/", children: nil)],
            [Bookmark(id: leftID, title: "Old", url: "https://left.example/", children: nil)],
            localStamps: [leftID.uuidString: later], remoteStamps: [leftID.uuidString: early], gone: [:]
        )
        check(renamed.first?.title == "New", "the later bookmark name wins")

        let shape = Session.Shape(tabs: [Session.Entry(url: "https://same.example/", title: "S", pin: nil, name: nil)], active: 0)
        let same = RemoteSession(updated: later, tabs: shape.tabs, active: 0)
        check(winningSession([same], local: shape, localUpdated: early) == nil, "the same tabs are not handed back")
        let other = RemoteSession(updated: later, tabs: [Session.Entry(url: "https://other.example/", title: "O", pin: nil, name: nil)], active: 0)
        check(winningSession([other], local: shape, localUpdated: early)?.tabs.first?.url == "https://other.example/", "a newer row replaces this one")

        let olderLogin = LoginRow(host: "a.example", user: "one", password: "old", changed: early, used: nil, clear: false)
        let newerLogin = LoginRow(host: "a.example", user: "one", password: "new", changed: later, used: nil, clear: false)
        let extra = LoginRow(host: "b.example", user: "two", password: "only-there", changed: early, used: nil, clear: false)
        let logins = mergeLogins([olderLogin], [newerLogin, extra], gone: [:])
        check(logins.count == 2 && logins.contains(where: { $0.password == "new" }) && logins.contains(where: { $0.host == "b.example" }), "the later password wins and a login only one Mac has is kept")
        let forgotten = mergeLogins([newerLogin], [olderLogin], gone: [newerLogin.id: later])
        check(forgotten.isEmpty, "a password deleted after it changed stays deleted")

        let kept = mergeNever(["a"], ["b"], localAt: ["a": early], remoteAt: ["b": early], gone: [:])
        check(kept == ["a", "b"], "sites told never-ask on either Mac are kept")
        let removed = mergeNever(["a"], ["a"], localAt: ["a": early], remoteAt: ["a": early], gone: ["a": later])
        check(removed.isEmpty, "a later never-ask removal wins")

        let localCrumb = Crumb(name: "sid", value: "ours", domain: "a.example", path: "/", expires: nil, secure: true, seen: early)
        let remoteCrumb = Crumb(name: "sid", value: "theirs", domain: "a.example", path: "/", expires: nil, secure: true, seen: later)
        let dated = datedCrumbs([localCrumb], remote: [remoteCrumb], marks: [:])
        let crumbMerged = mergeCrumbs(dated, [remoteCrumb], gone: [:])
        check(crumbMerged.first?.value == "theirs", "a first sync does not let this Mac's cookie overwrite the one already in iCloud")

        let noteEarly = ExtensionNote(hash: "1", updated: early, record: nil)
        let noteLate = ExtensionNote(hash: "2", updated: later, record: nil)
        let onlyHere = ExtensionNote(hash: "3", updated: early, record: nil)
        let picked = chooseExtensions(local: ["both": noteEarly, "here": onlyHere], remote: ["both": noteLate], gone: [:])
        check(picked["both"] == .remote && picked["here"] == .local, "a newer extension wins and one only this Mac has is kept")
        let realID = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        check(isExtensionFolder(realID), "a chrome extension id is a folder we sync")
        check(!isExtensionFolder(realID + " 2") && !isExtensionFolder(".next-" + realID), "an iCloud conflict copy is not an extension")
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("search-sync-plain-\(UUID().uuidString)")
        try? Data("ok".utf8).write(to: plain)
        check(!stillInCloud(plain), "a normal file is not treated as stuck in iCloud")
        try? FileManager.default.removeItem(at: plain)

        let secret = SymmetricKey(size: .bits256)
        let book = LoginBook(rows: [extra], gone: [:])
        if let sealed = SyncKey.seal(book, key: secret), let opened = SyncKey.open(sealed, key: secret) {
            check(opened == book, "a password book seals and opens")
        } else {
            check(false, "a password book seals and opens")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-sync-\(UUID().uuidString)", isDirectory: true)
        let macA = root.appendingPathComponent("a", isDirectory: true)
        let macB = root.appendingPathComponent("b", isDirectory: true)
        let drive = root.appendingPathComponent("cloud", isDirectory: true)
        put(encode([Visit(url: "https://from-a.example/", key: "from-a.example", title: "From A", count: 1, last: later)]), macA.appendingPathComponent("history.json"))
        var stateA = State()
        _ = exchange(local: macA, cloud: drive, device: "mac-a", state: &stateA)
        var stateB = State()
        let arrived = exchange(local: macB, cloud: drive, device: "mac-b", state: &stateB)
        let onB = decode([Visit].self, macB.appendingPathComponent("history.json")) ?? []
        check(arrived.history && onB.contains(where: { $0.key == "from-a.example" }), "a second Mac receives history through the folder")
        try? FileManager.default.removeItem(at: root)
        return ok
    }
}

private extension CloudSync.Crumb {
    var properties: [HTTPCookiePropertyKey: Any] {
        var fields: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path,
        ]
        if let expires { fields[.expires] = expires }
        if secure { fields[.secure] = "TRUE" }
        return fields
    }
}
