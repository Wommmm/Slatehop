import Foundation

/// Synthetic, process-local state. The demo never instantiates the real adapter.
actor HostAdminDemo: HostAdminBackend {
    enum RecoverySeed {
        case knownWindow, unknownWindow
    }

    private var validFromMS: Int64?
    private var validUntilMS: Int64?
    private var generation = 0
    private var requiresRecovery: Bool

    init(recovery: RecoverySeed? = nil) {
        requiresRecovery = recovery != nil
        if case .knownWindow? = recovery {
            let nowMS = Self.nowMS()
            validFromMS = nowMS - 3_600_000
            validUntilMS = nowMS + 86_400_000
        }
    }

    func status() async throws -> HostAdminStatus {
        snapshot(nowMS: Self.nowMS())
    }

    func setExpiry(_ expiryMS: Int64) async throws -> HostAdminStatus {
        guard !requiresRecovery else { throw DemoError.recoveryRequired }
        let nowMS = Self.nowMS()
        guard let validFromMS, expiryMS > max(validFromMS, nowMS) else {
            throw DemoError.invalidExpiry
        }
        validUntilMS = expiryMS
        return snapshot(nowMS: nowMS)
    }

    func newPassword(_ expiryMS: Int64) async throws -> HostAdminPassword {
        let nowMS = Self.nowMS()
        let start = validFromMS ?? nowMS
        guard expiryMS > max(start, nowMS) else { throw DemoError.invalidExpiry }
        validFromMS = start
        validUntilMS = expiryMS
        requiresRecovery = false
        generation += 1
        return HostAdminPassword(
            status: snapshot(nowMS: nowMS),
            password: "SLATEHOP-DEMO-\(generation)"
        )
    }

    private func snapshot(nowMS: Int64) -> HostAdminStatus {
        let state: String
        if requiresRecovery {
            state = "recovery_required"
        } else if let validFromMS, let validUntilMS {
            if nowMS < validFromMS {
                state = "pending"
            } else {
                state = nowMS < validUntilMS ? "active" : "expired"
            }
        } else {
            state = "unconfigured"
        }
        return HostAdminStatus(
            state: state,
            nowMS: nowMS,
            validFromMS: validFromMS,
            validUntilMS: validUntilMS
        )
    }

    private static func nowMS() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private enum DemoError: Error {
        case invalidExpiry, recoveryRequired
    }
}
