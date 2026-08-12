import Foundation
import Security

/// How a binary on disk is signed — which is how TCC decides whether the thing
/// running now is the thing you granted (gh#37).
///
/// A grant is keyed to the code signature. An unsigned binary has no identity
/// beyond its own bytes, so every rebuild is a new program: the Accessibility
/// grant is dropped and a second, indistinguishable row appears in the list. A
/// certificate that outlives the build fixes that, and it does not have to be a
/// paid one — an Apple Development certificate is enough for the machine that
/// issued it.
struct CodeSignature: Equatable {
    /// The signing identifier — `no.bredebjorhovd.papegoye` for the bundle.
    let identifier: String
    /// nil when ad-hoc signed.
    let teamID: String?
    /// Leaf certificate common name, e.g. "Apple Development: you (TEAMID)".
    let authority: String?
    /// When the leaf certificate expires. Nothing signed ad-hoc has one.
    let expiry: Date?

    /// Ad-hoc signatures (`codesign -s -`) carry no certificate, so their only
    /// identity is a hash of the contents — same problem as being unsigned.
    var isAdHoc: Bool { authority == nil }

    /// An identity that survives a rebuild, or nil when there isn't one.
    ///
    /// This is what parrot records instead of a size-and-mtime fingerprint when
    /// the binary is properly signed: a rebuilt signed binary really is the same
    /// program to macOS, so treating it as new would re-prompt for a permission
    /// that was never lost.
    var stableFingerprint: String? {
        guard !isAdHoc else { return nil }
        return "signed:\(identifier):\(teamID ?? authority ?? "")"
    }

    /// Reads the signature of an on-disk binary or bundle. Nil when unsigned —
    /// or when the security framework won't say, which amounts to the same
    /// thing for our purposes.
    static func of(path: String) -> CodeSignature? {
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let info = information as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String
        else { return nil }

        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let leaf = certificates?.first
        return CodeSignature(
            identifier: identifier,
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            authority: leaf.flatMap(commonName(of:)),
            expiry: leaf.flatMap(expiry(of:))
        )
    }

    /// The signature of the running executable, following the symlink that
    /// `parrot` on `PATH` usually is.
    static func current() -> CodeSignature? {
        ExecutablePath.current().flatMap { of(path: $0) }
    }

    private static func commonName(of certificate: SecCertificate) -> String? {
        var name: CFString?
        guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess else { return nil }
        return name as String?
    }

    private static func expiry(of certificate: SecCertificate) -> Date? {
        let key = kSecOIDX509V1ValidityNotAfter as String
        guard let values = SecCertificateCopyValues(certificate, [key] as CFArray, nil)
            as? [String: [String: Any]],
            let seconds = values[key]?[kSecPropertyKeyValue as String] as? Double
        else { return nil }
        // Certificate dates come back as CFAbsoluteTime — seconds since 2001.
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}
