import CryptoKit
import Foundation
import WebKit

// One person's browser, on every Mac signed into the same iCloud account.
//
// The GitHub repository is the app. This is the browsing: tabs, history,
// bookmarks, spaces, what is hidden, extensions, cookies, and — through
// iCloud Keychain, not this folder — passwords. Nothing here is committed
// or released. A test run never reaches it.
//
// Each kind of file is merged, not replaced. A bookmark saved on one Mac
// and a page visited on the other both survive. The open tabs of a space
// follow whichever Mac touched that space last, and an identical row is
// left alone so two Macs don't hand the same tabs back and forth.

@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    @Published var detail = "Looking for iCloud Drive…"
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            Store.settings.set(enabled, forKey: Self.enabledKey)
            if enabled { schedule() }
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

    func start(browser: Browser) {
        guard !started else { return }
        started = true
        self.browser = browser
        guard !Store.testing else { return }
        Vault.shareAcrossDevices()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { CloudSync.shared.schedule() } }
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
    func pushSessionsNow() {
        guard !Store.testing, enabled, let cloud = Self.cloudRoot() else { return }
        var state = State.load(Store.folder)
        Self.pushSessions(local: Store.folder, cloud: cloud, device: Self.deviceID, state: &state)
        state.save(Store.folder)
    }

    private func schedule() {
        guard enabled, !Store.testing else { return }
        wait?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        wait = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func reconcile() {
        guard enabled, !Store.testing else { return }
        guard !working else { again = true; return }
        guard let cloud = Self.cloudRoot() else {
            detail = "Turn on iCloud Drive and this Mac will keep the others up to date"
            return
        }
        working = true
        var state = State.load(Store.folder)
        let changed = Self.exchange(local: Store.folder, cloud: cloud, device: Self.deviceID, state: &state, browser: browser)
        state.save(Store.folder)
        if changed.history { browser?.history.reload() }
        if changed.bookmarks { browser?.bookmarks.reload() }
        if changed.hidden { browser?.curtain.reload() }
        if changed.spaces { browser?.adoptSpaces() }
        if changed.prefs, let prefs = changed.prefsBody { apply(prefs) }
        for space in changed.sessions { browser?.adoptSyncedSession(space) }
        if changed.extensions, #available(macOS 15.4, *) { Extensions.shared.adoptSyncedCopies() }
        let jars = changed.cookies
        Task { await Self.syncCookieJars(pull: jars, cloud: cloud) }
        detail = Self.describe(cloud: cloud)
        working = false
        if again { again = false; schedule() }
    }

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
    }

    /// `browser` is nil in the check that runs without opening a window.
    @discardableResult
    static func exchange(local: URL, cloud: URL, device: String, state: inout State, browser: Browser?) -> Changed {
        var changed = Changed()
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let name = Host.current().localizedName ?? "Mac"
        let cardURL = cloud.appendingPathComponent("devices/\(device).json")
        let card = decode(DeviceCard.self, cardURL)
        if card?.name != name || (card?.seen.timeIntervalSinceNow ?? -999) < -60 {
            put(encode(DeviceCard(name: name, seen: Date())), cardURL)
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
        if browser != nil { changed.cookies = mergeCookies(local: local, cloud: cloud, device: device, state: &state) }
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
    }

    private static func mergePrefs(local: URL, cloud: URL, device: String, state: inout State) -> PrefBody? {
        let file = local.appendingPathComponent("prefs-sync.json")
        let remoteURL = cloud.appendingPathComponent("prefs.json")
        let onDisk = decode(PrefBody.self, file)
        let current = PrefBody(
            spaces: Store.settings.bool(forKey: "spaces"),
            never: (Store.settings.stringArray(forKey: Vault.neverKey) ?? []).sorted()
        )
        let remote = decode(Marked<PrefBody>.self, remoteURL)
        let localBody = onDisk ?? current
        let localDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let chosen = localDate >= (remote?.updated ?? .distantPast) ? localBody : (remote?.body ?? localBody)
        // What the person just set beats a file we haven't written yet.
        let body = current == localBody || onDisk == nil ? chosen : current
        writeIfDifferent(body, file)
        publish(body, gone: [:], stamps: [:], device: device, url: remoteURL)
        return body == current ? nil : body
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

    private static func mergeExtensions(local: URL, cloud: URL, state: inout State) -> Bool {
        let source = local.appendingPathComponent("Extensions", isDirectory: true)
        let dest = cloud.appendingPathComponent("Extensions", isDirectory: true)
        let stampURL = cloud.appendingPathComponent("extensions.json")
        let localHash = treeHash(source)
        let remote = decode(Stamp.self, stampURL)
        let empty = digest(Data())
        let localChanged = localHash != state.extensionHash && localHash != "missing"
        let remoteChanged = remote.map { $0.hash != state.extensionHash && $0.updated > state.extensionSeen } ?? false
        if (localHash == "missing" || localHash == empty), let remote, remote.hash != empty && remote.hash != "missing" {
            replaceTree(from: dest, to: source)
            state.extensionHash = remote.hash
            state.extensionSeen = remote.updated
            return true
        }
        if remoteChanged && !localChanged, let remote {
            replaceTree(from: dest, to: source)
            state.extensionHash = remote.hash
            state.extensionSeen = remote.updated
            return true
        }
        if localChanged && localHash != empty && localHash != remote?.hash {
            replaceTree(from: source, to: dest)
            let stamp = Stamp(updated: Date(), hash: localHash)
            put(encode(stamp), stampURL)
            state.extensionHash = localHash
            state.extensionSeen = stamp.updated
        }
        return false
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
    private static func mergeCookies(local: URL, cloud: URL, device: String, state: inout State) -> [String] {
        guard let browser = CloudSync.shared.browser else { return [] }
        var due: [String] = []
        for (id, store) in jars(browser) {
            let remoteURL = cloud.appendingPathComponent("cookies/\(id).json")
            let remote = decode(Marked<[Crumb]>.self, remoteURL)
            // The local jar is read asynchronously below; here we only notice
            // a remote jar we haven't applied. The push happens in pullCookies
            // once WebKit has answered, and again on the next pass.
            if let remote, remote.device != device, state.cookieSeen[id] != remote.updated {
                due.append(id)
                _ = store
            }
        }
        return due
    }

    private static func jars(_ browser: Browser) -> [(String, WKWebsiteDataStore)] {
        var out: [(String, WKWebsiteDataStore)] = [(Space.firstID.uuidString, WKWebsiteDataStore.default())]
        let sharing = Set(browser.spaces.filter { $0.sharesSignIns == true }.map(\.id))
        for space in browser.spaces where space.id != Space.firstID && !sharing.contains(space.id) {
            out.append((space.id.uuidString, WKWebsiteDataStore(forIdentifier: space.id)))
        }
        return out
    }

    private static func syncCookieJars(pull ids: [String], cloud: URL) async {
        await pullCookies(ids, cloud: cloud)
        await pushCookies(cloud: cloud, device: deviceID)
    }

    private static func pullCookies(_ ids: [String], cloud: URL) async {
        guard let browser = CloudSync.shared.browser else { return }
        let stores = Dictionary(uniqueKeysWithValues: jars(browser))
        for id in ids {
            guard let store = stores[id], let remote = decode(Marked<[Crumb]>.self, cloud.appendingPathComponent("cookies/\(id).json")) else { continue }
            let have = await cookies(of: store)
            let merged = mergeCrumbs(have, remote.body, gone: remote.gone)
            for crumb in merged where !have.contains(where: { $0.id == crumb.id && $0.value == crumb.value }) {
                guard let cookie = HTTPCookie(properties: crumb.properties) else { continue }
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    store.httpCookieStore.setCookie(cookie) { done.resume() }
                }
            }
            var state = State.load(Store.folder)
            state.cookieSeen[id] = remote.updated
            state.save(Store.folder)
        }
    }

    /// Called once a pass has the stores. Pushes the jars WebKit actually holds.
    static func pushCookies(cloud: URL, device: String) async {
        guard let browser = shared.browser, !Store.testing, shared.enabled else { return }
        for (id, store) in jars(browser) {
            let have = await cookies(of: store)
            let remoteURL = cloud.appendingPathComponent("cookies/\(id).json")
            let remote = decode(Marked<[Crumb]>.self, remoteURL)
            let merged = mergeCrumbs(have, remote?.body ?? [], gone: remote?.gone ?? [:])
            publish(merged, gone: remote?.gone ?? [:], stamps: [:], device: device, url: remoteURL)
        }
    }

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

        @MainActor
        static func load(_ folder: URL) -> State {
            decode(State.self, folder.appendingPathComponent("sync-state.json")) ?? State()
        }

        @MainActor
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

    nonisolated static func selfTest() -> Bool {
        MainActor.assumeIsolated { testSync() }
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

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-sync-\(UUID().uuidString)", isDirectory: true)
        let macA = root.appendingPathComponent("a", isDirectory: true)
        let macB = root.appendingPathComponent("b", isDirectory: true)
        let drive = root.appendingPathComponent("cloud", isDirectory: true)
        put(encode([Visit(url: "https://from-a.example/", key: "from-a.example", title: "From A", count: 1, last: later)]), macA.appendingPathComponent("history.json"))
        var stateA = State()
        _ = exchange(local: macA, cloud: drive, device: "mac-a", state: &stateA, browser: nil)
        var stateB = State()
        let arrived = exchange(local: macB, cloud: drive, device: "mac-b", state: &stateB, browser: nil)
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
