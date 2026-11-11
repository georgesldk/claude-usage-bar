import Foundation
import Security
import CommonCrypto
import SQLite3

/// Copies the claude.ai login cookies from the Claude desktop app (Electron).
/// Electron encrypts cookie values with a key stored in the Keychain as "Claude Safe Storage".
enum ClaudeAppCookies {
    static func cookies() -> [HTTPCookie] {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude")
        let candidates = ["Cookies", "Network/Cookies", "Default/Cookies", "Default/Network/Cookies"]
            .map { base.appendingPathComponent($0) }
        for db in candidates where fm.fileExists(atPath: db.path) {
            let found = read(db)
            if !found.isEmpty { return found }
        }
        return []
    }

    private static func read(_ url: URL) -> [HTTPCookie] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("cub-\(UUID().uuidString).db")
        defer { for s in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: tmp.path + s) } }
        do {
            try fm.copyItem(at: url, to: tmp)
            if fm.fileExists(atPath: url.path + "-wal") {
                try fm.copyItem(atPath: url.path + "-wal", toPath: tmp.path + "-wal")
            }
        } catch { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        // Chromium DB version >= 24 prefixes decrypted values with a 32-byte domain hash.
        var version = 0
        var vstmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='version'", -1, &vstmt, nil) == SQLITE_OK,
           sqlite3_step(vstmt) == SQLITE_ROW, let c = sqlite3_column_text(vstmt, 0) {
            version = Int(String(cString: c)) ?? 0
        }
        sqlite3_finalize(vstmt)

        var stmt: OpaquePointer?
        let sql = """
        SELECT host_key, name, value, encrypted_value, path, is_secure, expires_utc
        FROM cookies WHERE host_key LIKE '%claude.ai'
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var aesKey: [UInt8]?
        var keyTried = false
        var result: [HTTPCookie] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let host = text(stmt, 0)
            let name = text(stmt, 1)
            // Cloudflare cookies are tied to the Claude app's browser; don't copy them.
            if name.hasPrefix("__cf") || name.hasPrefix("cf_") { continue }
            var value = text(stmt, 2)
            if value.isEmpty {
                let n = Int(sqlite3_column_bytes(stmt, 3))
                guard n > 0, let p = sqlite3_column_blob(stmt, 3) else { continue }
                if !keyTried { keyTried = true; aesKey = deriveKey() }
                guard let k = aesKey,
                      let v = decrypt(Data(bytes: p, count: n), key: k, stripHash: version >= 24) else { continue }
                value = v
            }
            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: host, .path: text(stmt, 4).isEmpty ? "/" : text(stmt, 4),
                .name: name, .value: value
            ]
            if sqlite3_column_int(stmt, 5) != 0 { props[.secure] = "TRUE" }
            let chromeTime = sqlite3_column_int64(stmt, 6)
            if chromeTime > 0 {
                props[.expires] = Date(timeIntervalSince1970: Double(chromeTime) / 1_000_000 - 11_644_473_600)
            }
            if let c = HTTPCookie(properties: props) { result.append(c) }
        }
        return result
    }

    private static func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }

    private static func deriveKey() -> [UInt8]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let password = String(data: data, encoding: .utf8) else { return nil }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let r = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                     1003, &key, key.count)
        return r == kCCSuccess ? key : nil
    }

    private static func decrypt(_ enc: Data, key: [UInt8], stripHash: Bool) -> String? {
        guard enc.count > 3, enc.prefix(3) == Data("v10".utf8) else { return nil }
        let input = [UInt8](enc.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, input, input.count, &out, out.count, &outLen)
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        var bytes = Array(out.prefix(outLen))
        if stripHash && bytes.count >= 32 { bytes.removeFirst(32) }
        return String(bytes: bytes, encoding: .utf8)
    }
}
