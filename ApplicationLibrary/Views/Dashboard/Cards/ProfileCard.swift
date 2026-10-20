import Foundation
import Libbox
import Library
import QRCode
import SwiftUI
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

@MainActor
public struct ProfileCard: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @StateObject private var viewModel = ViewModel()

    @Binding private var profileList: [ProfilePreview]
    @Binding private var selectedProfileID: Int64

    public init(
        profileList: Binding<[ProfilePreview]>,
        selectedProfileID: Binding<Int64>
    ) {
        _profileList = profileList
        _selectedProfileID = selectedProfileID
    }

    private var selectedProfile: ProfilePreview? {
        profileList.first { $0.id == selectedProfileID }
    }

    public var body: some View {
        DashboardCardView(title: "") {
            VStack(alignment: .leading, spacing: 16) {
                headerView
                profileSelectorView
            }
        }
        .disabled(viewModel.isUpdating)
        #if os(tvOS)
            .navigationDestination(isPresented: $viewModel.showNewProfile) {
                NewProfileMenuView(onComplete: {
                    viewModel.showNewProfile = false
                })
                .environmentObject(environments)
                .onDisappear {
                    environments.profileUpdate.send()
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        BackButton()
                    }
                }
            }
            .navigationDestination(isPresented: $viewModel.showProfilePicker) {
                ProfilePickerSheet(
                    profileList: $profileList,
                    selectedProfileID: $selectedProfileID
                )
                .environmentObject(environments)
                .navigationTitle("Profiles")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        BackButton()
                    }
                }
            }
            .navigationDestination(item: $viewModel.profileToEdit) { profile in
                EditProfileView()
                    .environmentObject(profile)
                    .environmentObject(environments)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarLeading) {
                            BackButton()
                        }
                    }
            }
            .sheet(isPresented: $viewModel.showQRCode) {
                if let profile = selectedProfile, let remoteURL = profile.remoteURL {
                    QRCodeSheet(profileName: profile.name, remoteURL: remoteURL)
                }
            }
            .sheet(
                isPresented: $viewModel.showQRSShare,
                onDismiss: {
                    viewModel.qrsShareData = nil
                    viewModel.qrsShareProfileName = nil
                },
                content: {
                    if let data = viewModel.qrsShareData, let name = viewModel.qrsShareProfileName {
                        QRSSheet(profileName: name, profileData: data)
                    } else {
                        ProgressView()
                    }
                }
            )
        #else
            .sheet(isPresented: $viewModel.showNewProfile, onDismiss: {
                environments.profileUpdate.send()
            }, content: {
                NewProfileNavigationView()
                    .environmentObject(environments)
            })
            .sheet(isPresented: $viewModel.showProfilePicker) {
                profilePickerSheet
            }
            .sheet(item: $viewModel.profileToEdit) { profile in
                editProfileSheet(for: profile)
            }
            #if os(iOS)
            .sheet(isPresented: $viewModel.showQRCode) {
                if let profile = selectedProfile, let remoteURL = profile.remoteURL {
                    QRCodeSheet(profileName: profile.name, remoteURL: remoteURL)
                }
            }
            #endif
            .sheet(
                isPresented: $viewModel.showQRSShare,
                onDismiss: {
                    viewModel.qrsShareData = nil
                    viewModel.qrsShareProfileName = nil
                },
                content: {
                    if let data = viewModel.qrsShareData, let name = viewModel.qrsShareProfileName {
                        QRSSheet(profileName: name, profileData: data)
                    } else {
                        ProgressView()
                    }
                }
            )
            .fileExporter(
                isPresented: $viewModel.showExporter,
                document: viewModel.exportDocument,
                contentType: viewModel.exportDocument?.contentType ?? .data,
                defaultFilename: viewModel.exportDocument?.filename
            ) { result in
                viewModel.exportDocument = nil
                if case let .failure(error) = result {
                    viewModel.alert = AlertState(action: "export profile", error: error)
                }
            }
        #endif
            .alert($viewModel.alert)
    }

    private var headerView: some View {
        HStack {
            DashboardCardHeader(icon: "doc.text.fill", title: "Profile")

            Spacer()

            Button {
                viewModel.showNewProfile = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16))
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            #if !os(tvOS)
            .buttonStyle(.plain)
            #endif
            .actionButtonStyle()
        }
    }

    private var profileSelectorView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if profileList.isEmpty {
                Text("Empty profiles")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ProfileSelectorButton(
                    selectedItem: selectedProfile,
                    isPickerPresented: $viewModel.showProfilePicker
                )

                if let profile = selectedProfile {
                    VStack(alignment: .leading, spacing: 12) {
                        profileInfo(for: profile)
                        #if os(macOS)
                        macOSSubscriptionQuotaInfo(for: profile)
                        #endif
                        actionButtonsRow(for: profile)
                    }
                }
            }
        }
    }

    private var actionButtonSpacing: CGFloat {
        #if os(tvOS)
            24
        #else
            12
        #endif
    }

    private func actionButtonsRow(for profile: ProfilePreview) -> some View {
        HStack(spacing: actionButtonSpacing) {
            editButton(for: profile)

            if profile.type == .remote {
                updateButton(for: profile)
            }

            shareMenu(for: profile)
        }
    }

    private func editButton(for profile: ProfilePreview) -> some View {
        Button {
            viewModel.profileToEdit = profile.origin
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 16))
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        #endif
        .actionButtonStyle()
    }

    private func updateButton(for profile: ProfilePreview) -> some View {
        Button {
            viewModel.isUpdating = true
            Task {
                await viewModel.updateProfile(profile.origin, environments: environments)
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 16))
                .rotationEffect(.degrees(viewModel.isUpdating ? 360 : 0))
                .animation(
                    viewModel.isUpdating
                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                        : .default,
                    value: viewModel.isUpdating
                )
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        #endif
        .actionButtonStyle()
        .disabled(viewModel.isUpdating)
    }

    @ViewBuilder
    private func shareMenu(for profile: ProfilePreview) -> some View {
        #if os(tvOS)
            Menu {
                if profile.type == .remote {
                    Button {
                        viewModel.showQRCode = true
                    } label: {
                        Label("Share URL as QR Code", systemImage: "qrcode")
                    }
                }

                Button {
                    prepareQRSShare(profile)
                } label: {
                    Label("Share as QRS Code", systemImage: "qrcode")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16))
            }
            .actionButtonStyle()
        #else
            Menu {
                Button {
                    exportProfile(profile, type: .file)
                } label: {
                    Label("Save File", systemImage: "square.and.arrow.down")
                }

                Button {
                    viewModel.shareItemType = .file
                } label: {
                    Label("Share File", systemImage: "doc")
                }

                Button {
                    exportProfile(profile, type: .json)
                } label: {
                    Label("Save Content JSON", systemImage: "square.and.arrow.down")
                }

                Button {
                    viewModel.shareItemType = .json
                } label: {
                    Label("Share Content JSON File", systemImage: "curlybraces")
                }

                if profile.type == .remote {
                    Button {
                        viewModel.showQRCode = true
                    } label: {
                        Label("Share URL as QR Code", systemImage: "qrcode")
                    }
                }

                Button {
                    prepareQRSShare(profile)
                } label: {
                    Label("Share as QRS Code", systemImage: "qrcode")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16))
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .foregroundStyle(.primary)
            .menuStyle(.borderlessButton)
            .actionButtonStyle()
            .onChange(of: viewModel.shareItemType) { shareItemType in
                guard let shareItemType else { return }
                viewModel.shareItemType = nil
                shareProfile(profile, type: shareItemType)
            }
            #if os(macOS)
            .background(ViewAnchor { viewModel.shareButtonView = $0 })
            .popover(isPresented: $viewModel.showQRCode, arrowEdge: .bottom) {
                if let remoteURL = profile.remoteURL {
                    QRCodeContentView(profileName: profile.name, remoteURL: remoteURL)
                }
            }
            #endif
        #endif
    }

    #if !os(tvOS)
        private func shareProfile(_ profile: ProfilePreview, type: ShareItemType) {
            Task {
                do {
                    let url: URL
                    switch type {
                    case .file:
                        url = try await profile.origin.generateShareFileAsync()
                    case .json:
                        url = try await profile.origin.generateJSONShareFileAsync(name: "\(profile.name).json")
                    }
                    #if os(iOS)
                        presentShareSheet(url)
                    #elseif os(macOS)
                        let anchorView = viewModel.shareButtonView ?? NSApp.keyWindow?.contentView ?? NSView()
                        NSSharingServicePicker(items: [url]).show(
                            relativeTo: .zero,
                            of: anchorView,
                            preferredEdge: .minY
                        )
                    #endif
                } catch {
                    viewModel.alert = AlertState(action: "share profile", error: error)
                }
            }
        }

        private func exportProfile(_ profile: ProfilePreview, type: ExportItemType) {
            Task {
                do {
                    let document: ProfileAnyExportDocument
                    switch type {
                    case .file:
                        let data = try await profile.origin.encodedContentDataAsync()
                        document = ProfileAnyExportDocument(data: data, filename: "\(profile.name).bpf", contentType: .data)
                    case .json:
                        let content = try await profile.origin.readAsync()
                        document = ProfileAnyExportDocument(data: Data(content.utf8), filename: "\(profile.name).json", contentType: .json)
                    }
                    await MainActor.run {
                        viewModel.exportDocument = document
                        viewModel.showExporter = true
                    }
                } catch {
                    await MainActor.run {
                        viewModel.alert = AlertState(action: "export profile", error: error)
                    }
                }
            }
        }

    #endif

    private func prepareQRSShare(_ profile: ProfilePreview) {
        viewModel.qrsShareProfileName = profile.name
        viewModel.qrsShareData = nil
        viewModel.showQRSShare = true
        Task {
            do {
                viewModel.qrsShareData = try await profile.origin.encodedContentDataAsync()
            } catch {
                viewModel.alert = AlertState(action: "prepare QRS share", error: error)
                viewModel.showQRSShare = false
            }
        }
    }

    private func profileInfo(for profile: ProfilePreview) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: profile.type.presentationSymbol)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(profile.type.presentationLabel)
                    .font(.caption)
                    .foregroundColor(.primary)
            }

            if profile.type == .remote, let lastUpdated = profile.lastUpdated {
                HStack(spacing: 4) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(lastUpdated.relativeFormat)
                        .font(.caption)
                        .foregroundColor(.primary)
                }
            }
        }
    }

    // MARK: - macOS subscription quota

    #if os(macOS)
        /// Whether the selected profile carries any quota figure worth a line.
        ///
        /// Presence is decided from the stored value alone, so a profile with no subscription
        /// metadata (or a panel that never sent the header) adds no height to the card at all.
        private func macOSHasSubscriptionQuota(_ profile: ProfilePreview) -> Bool {
            guard profile.type == .remote, let info = profile.subscriptionInfo else { return false }
            return info.total > 0 || info.usedBytes > 0 || info.expire > 0
        }

        /// The selected profile's subscription quota, under the profile metadata.
        ///
        /// Mirrors the Windows client's caption rather than inventing a Mac layout: a short
        /// `remaining / total` (or `used` when the panel reported no quota), and the expiry date,
        /// on one line when it fits and on two when it does not.
        ///
        /// A one-minute timeline re-evaluates only this subtree, because the caption must change
        /// from "expires" to "expired" when the clock passes the date on a card that is left open.
        @ViewBuilder
        private func macOSSubscriptionQuotaInfo(for profile: ProfilePreview) -> some View {
            if macOSHasSubscriptionQuota(profile) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    macOSSubscriptionQuotaLine(for: profile, now: context.date)
                }
            }
        }

        @ViewBuilder
        private func macOSSubscriptionQuotaLine(for profile: ProfilePreview, now: Date) -> some View {
            if let info = profile.subscriptionInfo {
                macOSSubscriptionQuotaLine(info, profile: profile, now: now)
            }
        }

        /// One line when the caption fits, two when it does not - the same wrapping rule the
        /// Windows flex container gives, without clipping a number to keep a line short.
        private func macOSSubscriptionQuotaLine(_ info: SubscriptionInfo, profile: ProfilePreview, now: Date) -> some View {
            let usage = macOSSubscriptionUsageText(info, profile: profile)
            let expiry = macOSSubscriptionExpiryText(info, now: now)
            return ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    macOSSubscriptionUsageView(usage)
                    macOSSubscriptionExpiryView(expiry)
                }
                VStack(alignment: .leading, spacing: 4) {
                    macOSSubscriptionUsageView(usage)
                    macOSSubscriptionExpiryView(expiry)
                }
            }
        }

        @ViewBuilder
        private func macOSSubscriptionUsageView(_ text: String?) -> some View {
            if let text {
                Text(verbatim: text)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
        }

        @ViewBuilder
        private func macOSSubscriptionExpiryView(_ text: (value: String, expired: Bool)?) -> some View {
            if let text {
                Text(verbatim: text.value)
                    .font(.caption)
                    .foregroundStyle(text.expired ? Color.red : Color.secondary)
            }
        }

        /// The usage half of the caption.
        ///
        /// `remainingBytes` is only non-nil when the panel reported a positive total, and it is
        /// already clamped at zero for an over-quota account, so no second subtraction lives here.
        ///
        /// With no total, `used > 0` is the only figure that can be stated: the stored model
        /// defaults a MISSING upload/download to zero, so `used == 0` cannot be told apart from
        /// "the panel said nothing" and must not be rendered as "used 0".
        private func macOSSubscriptionUsageText(_ info: SubscriptionInfo, profile: ProfilePreview) -> String? {
            if let remaining = info.remainingBytes {
                var text = String(format: String(localized: "Remaining %@ / %@"),
                                  macOSSubscriptionBytes(remaining),
                                  macOSSubscriptionBytes(info.total))
                // The quota's OWN capture time, when it is not the configuration refresh time shown
                // above. Without it the "2 hours ago" beside the type would read as the quota's
                // age, which is the misreading the Hako row already avoids the same way.
                if let capturedAt = profile.subscriptionInfoUpdatedAt,
                   let lastUpdated = profile.lastUpdated,
                   abs(lastUpdated.timeIntervalSince(capturedAt)) >= 1
                {
                    text += " \u{00B7} " + capturedAt.relativeFormat
                }
                return text
            }
            guard info.usedBytes > 0 else { return nil }
            return String(format: String(localized: "Used %@"),
                          macOSSubscriptionBytes(info.usedBytes))
        }

        /// The expiry half of the caption, or nil when the panel reported no expiry.
        ///
        /// `expire` is a Unix timestamp in seconds and zero means "not reported"; it must never be
        /// turned into a 1970 date.
        private func macOSSubscriptionExpiryText(_ info: SubscriptionInfo, now: Date) -> (value: String, expired: Bool)? {
            guard info.expire > 0 else { return nil }
            let expiration = Date(timeIntervalSince1970: TimeInterval(info.expire))
            let date = expiration.formatted(date: .numeric, time: .omitted)
            if now >= expiration {
                return (String(format: String(localized: "Expired on %@"), date), true)
            }
            return (String(format: String(localized: "Expires on %@"), date), false)
        }

        /// A byte count in the units the panels report against.
        ///
        /// `ByteCountFormatter` with the file style is decimal (1000-based), which is what the
        /// Windows caption and the panels use; zero is spelled "0 B" rather than the formatter's
        /// word for nothing.
        private func macOSSubscriptionBytes(_ bytes: Int64) -> String {
            let bytes = Swift.max(0, bytes)
            guard bytes > 0 else { return "0 B" }
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    #endif
    #if !os(tvOS)
        private var profilePickerSheet: some View {
            NavigationSheet(
                title: String(localized: "Profiles"),
                size: .large,
                content: {
                    ProfilePickerSheet(
                        profileList: $profileList,
                        selectedProfileID: $selectedProfileID
                    )
                    .environmentObject(environments)
                }
            )
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 300)
            #endif
            .modifier(OpaqueSheetBackground())
        }

        @ViewBuilder
        private func editProfileSheet(for profile: Profile) -> some View {
            #if os(macOS)
                NavigationSheet {
                    EditProfileView()
                        .environmentObject(profile)
                        .environmentObject(environments)
                }
                .frame(minWidth: 500, minHeight: 400)
            #else
                NavigationSheet(title: "Edit Profile") {
                    EditProfileView()
                        .environmentObject(profile)
                        .environmentObject(environments)
                }
            #endif
        }
    #endif
}

// MARK: - ViewModel

extension ProfileCard {
    enum ShareItemType {
        case file
        case json
    }

    enum ExportItemType {
        case file
        case json
    }

    @MainActor
    class ViewModel: ObservableObject {
        @Published var showNewProfile = false
        @Published var showProfilePicker = false
        @Published var showQRCode = false
        @Published var showQRSShare = false
        @Published var qrsShareData: Data?
        @Published var qrsShareProfileName: String?
        @Published var isUpdating = false
        @Published var alert: AlertState?
        @Published var profileToEdit: Profile?
        @Published var shareItemType: ShareItemType?
        #if !os(tvOS)
            @Published var exportDocument: ProfileAnyExportDocument?
            @Published var showExporter = false
        #endif
        #if os(macOS)
            var shareButtonView: NSView?
        #endif

        func updateProfile(_ profile: Profile, environments: ExtensionEnvironments) async {
            defer { isUpdating = false }

            do {
                try await profile.updateRemoteProfile()
                environments.profileUpdate.send()
            } catch {
                alert = AlertState(action: "update remote profile", error: error)
            }
        }
    }
}

// MARK: - NewProfileNavigationView

extension ProfileCard {
    @MainActor
    struct NewProfileNavigationView: View {
        @EnvironmentObject private var environments: ExtensionEnvironments

        var body: some View {
            #if os(macOS)
                NavigationSheet {
                    NewProfileMenuView()
                        .environmentObject(environments)
                }
            #else
                NavigationStackCompat {
                    NewProfileMenuView()
                        .environmentObject(environments)
                }
                .presentationDetentsIfAvailable()
            #endif
        }
    }
}

// MARK: - OpaqueSheetBackground

#if os(iOS)
    private struct OpaqueSheetBackground: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 16.4, *) {
                content.presentationBackground(.regularMaterial)
            } else {
                content
            }
        }
    }

#elseif os(macOS)
    private struct OpaqueSheetBackground: ViewModifier {
        func body(content: Content) -> some View {
            content
        }
    }

    private struct ViewAnchor: NSViewRepresentable {
        let callback: (NSView) -> Void

        func makeNSView(context _: Context) -> NSView {
            let view = NSView()
            DispatchQueue.main.async {
                callback(view)
            }
            return view
        }

        func updateNSView(_: NSView, context _: Context) {}
    }
#else
    private struct OpaqueSheetBackground: ViewModifier {
        func body(content: Content) -> some View {
            content
        }
    }
#endif
