import Foundation
import UmbraProtocolV3

struct ValidatedSecurePairingInvitation: Equatable {
    let uri: String
    let hostname: String
    let expiresAt: Date
}

enum SecurePairingInvitationValidationError: LocalizedError, Equatable {
    case required
    case wrongLink
    case damaged
    case invalidHost
    case notActive
    case expired
    case invalidIdentity

    var errorDescription: String? {
        switch self {
        case .required:
            "Paste a Lumen invitation."
        case .wrongLink:
            "Paste the full Lumen invitation beginning with umbra://pair/v3#."
        case .damaged:
            "This invitation is incomplete or damaged. Generate a new invitation in Lumen."
        case .invalidHost:
            "This invitation does not contain a valid host address. Generate a new invitation in Lumen."
        case .notActive:
            "This invitation is not active yet. Check the clocks on this Mac and the host, then generate a new invitation."
        case .expired:
            "This invitation has expired. Generate a new invitation in Lumen."
        case .invalidIdentity:
            "This invitation could not verify the host identity. Generate a new invitation in Lumen."
        }
    }
}

enum SecurePairingInvitationValidator {
    static func validate(
        _ value: String,
        now: Date = Date()
    ) throws -> ValidatedSecurePairingInvitation {
        let uri = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uri.isEmpty else { throw SecurePairingInvitationValidationError.required }
        guard uri.hasPrefix(ProtocolV3PairingInvitation.uriPrefix) else {
            throw SecurePairingInvitationValidationError.wrongLink
        }

        let invitation: ProtocolV3PairingInvitation
        do {
            invitation = try ProtocolV3PairingInvitation.decode(
                uri: uri,
                nowUnixSeconds: UInt64(max(0, now.timeIntervalSince1970))
            )
        } catch let ProtocolV3WireError.invalidField(field) {
            switch field {
            case "v3 invitation URI":
                throw SecurePairingInvitationValidationError.wrongLink
            case "v3 invitation hostname":
                throw SecurePairingInvitationValidationError.invalidHost
            case "v3 invitation not active":
                throw SecurePairingInvitationValidationError.notActive
            case "v3 invitation expired", "v3 invitation lifetime":
                throw SecurePairingInvitationValidationError.expired
            case "v3 invitation identity":
                throw SecurePairingInvitationValidationError.invalidIdentity
            default:
                throw SecurePairingInvitationValidationError.damaged
            }
        } catch {
            throw SecurePairingInvitationValidationError.damaged
        }

        return ValidatedSecurePairingInvitation(
            uri: uri,
            hostname: invitation.hostname,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(invitation.expiryUnixSeconds))
        )
    }
}
