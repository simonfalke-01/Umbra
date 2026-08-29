import Foundation
import Security

public enum AWDLCodeSigning {
    public static func peerRequirement(identifier: String) throws -> String {
        guard let teamIdentifier = try currentTeamIdentifier(), !teamIdentifier.isEmpty else {
            throw AWDLHelperError.unavailable(
                "the current executable has no Team ID; a non-ad-hoc notarized build is required"
            )
        }
        return "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    static func currentTeamIdentifier() throws -> String? {
        var code: SecCode?
        let copySelfStatus = SecCodeCopySelf([], &code)
        guard copySelfStatus == errSecSuccess, let code else {
            throw AWDLHelperError.unavailable("SecCodeCopySelf failed (\(copySelfStatus))")
        }
        var staticCode: SecStaticCode?
        let staticCodeStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticCodeStatus == errSecSuccess, let staticCode else {
            throw AWDLHelperError.unavailable(
                "SecCodeCopyStaticCode failed (\(staticCodeStatus))"
            )
        }
        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(staticCode, [], &information)
        guard informationStatus == errSecSuccess,
              let values = information as? [String: Any] else {
            throw AWDLHelperError.unavailable(
                "SecCodeCopySigningInformation failed (\(informationStatus))"
            )
        }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
