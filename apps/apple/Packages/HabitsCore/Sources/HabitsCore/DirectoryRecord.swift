import CryptoKit
import Foundation

/// An answer from the OpenHabits directory, checked against the server's
/// own key.
///
/// The server signs every update it sends the directory, and the directory
/// passes that signed update on unchanged. This device learned the server's
/// key when it signed in, so it can tell an address the server published
/// from one the directory (or anyone in between) made up. Matches
/// apps/client/lib/data/directory_record.dart.
public struct DirectoryRecord: Sendable {
    public let urls: [String]
    /// When the server signed it, in milliseconds.
    public let ts: Int

    /// The record in `response`, or nil unless it was signed with `key`
    /// (base64url, an uncompressed P-256 point), is for `id`, and is no
    /// older than `notBefore`.
    public static func verify(_ response: [String: JSONValue], key: String, id: String, notBefore: Int = 0)
        -> DirectoryRecord?
    {
        guard let payload = response["payload"]?.string, let sig = response["sig"]?.string,
            let keyData = base64Url(key), let sigData = base64Url(sig),
            let publicKey = try? P256.Signing.PublicKey(x963Representation: keyData),
            let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sigData),
            publicKey.isValidSignature(signature, for: Data(payload.utf8)),
            let update = try? JSONDecoder().decode([String: JSONValue].self, from: Data(payload.utf8)),
            update["id"]?.string == id,
            let ts = update["ts"]?.int, ts >= notBefore,
            let urls = update["urls"]?.array
        else { return nil }
        return DirectoryRecord(urls: urls.compactMap(\.string).filter { $0.hasPrefix("https://") }, ts: ts)
    }

    static func base64Url(_ text: String) -> Data? {
        var b64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        return Data(base64Encoded: b64)
    }
}
