#if os(iOS)
    import Dispatch
    import Foundation
    import Libbox
    import notify

    /// The real Darwin `notify` surface.
    ///
    /// This is the only file that imports `notify`, and therefore the only place the raw status
    /// codes are interpreted. Every call is checked against `NOTIFY_STATUS_OK`:
    ///
    ///   * `notify_register_dispatch` returns `uint32_t` and writes `out_token` only on success, so
    ///     a failed registration yields `.failed` and no token - it cannot be cancelled later as if
    ///     it had registered.
    ///   * `notify_get_state` returns `uint32_t` and writes `state64` only on success, so a failed
    ///     read yields `.failed` with no value at all. The old code ignored the status, left `state`
    ///     at its `0` initialiser, and published `state == 1` as `false` - an unlock, the one fact
    ///     that lifts the device pause.
    ///   * `notify_cancel` returns `uint32_t` too; the result is reported rather than discarded, so
    ///     the caller can tell a token that was released from one that was not.
    ///
    /// `NOTIFY_STATUS_OK` is a `#define`, so Clang imports it as `Int32` while the entry points
    /// return `UInt32`. The conversion is written out at each comparison instead of hiding it behind
    /// a literal `0`.
    final class SystemNotifyAPI: DarwinNotifyAPI {
        func registerDispatch(name: String,
                              queue: DispatchQueue,
                              handler: @escaping (Int32) -> Void) -> NotifyRegistration {
            var token: Int32 = -1
            let status = notify_register_dispatch(name, &token, queue, handler)
            guard status == UInt32(NOTIFY_STATUS_OK) else {
                return .failed(status: status)
            }
            return .registered(token: token)
        }

        func getState(token: Int32) -> NotifyStateRead {
            var value: UInt64 = 0
            let status = notify_get_state(token, &value)
            guard status == UInt32(NOTIFY_STATUS_OK) else {
                return .failed(status: status)
            }
            return .value(value)
        }

        func cancel(token: Int32) -> NotifyOutcome {
            let status = notify_cancel(token)
            guard status == UInt32(NOTIFY_STATUS_OK) else {
                return .failed(status: status)
            }
            return .ok
        }
    }

    /// Publishes the observer's facts into the running core.
    ///
    /// The command server is held weakly on purpose. The observer is torn down before the server is
    /// closed, but "before" is an ordering inside `ExtensionProvider.stopTunnel`, and a weak
    /// reference makes it an invariant of this type instead: a callback that somehow still ran after
    /// the server was gone publishes into nothing rather than into a closed core, and the publisher
    /// cannot keep a closed server alive either.
    final class CommandServerScreenStatePublisher: ScreenStatePublishing {
        private weak var commandServer: LibboxCommandServer?

        init(_ commandServer: LibboxCommandServer) {
            self.commandServer = commandServer
        }

        func recordScreenState(on: Bool) {
            commandServer?.recordScreenState(on)
        }

        func recordLockState(locked: Bool) {
            commandServer?.recordLockState(locked)
        }
    }

    extension ScreenStateObserver {
        /// The observer as `ExtensionProvider` uses it.
        convenience init(commandServer: LibboxCommandServer) {
            self.init(notify: SystemNotifyAPI(),
                      publisher: CommandServerScreenStatePublisher(commandServer))
        }
    }
#endif
