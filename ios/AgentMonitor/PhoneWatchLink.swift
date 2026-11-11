#if os(iOS)
import Foundation
import WatchConnectivity

/// Hands the phone's bridge URL and device token to the paired watch once, over WatchConnectivity.
/// The watch stores its own Keychain copy; nothing else crosses the boundary.
@MainActor final class PhoneWatchLink: NSObject, ObservableObject {
    static let shared = PhoneWatchLink()

    private var context: [String: Any] = [:]
    private var activated = false

    func activate() {
        guard WCSession.isSupported(), !activated else { return }
        activated = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func publish(bridge: String, token: String?) {
        activate()
        context = (token?.isEmpty == false && !bridge.isEmpty)
            ? ["bridge": bridge, "token": token ?? ""]
            : ["bridge": "", "token": ""]
        flush()
    }

    private func flush() {
        guard activated, WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(context)
    }
}

extension PhoneWatchLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            guard activationState == .activated else { return }
            try? session.updateApplicationContext(context)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            self.flush()
            replyHandler(self.context)
        }
    }
}
#endif