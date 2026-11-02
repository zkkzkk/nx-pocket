// NX Pocket's signing of game packs on the phone (PackSign.c; the way LiveContainer signs with zsign). A pack built with build_pack.py --unsigned, or signed by another
// developer, has a library iOS would not load here: NX Pocket signs a copy of it with the certificate it holds, the one NX Pocket itself is signed with (library validation
// wants the app's team), and loads that copy. The certificate is a .p12 with its password, imported once (Settings, or a .p12 dropped into Documents) and kept in the Keychain
// (this device only). The signed copy is in Library/Application Support/SignedPacks/<title ID> and is made again when the pack's library or the certificate changes.
import Foundation
import Security
import CryptoKit

enum PackSigner {
    struct Certificate { let name, team: String; let expires: Date }
    enum Failure: LocalizedError {
        case noCertificate, certificate(String), sign(String)
        var errorDescription: String? {
            switch self {
            case .noCertificate: return tr("This pack must be signed on this device. Import a developer certificate in Settings first.")
            case .certificate(let s): return String(format: tr("The certificate cannot be used: %@"), s)
            case .sign(let s): return String(format: tr("Signing the game's library failed: %@"), s)
            }
        }
    }

    private static let service = "nxpocket.signing"
    static var appTeam: String? { AppSigning.team }   // the team that signed NX Pocket, as installed (GameLibrary.swift)

    // ---- the Keychain ----
    private static func keychain(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var r: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess ? r as? Data : nil
    }
    private static func setKeychain(_ account: String, _ data: Data?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let data else { return }
        var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    // Apple's intermediate and root certificates, which complete the chain when the .p12 holds only the developer's own (Certificates/ in the app)
    private static var apple: [Data] {
        (Bundle.main.urls(forResourcesWithExtension: "cer", subdirectory: "Certificates") ?? []).compactMap { try? Data(contentsOf: $0) }
    }

    private struct Identity { let key: SecKey; let chain: [Data]; let cert: Certificate }
    private static func identity(_ p12: Data, _ password: String) throws -> Identity {
        var key: Unmanaged<SecKey>?, chain: Unmanaged<CFArray>?
        var team = [CChar](repeating: 0, count: 32), name = [CChar](repeating: 0, count: 256), err = [CChar](repeating: 0, count: 512)
        var expires: CFAbsoluteTime = 0
        let rc = appTeam.withOptionalCString { want in
            dm_pack_identity(p12 as CFData, password as CFString, want, apple as CFArray, &key, &chain, &team, team.count, &name, name.count, &expires, &err, err.count)
        }
        guard rc == 0, let k = key?.takeRetainedValue(), let c = chain?.takeRetainedValue() as? [Data] else {
            let e = String(cString: err), w = e.split(separator: " ")
            if w.count == 3, w[0] == "TEAM" {   // a developer certificate, but of another team: iOS would not load what it signs into this NX Pocket
                throw Failure.certificate(String(format: tr("the certificate belongs to team %@, but NX Pocket is signed by team %@. Use the certificate NX Pocket is signed with."), String(w[1]), String(w[2])))
            }
            throw Failure.certificate(e)
        }
        return Identity(key: k, chain: c, cert: Certificate(name: String(cString: name), team: String(cString: team), expires: Date(timeIntervalSinceReferenceDate: expires)))
    }

    /// The certificate NX Pocket holds, nil when none
    static var current: Certificate? {
        guard let p = keychain("p12"), let pw = keychain("password").flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        return try? identity(p, pw).cert
    }

    /// Keeps a .p12 and its password once they prove to be a developer certificate of NX Pocket's team
    @discardableResult static func importCertificate(_ p12: Data, password: String) throws -> Certificate {
        let id = try identity(p12, password)
        if id.cert.expires < Date() { throw Failure.certificate(tr("it has expired")) }
        setKeychain("p12", p12); setKeychain("password", Data(password.utf8))
        fputs("pocket: certificate \(id.cert.name) (team \(id.cert.team)), valid until \(id.cert.expires)\n", stderr)
        return id.cert
    }
    static func removeCertificate() { setKeychain("p12", nil); setKeychain("password", nil) }

    /// A certificate built into NX Pocket (build_pocket.py --certificate: EmbeddedCertificate.p12 and its password in the app), for a build signed for a friend's phone: moved
    /// into the Keychain on the first launch, so the friend imports nothing. A certificate already there is kept
    static func adoptEmbeddedCertificate() {
        guard keychain("p12") == nil, let url = Bundle.main.url(forResource: "EmbeddedCertificate", withExtension: "p12"), let p12 = try? Data(contentsOf: url) else { return }
        let pw = (Bundle.main.url(forResource: "EmbeddedCertificate", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do { try importCertificate(p12, password: pw) } catch { fputs("[RED] pocket: the built-in certificate: \(error.localizedDescription)\n", stderr) }
    }

    /// A .p12 dropped into Documents (from a Mac, or the Files app) with its password in a .txt of the same name: imported, then both files are deleted
    static func adoptDroppedCertificate() {
        let docs = GameLibrary.documents, fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension.lowercased() == "p12" {
            let passURL = url.deletingPathExtension().appendingPathExtension("txt")
            guard let p12 = try? Data(contentsOf: url) else { continue }
            let pw = ((try? String(contentsOf: passURL, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            do { try importCertificate(p12, password: pw); try? fm.removeItem(at: url); try? fm.removeItem(at: passURL) }
            catch { fputs("[RED] pocket: \(url.lastPathComponent): \(error.localizedDescription)\n", stderr) }
        }
    }

    // ---- the signed copies ----
    private static func signedFolder(_ titleID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SignedPacks/\(titleID)", isDirectory: true)
    }
    /// What a signed copy was made from: the pack library's size and date, and the certificate's (a new certificate signs it again)
    private static func stamp(_ lib: URL, _ id: Identity) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: lib.path)
        let cert = SHA256.hash(data: id.chain[0]).map { String(format: "%02x", $0) }.joined()
        return "\((a?[.size] as? NSNumber)?.int64Value ?? -1) \((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) \(cert)"
    }

    /// Whether Play needs the pack signed here: its library is not signed by NX Pocket's team (pack.json's team: none for an unsigned pack)
    static func needsSigning(_ pack: GamePack) -> Bool { pack.info.team == nil || pack.info.team != appTeam }

    /// The library Play loads: the pack's own when it is signed by NX Pocket's team, else a copy signed here (made now when there is none for this pack and certificate).
    /// Slow the first time (copy and hash the library): call it off the main thread
    static func library(for pack: GamePack) throws -> URL {
        let own = pack.folder.appendingPathComponent(pack.info.library)   // a single-file pack's unpacked parts (GamePack.folder)
        guard needsSigning(pack) else { return own }
        guard let p = keychain("p12"), let pw = keychain("password").flatMap({ String(data: $0, encoding: .utf8) }) else { throw Failure.noCertificate }
        let id = try identity(p, pw)
        let fwName = (pack.info.library as NSString).pathComponents.first ?? "Game.framework"
        let src = pack.folder.appendingPathComponent(fwName), folder = signedFolder(pack.info.titleID), dst = folder.appendingPathComponent(fwName)
        let stampURL = folder.appendingPathComponent("signed.txt"), want = stamp(own, id)
        let lib = folder.appendingPathComponent(pack.info.library)
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == want, FileManager.default.fileExists(atPath: lib.path) { return lib }
        let t0 = Date()
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true); try fm.copyItem(at: src, to: dst) }
        catch { throw Failure.sign(error.localizedDescription) }
        let t1 = Date()
        var err = [CChar](repeating: 0, count: 512)
        let rc = dst.path.withCString { dm_pack_sign($0, id.key, id.chain as CFArray, id.cert.team, &err, err.count) }
        guard rc == 0 else { try? fm.removeItem(at: folder); throw Failure.sign(String(cString: err)) }
        try? want.write(to: stampURL, atomically: true, encoding: .utf8)
        var r = URLResourceValues(); r.isExcludedFromBackup = true; var f = folder; try? f.setResourceValues(r)
        fputs(String(format: "pocket: signed %@ with %@: copy %.2f s, sign %.2f s\n", pack.info.name, id.cert.name, t1.timeIntervalSince(t0), Date().timeIntervalSince(t1)), stderr)
        return lib
    }

    /// Forgets a pack's signed copy (the pack was removed)
    static func forget(_ titleID: String) { try? FileManager.default.removeItem(at: signedFolder(titleID)) }
}

private extension Optional where Wrapped == String {
    func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self { case .some(let s): return s.withCString { body($0) }; case .none: return body(nil) }
    }
}
