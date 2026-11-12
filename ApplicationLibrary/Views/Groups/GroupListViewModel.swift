import Libbox
import Library
import SwiftUI

@MainActor
public class GroupListViewModel: BaseViewModel {
    @Published public var groups: [OutboundGroup] = []
    @Published public var testingGroups: Set<String> = []
    /// The members whose latency is being measured right now.
    ///
    /// A group test measures every member, so the members carry the state as well as the group:
    /// without it a sweep over a hundred and thirty-seven nodes shows one spinner on the header and
    /// nothing on the rows it is actually working through. `HakoGroupListView` reads this to put the
    /// spinner on the row, which is why the set exists here rather than in the page.
    @Published public var testingItems: Set<String> = []

    private var pendingExpands: [String: Bool] = [:]
    /// The latest selection attempt per group.
    ///
    /// A group tag could not tell two attempts apart: `pendingSelections[groupTag]` was overwritten
    /// by the next tap and then settled whichever answer arrived last. The kernel now echoes the
    /// request id and the group revision of every selection, so the ledger can decide - for each
    /// answer - whether it still owns the row.
    private var selectionLedger = SelectionLedger()
    /// The in-flight task per group, so a newer tap cancels the older one instead of racing it.
    private var selectionTasks: [String: Task<Void, Never>] = [:]

    override public init() {
        super.init()
        isLoading = true
    }

    public func connect() {
        if Variant.screenshotMode {
            // The fixture's groups, from the one place that defines them. They used to be written
            // out here, and only here - so this sheet had two groups while Home, reading
            // `CommandClient.groups`, had none, and the two views disagreed about one number under
            // the very fixture that exists to make them comparable.
            groups = ScreenshotFixtureGroups.make()
            isLoading = false
        }
    }

    public func setGroups(_ newGroups: [OutboundGroup]?) {
        guard var newGroups else { return }
        for index in newGroups.indices {
            let tag = newGroups[index].tag
            if let pending = selectionLedger.pendingSelection(for: tag) {
                if newGroups[index].selected == pending.outboundTag {
                    _ = selectionLedger.confirmFromStream(groupTag: tag, selectedTag: pending.outboundTag)
                } else {
                    // The read-back has not arrived yet. Keep the user's choice on screen, but
                    // only while an attempt is actually in flight: a failure clears the ledger
                    // entry, so a failed selection cannot pin this row forever.
                    newGroups[index].selected = pending.outboundTag
                }
            }
            if let pendingExpand = pendingExpands[tag] {
                if newGroups[index].isExpand == pendingExpand {
                    pendingExpands.removeValue(forKey: tag)
                } else {
                    newGroups[index].isExpand = pendingExpand
                }
            }
        }
        if newGroups != groups {
            groups = newGroups
        }
        isLoading = false
    }

    public func selectOutbound(groupTag: String, outboundTag: String) {
        if let index = groups.firstIndex(where: { $0.tag == groupTag }) {
            groups[index].selected = outboundTag
        }
        let request = selectionLedger.begin(groupTag: groupTag, outboundTag: outboundTag)
        // The newest attempt owns the row. Cancelling the older task is not what makes that true -
        // the ledger's request id is - but it stops an abandoned call from being driven further.
        selectionTasks[groupTag]?.cancel()
        selectionTasks[groupTag] = Task { [weak self] in
            await self?.doSelectOutbound(request)
        }
    }

    /// Sends the selection with its request identity and read-back expectations.
    ///
    /// `expectedRevision` is the last revision this client applied for the group, so the kernel can
    /// say `stale` when the group moved before the request arrived. The answer is applied only if
    /// `selectionLedger` still considers this attempt the latest one.
    private nonisolated func doSelectOutbound(_ request: SelectionRequest) async {
        do {
            let client = try CommandTarget.standaloneClient()
            let box = try client.selectOutboundWithRequest(
                request.groupTag,
                outboundTag: request.outboundTag,
                // The bridge binds the wire's uint64 as a signed 64-bit value; the ledger's
                // counters are small and non-negative, so the conversion cannot lose an identity.
                requestID: Int64(request.requestID),
                expectedRevision: Int64(request.expectedRevision)
            )
            guard let readBack = SelectionReadBack.decode(box.value) else {
                await MainActor.run {
                    settleSelectionFailure(request, message: "the selection answer could not be read")
                }
                return
            }
            await MainActor.run {
                settleSelection(readBack, for: request)
            }
        } catch {
            await MainActor.run {
                settleSelectionFailure(request, message: error.localizedDescription)
            }
        }
    }

    private func settleSelection(_ readBack: SelectionReadBack, for request: SelectionRequest) {
        selectionTasks[request.groupTag] = nil
        switch selectionLedger.settle(readBack, for: request) {
        case let .applied(outboundTag, _, _):
            // The row shows what the group HOLDS, not what was requested: the daemon may have
            // applied a different member (a hard switch, or a group that refused the member).
            if let index = groups.firstIndex(where: { $0.tag == request.groupTag }) {
                groups[index].selected = outboundTag
            }
        case .ignoredOlderRequest, .ignoredOlderRevision:
            // A newer tap already owns this group. Applying this answer is exactly the defect
            // the request identity exists to remove.
            break
        case let .unconfirmed(reason):
            alert = AlertState(action: "select outbound", error: SelectionOrderingFailure(reason))
        case let .failed(reason):
            alert = AlertState(action: "select outbound", error: SelectionOrderingFailure(reason))
        }
    }

    private func settleSelectionFailure(_ request: SelectionRequest, message: String) {
        selectionTasks[request.groupTag] = nil
        switch selectionLedger.fail(request, reason: message) {
        case let .failed(reason):
            alert = AlertState(action: "select outbound", error: SelectionOrderingFailure(reason))
        case .applied, .ignoredOlderRequest, .ignoredOlderRevision, .unconfirmed:
            break
        }
    }

    public func toggleExpand(groupTag: String) {
        guard let index = groups.firstIndex(where: { $0.tag == groupTag }) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            groups[index].isExpand.toggle()
        }
        let isExpand = groups[index].isExpand
        pendingExpands[groupTag] = isExpand
        Task {
            await setGroupExpand(tag: groupTag, isExpand: isExpand)
        }
    }

    private nonisolated func setGroupExpand(tag: String, isExpand: Bool) async {
        do {
            try await CommandTarget.standaloneClient().setGroupExpand(tag, isExpand: isExpand)
        } catch {
            await MainActor.run {
                alert = AlertState(action: "update group expansion", error: error)
            }
        }
    }

    public func performGroupURLTest(_ groupTag: String) {
        testingGroups.insert(groupTag)
        // A group test measures every member, so the members are marked as well: the header alone
        // cannot show which of a hundred and thirty-seven rows is being worked through. The set is
        // captured before the task starts so the same members are cleared even if the group's list
        // changes while the sweep is running.
        let members = groups.first { $0.tag == groupTag }?.items.map(\.tag) ?? []
        testingItems.formUnion(members)
        Task {
            await doURLTest(tag: groupTag)
            testingGroups.remove(groupTag)
            testingItems.subtract(members)
        }
    }

    public func performURLTest(_ tag: String) {
        testingItems.insert(tag)
        Task {
            await doURLTest(tag: tag)
            testingItems.remove(tag)
        }
    }

    private nonisolated func doURLTest(tag: String) async {
        do {
            try await CommandTarget.standaloneClient().urlTest(tag)
        } catch {
            await MainActor.run {
                alert = AlertState(action: "run URL test", error: error)
            }
        }
    }
}
