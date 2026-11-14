import Library
import SwiftUI

struct ConnectionLifecycleObserver: ViewModifier {
    var profile: ExtensionProfile?
    var remoteServerID: Int64?
    var onActive: () -> Void
    var onInactive: () -> Void

    func body(content: Content) -> some View {
        content.background {
            if let profile {
                LocalServiceLifecycleTrigger(profile: profile, remoteServerID: remoteServerID, onActive: onActive, onInactive: onInactive)
            } else {
                RemoteServiceLifecycleTrigger(remoteServerID: remoteServerID, onActive: onActive, onInactive: onInactive)
            }
        }
    }
}

private struct LocalServiceLifecycleTrigger: View {
    @ObservedObject var profile: ExtensionProfile
    var remoteServerID: Int64?
    var onActive: () -> Void
    var onInactive: () -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onAppear {
                if remoteServerID != nil || profile.status.isConnectedStrict {
                    onActive()
                }
            }
            .onChangeCompat(of: remoteServerID) { newValue in
                onInactive()
                if newValue != nil || profile.status.isConnectedStrict {
                    onActive()
                }
            }
            .onChangeCompat(of: profile.status) { status in
                guard remoteServerID == nil else { return }
                if status.isConnectedStrict {
                    onActive()
                } else {
                    onInactive()
                }
            }
            // # Why this is required
            //
            // Without it, leaving the page never released the subscription it opened: the trigger's
            // `onAppear` was the only other call, and it cannot fire for a view that is gone. The
            // tools pages therefore kept a live core status stream - and, for the SSH pages, a live
            // peer list - for the rest of the process's life, one more of each per visit. The
            // subscription itself fences its callbacks, so this is a lifetime fix rather than a
            // correctness one; the leak is real either way.
            //
            // `onInactive` is idempotent by contract (every view model's `cancel()` is a no-op when
            // nothing is subscribed), so a disappear/reappear pair is one cancel and one subscribe.
            .onDisappear {
                onInactive()
            }
    }
}

private struct RemoteServiceLifecycleTrigger: View {
    var remoteServerID: Int64?
    var onActive: () -> Void
    var onInactive: () -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onAppear {
                if remoteServerID != nil {
                    onActive()
                }
            }
            .onChangeCompat(of: remoteServerID) { newValue in
                onInactive()
                if newValue != nil {
                    onActive()
                }
            }
            // Same reason as the local trigger above.
            .onDisappear {
                onInactive()
            }
    }
}
