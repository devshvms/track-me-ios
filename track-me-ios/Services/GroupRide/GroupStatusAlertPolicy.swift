import Foundation

nonisolated enum GroupStatusAlertPolicy {
    struct Transition: Equatable {
        let uid: String
        let status: RiderStatus
    }

    struct Decision: Equatable {
        let alerts: [Transition]
        let resolutions: [Transition]
        let ledger: [String: String]
    }

    static func evaluate(
        previous: [GroupWire.MemberStatus],
        current: [GroupWire.MemberStatus],
        freshUIDs: Set<String>,
        shownLedger: [String: String],
        elapsedSinceJoinMillis: Int64,
        alertsMuted: Bool
    ) -> Decision {
        let previousByUID = Dictionary(uniqueKeysWithValues: previous.map { ($0.uid, $0) })
        let currentByUID = Dictionary(uniqueKeysWithValues: current.map { ($0.uid, $0) })
        var nextLedger = shownLedger
        var alerts: [Transition] = []
        var resolutions: [Transition] = []

        for memberStatus in current where memberStatus.status.isAlert {
            guard previousByUID[memberStatus.uid]?.status.raw != memberStatus.status.raw,
                  !alertsMuted,
                  elapsedSinceJoinMillis >= 60_000,
                  freshUIDs.contains(memberStatus.uid) else { continue }
            alerts.append(.init(uid: memberStatus.uid, status: memberStatus.status))
            nextLedger[memberStatus.uid] = memberStatus.status.raw
        }

        for (uid, alertedRaw) in Array(nextLedger) {
            guard let alertedStatus = RiderStatusCodec.parse(alertedRaw), alertedStatus.isAlert else {
                nextLedger.removeValue(forKey: uid)
                continue
            }
            let next = currentByUID[uid]?.status
            guard next == nil || !next!.isAlert else { continue }
            if !alertsMuted {
                resolutions.append(.init(uid: uid, status: alertedStatus))
            }
            nextLedger.removeValue(forKey: uid)
        }

        return Decision(
            alerts: alerts,
            resolutions: resolutions,
            ledger: nextLedger
        )
    }
}
