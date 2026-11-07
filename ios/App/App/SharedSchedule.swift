import Foundation

// The schedule the app hands to the Home Screen widget.
// Stored in a keychain group both the app and the widget can read (no App Group setup needed).
// This file is compiled into both the app and the widget.
struct HTWidgetJob: Codable, Hashable {
    var id: String
    var s: Double          // start, ms since 1970
    var e: Double?         // end of the time window, ms
    var n: String          // customer
    var c: String?         // vehicle
    var w: String?         // work
    var a: String?         // address
    var h: Bool?           // booked, estimate not signed yet
    var nt: Bool?          // booked for the day, no time set
    var on: Bool?          // started (in progress)
    var start: Date { Date(timeIntervalSince1970: s / 1000) }
    var end: Date {
        if let e = e { return Date(timeIntervalSince1970: e / 1000) }
        if nt == true { return Calendar.current.startOfDay(for: start).addingTimeInterval(86_399) }
        return start.addingTimeInterval(90 * 60)
    }
}

struct HTWidgetSnapshot: Codable {
    var v: Int = 1
    var at: Double = 0     // when the app wrote it, ms
    var shop: String?
    var accent: String?
    var signedIn: Bool?
    var jobs: [HTWidgetJob] = []
    var wait: Int?         // estimates waiting on the customer
    var req: Int?          // new requests
    var owed: Int?         // unpaid invoices
}

enum HTShared {
    static let service = "com.honestechmobileapp.widget"
    static let account = "schedule"

    static var group: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "HTKeychainGroup") as? String, !g.isEmpty, !g.hasPrefix("$(") else { return nil }
        return g
    }

    private static func base() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let g = group { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    static func write(_ data: Data) -> Bool {
        let q = base()
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        var st = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if st == errSecItemNotFound {
            var add = q
            for (k, v) in attrs { add[k] = v }
            st = SecItemAdd(add as CFDictionary, nil)
        }
        return st == errSecSuccess
    }

    static func read() -> HTWidgetSnapshot? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(HTWidgetSnapshot.self, from: d)
    }

    static func clear() { SecItemDelete(base() as CFDictionary) }
}
