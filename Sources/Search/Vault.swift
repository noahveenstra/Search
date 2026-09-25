import Foundation
import Security
import LocalAuthentication

// Where passwords live: the macOS keychain, under this app's own name, as
// internet passwords keyed by site and account. Nothing is written to disk by
// this app in any other form, and nothing is ever logged.
//
// This is the same coffer Safari's are in, but not the same drawer: Apple keeps
// Safari's behind an entitlement no other browser gets. So these are Office
// Browser's — in the system's vault, unlocked with the Mac, shown with Touch ID.

struct Login: Identifiable, Equatable, Hashable {
    var host: String
    var user: String
    var password: String
    /// When it was last used to sign in, if known. Newest first in lists.
    var used: Date?
    /// Kept from a page sent in the clear, over plain http. Only these are
    /// offered on such a page: one kept from https, or from before this was
    /// written down, is never handed to a page anyone on the way could have
    /// written.
    var clear = false
    /// When the password itself last changed. Using it to sign in does not
    /// move this. Sync keeps the later one when two Macs disagree.
    var changed = Date.distantPast

    var id: String { host + "\u{1}" + user }
}

enum Vault {
    /// What every item of ours is tagged with. A test run tags its own, so a
    /// password saved while trying something never sits among the real ones.
    private static let label = Store.world.map { "Search by Noah (\($0))" } ?? "Search by Noah"

    // MARK: - reading

    /// The keychain will list many items, or hand over one secret — not
    /// both in one call. Asked for every item's data at once it answers
    /// errSecParam, and it did so quietly enough that for a while this app
    /// saved passwords it could never read back. So: the list first, without
    /// secrets, then each secret on its own.

    /// What is kept for a host, exactly. See `logins(matching:)` for the
    /// version that also looks across a site's subdomains.
    static func logins(for host: String) -> [Login] {
        rows(where: [kSecAttrServer as String: host]).compactMap(login(from:))
    }

    /// The keychain matches a server name exactly, and a sign-in rarely lives
    /// on the page you saved it from — accounts.example.com asks, and the
    /// password was kept for example.com. So the site is matched as a site:
    /// the host first, then anything sharing its registrable domain.
    static func logins(matching host: String) -> [Login] {
        let domain = registrable(host)
        let exact = logins(for: host)
        let wider = rows(where: [:])
            .filter { ($0[kSecAttrServer as String] as? String).map { $0 != host && registrable($0) == domain } ?? false }
            .compactMap(login(from:))
        return (exact + wider).sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }
    }

    /// Everything this app holds, for the list. Read on demand and never kept
    /// in a property.
    static func all() -> [Login] {
        rows(where: [:]).compactMap(login(from:))
            .sorted { $0.host == $1.host ? $0.user < $1.user : $0.host < $1.host }
    }

    /// The items' attributes — no secrets — narrowed by whatever is given.
    /// Items saved before syncing are not synchronizable. Asking for "any"
    /// is what makes a later Mac's iCloud Keychain copies show up here too.
    private static func rows(where extra: [String: Any], legacyOnly: Bool = false) -> [[String: Any]] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if !legacyOnly { query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny }
        extra.forEach { query[$0] = $1 }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else {
            // Nothing kept reads as "not found"; anything else is worth a
            // line in the log, because the panel will only say "nothing".
            if status != errSecItemNotFound { NSLog("Vault: keychain list failed (%d)", status) }
            return []
        }
        return rows
    }

    /// One item's secret, by the two things that name it.
    private static func secret(host: String, user: String) -> String? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { NSLog("Vault: keychain read failed (%d)", status) }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func login(from row: [String: Any]) -> Login? {
        guard let host = row[kSecAttrServer as String] as? String,
              let user = row[kSecAttrAccount as String] as? String,
              let password = secret(host: host, user: user)
        else { return nil }
        // The keychain has no dates of its own. They ride in the comment:
        // a JSON stamp now, or — from before that — the last-used time alone,
        // which is then also the only change date we can give it.
        let stamp = Self.stamp(from: row[kSecAttrComment as String] as? String)
        let clear = (row[kSecAttrProtocol as String] as? String) == (kSecAttrProtocolHTTP as String)
        return Login(
            host: host, user: user, password: password,
            used: stamp.used, clear: clear, changed: stamp.changed
        )
    }

    private struct Stamp: Codable {
        var changed: Date
        var used: Date?
    }

    private static func stamp(from comment: String?) -> Stamp {
        guard let comment, !comment.isEmpty else { return Stamp(changed: .distantPast, used: nil) }
        if comment.hasPrefix("{"),
           let data = comment.data(using: .utf8),
           let stamp = try? JSONDecoder().decode(Stamp.self, from: data) {
            return stamp
        }
        if let number = Double(comment) {
            let date = Date(timeIntervalSince1970: number)
            return Stamp(changed: date, used: date)
        }
        return Stamp(changed: .distantPast, used: nil)
    }

    private static func comment(changed: Date, used: Date?) -> String {
        let data = (try? JSONEncoder().encode(Stamp(changed: changed, used: used))) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - writing

    /// `keepChanged` is for signing in, and for writing a login that already
    /// has a date from another Mac. A person saving or changing a password
    /// leaves it false, and the date becomes now.
    @discardableResult
    static func save(
        host: String, user: String, password: String,
        used: Date? = nil, clear: Bool = false,
        changed: Date? = nil, keepChanged: Bool = false, quiet: Bool = false
    ) -> Bool {
        guard !host.isEmpty, !password.isEmpty,
              let data = password.data(using: .utf8)
        else { return false }
        let when = keepChanged ? (changed ?? .distantPast) : Date()

        // Ours only. Server and account alone also match what other apps
        // keep for the same site — git's token for github.com under your
        // username — and an update would write this password over it.
        let identity: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrLabel as String: label,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        // A web form's, which also keeps ours apart from another app's item
        // in the keychain's eyes: one for the same server, account and
        // protocol — git's — makes adding ours fail as a duplicate.
        var fields: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: label,
            kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeHTMLForm,
            kSecAttrProtocol as String: clear ? kSecAttrProtocolHTTP : kSecAttrProtocolHTTPS,
        ]
        fields[kSecAttrComment as String] = comment(changed: when, used: used)

        let status = SecItemUpdate(identity as CFDictionary, fields as CFDictionary)
        if status == errSecSuccess {
            if !quiet { CloudSync.shared.notice() }
            return true
        }
        guard status == errSecItemNotFound else { return false }

        var fresh = identity.merging(fields) { _, new in new }
        fresh[kSecAttrSynchronizable as String] = kCFBooleanTrue
        fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = SecItemAdd(fresh as CFDictionary, nil) == errSecSuccess
        if added, !quiet { CloudSync.shared.notice() }
        return added
    }

    /// It was just used to sign in. Lists put it first from now on. The
    /// password did not change, so neither does the date sync compares.
    static func touch(_ login: Login) {
        save(
            host: login.host, user: login.user, password: login.password,
            used: Date(), clear: login.clear, changed: login.changed, keepChanged: true
        )
    }

    static func forget(host: String, user: String, quiet: Bool = false) {
        let status = SecItemDelete([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrLabel as String: label,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ] as CFDictionary)
        if status == errSecSuccess, !quiet { CloudSync.shared.notice() }
    }

    /// Copies passwords saved before syncing into iCloud Keychain, so the
    /// other Macs on this account can read them. The old item, which could
    /// never leave this Mac, is removed once the copy is in.
    static func shareAcrossDevices() {
        guard !Store.testing else { return }
        for login in rows(where: [:], legacyOnly: true).compactMap(login(from:)) {
            SecItemDelete([
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: login.host,
                kSecAttrAccount as String: login.user,
                kSecAttrLabel as String: label,
            ] as CFDictionary)
            _ = save(
                host: login.host, user: login.user, password: login.password,
                used: login.used, clear: login.clear, changed: login.changed,
                keepChanged: true, quiet: true
            )
        }
    }

    // MARK: - sites that asked not to be asked

    static let neverKey = "passwords.never"

    static var never: Set<String> {
        get { Set(Store.settings.stringArray(forKey: neverKey) ?? []) }
        set {
            Store.settings.set(Array(newValue).sorted(), forKey: neverKey)
            if !Store.testing { CloudSync.shared.notice() }
        }
    }

    static func never(_ host: String) { never.insert(host) }
    static func isNever(_ host: String) -> Bool { never.contains(host) || never.contains(registrable(host)) }

    // MARK: - showing one

    /// A password is shown only to the person the Mac belongs to. Touch ID,
    /// the watch, or the account password — whatever the Mac itself takes.
    static func prove(_ reason: String, _ done: @escaping (Bool) -> Void) {
        let context = LAContext()
        var trouble: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &trouble) else {
            // No way to ask at all — a Mac with no password set. Then there is
            // nothing to prove.
            done(true)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    // MARK: - the site behind a host

    /// example.com for www.example.com and accounts.example.com; bbc.co.uk
    /// stays bbc.co.uk.
    static func registrable(_ host: String) -> String {
        Registrable.domain(of: host, isSuffix: Passkeys.publicSuffix.map { test in { test($0 as CFString) } })
    }

    static func host(of text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if !value.contains("://") { value = "https://" + value }
        guard let host = URL(string: value)?.host()?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - taking in an export

    /// A CSV as Google Password Manager, Chrome or Dia write it: name, url,
    /// username, password, note. Read once, put in the keychain, and the file
    /// is yours to delete — this never keeps a copy of it.
    static func take(csv text: String) -> (kept: Int, skipped: Int) {
        var rows = parse(csv: text)
        guard !rows.isEmpty else { return (0, 0) }

        let header = rows.removeFirst().map { $0.lowercased() }
        func column(_ names: [String]) -> Int? {
            header.firstIndex { names.contains($0) }
        }
        guard let urlAt = column(["url", "login_uri", "website", "site"]),
              let userAt = column(["username", "login_username", "user", "email"]),
              let passAt = column(["password", "login_password"])
        else { return (0, rows.count) }

        var kept = 0, skipped = 0
        for row in rows {
            guard row.count > max(urlAt, max(userAt, passAt)) else {
                skipped += 1
                continue
            }
            let host = self.host(of: row[urlAt])
            let password = row[passAt]
            guard !host.isEmpty, !password.isEmpty else {
                skipped += 1
                continue
            }
            let clear = row[urlAt].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
            save(host: host, user: row[userAt], password: password, clear: clear) ? (kept += 1) : (skipped += 1)
        }
        return (kept, skipped)
    }

    /// Quoted fields, doubled quotes inside them, and newlines inside those —
    /// all three turn up in a real export.
    private static func parse(csv text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex

        while index < text.endIndex {
            let c = text[index]
            if quoted {
                if c == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r":
                    row.append(field)
                    field = ""
                    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            index = text.index(after: index)
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}
