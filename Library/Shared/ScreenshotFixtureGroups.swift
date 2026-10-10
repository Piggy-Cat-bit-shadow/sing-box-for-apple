//
//  ScreenshotFixtureGroups.swift
//  Library
//
//  The outbound groups every screenshot fixture shows, in one place.
//
//  # Why this exists
//
//  Two views answer "how many groups are there" and both are on screen at once when the
//  configuration centre is open: Home's `Proxies` row and the proxy sheet's `Groups` summary.
//  They read different things. The sheet builds its own list in `GroupListViewModel.connect()`
//  under `Variant.screenshotMode`; Home reads `CommandClient.groups`, which the fixture never
//  populated. So under the fixture the sheet said two groups and Home said none, and
//  `test17HomeAgreesWithTheProxySheet` - whose stated purpose is that two views must not disagree
//  about one number - read the fixture's invention against the live client's zero.
//
//  The two numbers were never meant to differ. They differed because the fixture was written
//  twice, once per consumer, and only one of them was ever installed. This is the one copy: the
//  sheet seeds its view model from it, and `CommandClient.setupMockData()` publishes it so Home
//  sees the same two groups.
//
//  # What it must not become
//
//  This is fixture data, and it is only reachable under `Variant.screenshotMode` - a production
//  launch installs nothing here. It deliberately describes an ordinary configuration: a selector
//  with a few nodes and a URLTest group with many, which is what the two layouts under test have
//  to survive. It is not a gallery of every row shape the client can draw.
//

import Foundation

public enum ScreenshotFixtureGroups {
    /// The two groups the proxy sheet and Home's `Proxies` row both count.
    public static func make() -> [OutboundGroup] {
        let selectorItems: [OutboundGroupItem] = [
            OutboundGroupItem(tag: "server", type: "Shadowsocks", urlTestTime: .now, urlTestDelay: 10),
            OutboundGroupItem(tag: "server2", type: "WireGuard", urlTestTime: .now, urlTestDelay: 20),
            OutboundGroupItem(tag: "auto", type: "URLTest", urlTestTime: .now, urlTestDelay: 30),
        ]
        let urlTestItems: [OutboundGroupItem] = (0 ..< 137).map { index in
            let tag = index == 0 ? "Tokyo" : "node-\(index)"
            let delay = UInt16(100 + index * 13)
            return OutboundGroupItem(tag: tag, type: "Shadowsocks", urlTestTime: .now, urlTestDelay: delay)
        }
        return [
            OutboundGroup(tag: "my_group", type: "selector", selected: "server", selectable: true, isExpand: true, items: selectorItems),
            OutboundGroup(tag: "Auto", type: "urltest", selected: "Tokyo", selectable: true, isExpand: false, items: urlTestItems),
        ]
    }
}
