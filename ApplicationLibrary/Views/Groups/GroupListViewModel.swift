import Libbox
import Library
import SwiftUI

@MainActor
public class GroupListViewModel: BaseViewModel {
    @Published public var groups: [OutboundGroup] = []
    @Published public var testingGroups: Set<String> = []
    /// The members whose latency is being measured right now.
    ///
    /// A group test measures every member, so the members carry the state as well as the
    /// group: without it a sweep over a hundred and thirty-seven nodes shows one spinner on
    /// the header and nothing on the rows it is actually working through.
    @Published public var testingItems: Set<String> = []

    private var pendingSelections: [String: String] = [:]
    private var pendingExpands: [String: Bool] = [:]

    override public init() {
        super.init()
        isLoading = true
    }

    public func connect() {
        if Variant.screenshotMode {
            // The type strings are the core's canonical lower-case names. The fixture used
            // capitalized ones, which the display-type mapping does not recognise, so every
            // member in every snapshot read "Unknown" - a fixture that made the pages it
            // exists to photograph look wrong.
            let selectorItems: [OutboundGroupItem] = [
                OutboundGroupItem(tag: "server", type: "shadowsocks", urlTestTime: .now, urlTestDelay: 10),
                OutboundGroupItem(tag: "server2", type: "wireguard", urlTestTime: .now, urlTestDelay: 20),
                OutboundGroupItem(tag: "auto", type: "urltest", urlTestTime: .now, urlTestDelay: 30),
            ]
            let urlTestItems: [OutboundGroupItem] = (0 ..< 137).map { index in
                let tag = index == 0 ? "Tokyo" : "node-\(index)"
                let delay = UInt16(100 + index * 13)
                return OutboundGroupItem(tag: tag, type: "shadowsocks", urlTestTime: .now, urlTestDelay: delay)
            }
            groups = [
                OutboundGroup(tag: "my_group", type: "selector", selected: "server", selectable: true, isExpand: true, items: selectorItems),
                OutboundGroup(tag: "Auto", type: "urltest", selected: "Tokyo", selectable: true, isExpand: false, items: urlTestItems),
            ]
            isLoading = false
        }
    }

    public func setGroups(_ newGroups: [OutboundGroup]?) {
        guard var newGroups else { return }
        for index in newGroups.indices {
            let tag = newGroups[index].tag
            if let pendingSelected = pendingSelections[tag] {
                if newGroups[index].selected == pendingSelected {
                    pendingSelections.removeValue(forKey: tag)
                } else {
                    newGroups[index].selected = pendingSelected
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
        pendingSelections[groupTag] = outboundTag

        Task {
            await doSelectOutbound(groupTag: groupTag, outboundTag: outboundTag)
        }
    }

    private nonisolated func doSelectOutbound(groupTag: String, outboundTag: String) async {
        do {
            try await CommandTarget.standaloneClient().selectOutbound(groupTag, outboundTag: outboundTag)
        } catch {
            await MainActor.run {
                alert = AlertState(action: "select outbound", error: error)
            }
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
