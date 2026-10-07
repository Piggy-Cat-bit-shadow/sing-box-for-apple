import Library
import Libbox
import SwiftUI

#if os(macOS)
    import AppKit
    import ServiceManagement
#endif

public struct AppView: View {
    private struct LanguageOption: Hashable {
        let code: String?
        let name: String
    }

    private static var supportedLanguages: [LanguageOption] {
        var options = [LanguageOption(code: nil, name: String(localized: "System Default"))]
        options.append(contentsOf: configuredLanguageCodes().map { code in
            let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
            return LanguageOption(code: code, name: name)
        })
        return options
    }

    @State private var isLoading = true
    @State private var selectedLanguage: String?

    #if os(macOS)
        @State private var startAtLogin = false
        @Environment(\.showMenuBarExtra) private var showMenuBarExtra
        @Environment(\.menuBarExtraSpeedMode) private var menuBarExtraSpeedMode
        @State private var menuBarExtraInBackground = false
        @State private var systemExtensionInstalled = false
        @State private var helperStatusLoaded = false
        @State private var rootHelperRegistrationStatus: SMAppService.Status = .notRegistered
        @EnvironmentObject private var updateManager: UpdateManager
        @State private var updateTrack: UpdateTrack = .stable
        @State private var githubToken = ""
        @State private var checkUpdateEnabled = false
    #endif

    /// Provided on every platform: the system proxy's off-path restarts the tunnel, and that
    /// needs the profile. It used to be declared inside the desktop-only block, because only the
    /// desktop used it here.
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var alert: AlertState?
    /// The tools page's top-right menu, moved here whole: its home-layout sheet and the remote
    /// control picker. The review's item is that a root page's chrome is not where either belongs.
    @State private var remoteServers: [RemoteServer] = []
    @State private var showCardManagement = false

    public init() {}
    public var body: some View {
        Group {
            if isLoading {
                ProgressView().onAppear {
                    Task {
                        await loadSettings()
                    }
                }
            } else {
                FormView {
                    #if os(tvOS)
                        FormNavigationLink {
                            LanguagePickerView(selection: $selectedLanguage)
                        } label: {
                            HStack {
                                Text("Language")
                                Spacer()
                                Text(selectedLanguageName)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    #else
                        // The three rows the review merged into this one card, in its order.
                        HakoSettingsSection {
                            // The language picker stays the menu it was on this platform, inside the
                            // client's own row: the current language is still the value on the
                            // right, and the choosing still happens in place.
                            HakoRowBody(
                                title: String(localized: "Language"),
                                systemImage: "globe",
                                tint: HakoAccentRole.neutral.color,
                                showsDisclosure: false
                            ) {
                                Picker("Language", selection: $selectedLanguage) {
                                    ForEach(Self.supportedLanguages, id: \.code) { language in
                                        Text(language.name).tag(language.code)
                                    }
                                }
                                .labelsHidden()
                                .onChangeCompat(of: selectedLanguage) { newValue in
                                    updateLanguage(newValue)
                                }
                            }
                            .hakoStandardRowMetric()

                            FormNavigationLink {
                                GhosttyConfigurationView()
                            } label: {
                                HakoNavigationRow(
                                    title: String(localized: "Terminal Appearance"),
                                    subtitle: String(localized: "Colours and font for SSH sessions"),
                                    systemImage: "terminal.fill",
                                    tint: HakoAccentRole.neutral.color
                                )
                            }
                            .hakoStandardRowMetric()

                            FormButton {
                                showCardManagement = true
                            } label: {
                                HakoNavigationRow(
                                    title: String(localized: "Home Cards"),
                                    subtitle: String(localized: "What the home shows, and which device this client controls."),
                                    systemImage: "square.grid.2x2",
                                    tint: HakoAccentRole.neutral.color
                                )
                            }
                            .buttonStyle(HakoPushRowButtonStyle())
                            .hakoStandardRowMetric()
                            .accessibilityIdentifier("hako.settings.homeCards")
                        }
                    #endif

                    #if os(macOS)
                        FormToggle("Start At Login", "Launch the application when the system is logged in. If enabled at the same time as `Show in Menu Bar` and `Keep Menu Bar in Background`, the application interface will not be opened automatically.", $startAtLogin) { newValue in
                            updateLoginItems(newValue)
                        }

                        Toggle("Show in Menu Bar", isOn: showMenuBarExtra)
                            .onChangeCompat(of: showMenuBarExtra.wrappedValue) { newValue in
                                Task {
                                    await SharedPreferences.showMenuBarExtra.set(newValue)
                                    if !newValue {
                                        menuBarExtraInBackground = false
                                    }
                                }
                            }

                        if showMenuBarExtra.wrappedValue {
                            Picker("Real-time Speed", selection: menuBarExtraSpeedMode) {
                                ForEach(MenuBarExtraSpeedMode.allCases, id: \.rawValue) { mode in
                                    Text(mode.name).tag(mode.rawValue)
                                }
                            }
                            .onChangeCompat(of: menuBarExtraSpeedMode.wrappedValue) { newValue in
                                Task {
                                    await SharedPreferences.menuBarExtraSpeedMode.set(newValue)
                                }
                            }

                            Toggle("Keep Menu Bar in Background", isOn: $menuBarExtraInBackground)
                                .onChangeCompat(of: menuBarExtraInBackground) { newValue in
                                    Task {
                                        await SharedPreferences.menuBarExtraInBackground.set(newValue)
                                    }
                                }
                        }

                    #endif

                    // Cache Size and Clear Cache lived here. The review moved both to 核心, where
                    // the client's own figures are read and its maintenance actions are taken;
                    // this page is about how the client looks and speaks.

                    // The menu the tools page used to carry. Its contents were the home-layout
                    // sheet and the remote control picker; both are settings, so both arrive on
                    // this page, in its own row language, with the menu's behaviour kept item for
                    // item - the sheet still opens, the active server still carries a checkmark,
                    // and the local device is still the way out of remote control.
                    HakoSettingsSection {
                        // The picker the menu showed only when there was somewhere to switch to,
                        // which is what its `if !servers.isEmpty` did.
                        if !remoteServers.isEmpty {
                            HakoRowDivider()
                            FormButton {
                                environments.exitRemoteControl()
                            } label: {
                                remoteControlRow(
                                    title: String(localized: "Local Device"),
                                    systemImage: "iphone",
                                    isActive: environments.remoteServer == nil
                                )
                            }
                            .buttonStyle(HakoPushRowButtonStyle())
                            .accessibilityIdentifier("hako.settings.remoteControl.local")

                            ForEach(remoteServers) { server in
                                HakoRowDivider()
                                FormButton {
                                    guard environments.remoteServer?.id != server.id else { return }
                                    environments.enterRemoteControl(server)
                                } label: {
                                    remoteControlRow(
                                        title: server.displayName,
                                        systemImage: "server.rack",
                                        isActive: environments.remoteServer?.id == server.id
                                    )
                                }
                                .buttonStyle(HakoPushRowButtonStyle())
                                .accessibilityIdentifier("hako.settings.remoteControl.server")
                            }

                            HakoRowDivider()
                            FormButton {
                                NotificationCenter.default.post(
                                    name: .navigateToSettingsPage,
                                    object: SettingsPage.remoteControl
                                )
                            } label: {
                                HakoToolRow(
                                    title: String(localized: "Manage Servers..."),
                                    systemImage: "slider.horizontal.3",
                                    tint: HakoAccentRole.neutral
                                )
                            }
                            .buttonStyle(HakoPushRowButtonStyle())
                            .accessibilityIdentifier("hako.settings.remoteControl.manage")
                        }
                    }

                    #if os(macOS)
                        if Variant.useSystemExtension {
                            Section("Update Settings") {
                                Picker("Update Track", selection: $updateTrack) {
                                    Text("Stable").tag(UpdateTrack.stable)
                                    Text("Beta").tag(UpdateTrack.beta)
                                }
                                .onChangeCompat(of: updateTrack) { newValue in
                                    Task {
                                        await updateManager.updateTrackChanged(to: newValue)
                                    }
                                }

                                FormItem(String(localized: "GitHub Token")) {
                                    SecureField("GitHub Token", text: $githubToken, prompt: Text("Get higher GitHub API rate limits"))
                                        .multilineTextAlignment(.trailing)
                                        .onChangeCompat(of: githubToken) { newValue in
                                            Task {
                                                let token = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                                await SharedPreferences.githubToken.set(token.isEmpty ? nil : token)
                                            }
                                        }
                                }

                                Toggle("Automatic Update Check", isOn: $checkUpdateEnabled)
                                    .onChangeCompat(of: checkUpdateEnabled) { newValue in
                                        Task {
                                            await SharedPreferences.checkUpdateEnabled.set(newValue)
                                        }
                                    }

                                FormButton {
                                    Task {
                                        do {
                                            if try await updateManager.refreshUpdateInfo() != nil {
                                                await updateManager.showUpdateSheet()
                                            } else {
                                                alert = AlertState(
                                                    title: String(localized: "Check Update"),
                                                    message: String(localized: "No updates available")
                                                )
                                            }
                                        } catch {}
                                    }
                                } label: {
                                    if updateManager.isChecking {
                                        HStack(spacing: 6) {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Checking...")
                                        }
                                    } else {
                                        Label("Check Update", systemImage: "arrow.triangle.2.circlepath")
                                    }
                                }
                                .disabled(updateManager.isChecking)
                                .contextMenu {
                                    Button("Force Show Latest Version as Update") {
                                        Task {
                                            do {
                                                if try await updateManager.refreshUpdateInfo(force: true) != nil {
                                                    await updateManager.showUpdateSheet()
                                                } else {
                                                    alert = AlertState(
                                                        title: String(localized: "Check Update"),
                                                        message: String(localized: "No updates available")
                                                    )
                                                }
                                            } catch {}
                                        }
                                    }
                                    .disabled(updateManager.isChecking)
                                }

                                if let info = updateManager.updateInfo {
                                    FormButton {
                                        Task {
                                            await updateManager.showUpdateSheet()
                                        }
                                    } label: {
                                        HStack {
                                            Label("Update", systemImage: "arrow.down.circle")
                                            Spacer()
                                            Text(verbatim: "v\(info.versionName)")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }

                            Section("System Extension") {
                                if systemExtensionInstalled {
                                    FormButton {
                                        Task {
                                            await updateSystemExtension()
                                        }
                                    } label: {
                                        Label("Update", systemImage: "arrow.down.doc.fill")
                                    }
                                    FormButton(role: .destructive) {
                                        Task {
                                            await uninstallSystemExtension()
                                        }
                                    } label: {
                                        Label("Uninstall", systemImage: "trash.fill").foregroundColor(.red)
                                    }
                                } else {
                                    FormButton {
                                        Task {
                                            await installSystemExtension()
                                        }
                                    } label: {
                                        Label("Install", systemImage: "lock.doc.fill")
                                    }
                                }
                            }

                            Section {
                                if !helperStatusLoaded {
                                    ProgressView()
                                } else if rootHelperRegistrationStatus == .enabled {
                                    FormButton {
                                        Task {
                                            do {
                                                try HelperServiceManager.unregisterRootHelper()
                                                try await Task.sleep(for: .seconds(1))
                                                try HelperServiceManager.registerRootHelper()
                                                refreshHelperStatus()
                                            } catch {
                                                refreshHelperStatus()
                                                if rootHelperRegistrationStatus == .requiresApproval {
                                                    HelperServiceManager.openApprovalSettings()
                                                } else {
                                                    alert = AlertState(action: "update helper service", error: error)
                                                }
                                            }
                                        }
                                    } label: {
                                        Label("Update", systemImage: "arrow.down.doc.fill")
                                    }
                                    FormButton(role: .destructive) {
                                        performHelperAction(actionName: "uninstall helper service") {
                                            try HelperServiceManager.unregisterRootHelper()
                                        }
                                    } label: {
                                        Label("Uninstall", systemImage: "trash.fill").foregroundColor(.red)
                                    }
                                } else if rootHelperRegistrationStatus == .requiresApproval {
                                    FormButton {
                                        HelperServiceManager.openApprovalSettings()
                                    } label: {
                                        Label("Enable", systemImage: "switch.2")
                                    }
                                } else {
                                    FormButton {
                                        performHelperAction(actionName: "install helper service") {
                                            try HelperServiceManager.registerRootHelper()
                                        }
                                    } label: {
                                        Label("Install", systemImage: "square.and.arrow.down.fill")
                                    }
                                }
                            } header: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Helper Service")
                                    Text("This helper service provides process lookup for `process_name` and `process_path` routing rules, and manages the working directory.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textCase(nil)
                                }
                            }
                        }
                    #endif
                }
            }
        }
        .alert($alert)
        #if os(macOS)
            .alert($updateManager.alert)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard Variant.useSystemExtension, helperStatusLoaded else {
                    return
                }
                Task {
                    await refreshHelperStatusUntilSettled()
                }
            }
        #endif
            // Named for what it configures rather than for the target it lives in, and it
            // wears the shared chrome: the same title treatment, the same back control and
            // the same tab-bar rule as a page on the scaffold.
            .hakoNavigationChrome(title: String(localized: "Client Settings"))
            // The review's high-priority item on this page: its one-line rows must be the size of
            // a first-level row. The container this page uses is shared with pages that are
            // frozen, so the metric is asked for here, on the page, rather than in the container.
            .environment(\.hakoCompactRows, true)
            .sheet(isPresented: $showCardManagement, content: {
                if #available(iOS 16.0, *) {
                    CardManagementSheet().presentationDetents([.large]).presentationDragIndicator(.visible)
                } else {
                    CardManagementSheet()
                }
            })
            .onAppear {
                Task { await reloadRemoteServers() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteServersUpdated)) { _ in
                Task { await reloadRemoteServers() }
            }
    }

    /// A remote control row: the name, and a checkmark when it is the one in use.
    private func remoteControlRow(title: String, systemImage: String, isActive: Bool) -> some View {
        HakoRowBody(
            title: title,
            systemImage: systemImage,
            tint: HakoAccentRole.neutral.color,
            showsDisclosure: false
        ) {
            if isActive {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func reloadRemoteServers() async {
        remoteServers = await (try? RemoteServerManager.list()) ?? []
    }

    private func loadSettings() async {
        selectedLanguage = Self.currentLanguage()
        #if os(macOS)
            startAtLogin = SMAppService.mainApp.status == .enabled
            menuBarExtraInBackground = await SharedPreferences.menuBarExtraInBackground.get()
            if Variant.useSystemExtension {
                systemExtensionInstalled = await SystemExtension.isInstalled()
                let trackString = await SharedPreferences.updateTrack.get()
                updateTrack = UpdateTrack.resolved(from: trackString)
                githubToken = await SharedPreferences.githubToken.get()
                checkUpdateEnabled = await SharedPreferences.checkUpdateEnabled.get()
            }
        #endif
        isLoading = false
        #if os(macOS)
            if Variant.useSystemExtension {
                refreshHelperStatus()
                helperStatusLoaded = true
            }
        #endif
    }

    #if os(tvOS)

        private var selectedLanguageName: String {
            Self.supportedLanguages.first { $0.code == selectedLanguage }?.name
                ?? String(localized: "System Default")
        }

        private struct LanguagePickerView: View {
            @Binding var selection: String?
            @State private var alert: AlertState?

            var body: some View {
                FormView {
                    ForEach(AppView.supportedLanguages, id: \.code) { language in
                        Button {
                            selection = language.code
                            ApplicationLocale.setSelectedIdentifier(language.code)
                            alert = AlertState(
                                title: String(localized: "Restart Required"),
                                message: String(localized: "Language will be changed after restarting the app.")
                            )
                        } label: {
                            HStack {
                                Text(language.name)
                                Spacer()
                                Image(systemName: "checkmark")
                                    .opacity(selection == language.code ? 1 : 0)
                            }
                        }
                    }
                }
                .alert($alert)
                .navigationTitle("Language")
            }
        }

    #endif

    private static func currentLanguage() -> String? {
        guard let selectedIdentifier = ApplicationLocale.selectedIdentifier else {
            return nil
        }
        let current = canonicalLanguageCode(selectedIdentifier)
        for language in supportedLanguages {
            guard let code = language.code else {
                continue
            }
            if current == code || current.hasPrefix("\(code)-") || current.hasPrefix("\(code)_") {
                return code
            }
        }
        return nil
    }

    #if !os(tvOS)

        private func updateLanguage(_ language: String?) {
            ApplicationLocale.setSelectedIdentifier(language)
            alert = AlertState(
                title: String(localized: "Restart Required"),
                message: String(localized: "Language will be changed after restarting the app.")
            )
        }

    #endif

    private static func configuredLanguageCodes() -> [String] {
        let rawCodes: [String]
        if let configured = Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String],
           !configured.isEmpty
        {
            rawCodes = configured
        } else if let development = Bundle.main.developmentLocalization, !development.isEmpty {
            rawCodes = [development]
        } else {
            rawCodes = []
        }

        var seen = Set<String>()
        var codes: [String] = []
        for rawCode in rawCodes {
            let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let canonical = canonicalLanguageCode(trimmed)
            guard !canonical.isEmpty, seen.insert(canonical).inserted else {
                continue
            }
            codes.append(canonical)
        }
        return codes
    }

    private static func canonicalLanguageCode(_ code: String) -> String {
        Locale.canonicalLanguageIdentifier(from: code)
    }

    #if os(macOS)

        private func updateLoginItems(_ startAtLogin: Bool) {
            do {
                if startAtLogin {
                    if SMAppService.mainApp.status == .enabled {
                        try? SMAppService.mainApp.unregister()
                    }

                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                alert = AlertState(action: "update login items", error: error)
            }
        }

        private func installSystemExtension() async {
            do {
                let result = try await SystemExtension.install()
                await SharedPreferences.rootHelperPromptPending.set(true)
                if result == .willCompleteAfterReboot {
                    alert = AlertState(errorMessage: String(localized: "Need Reboot"))
                    return
                }
                systemExtensionInstalled = true
                NotificationCenter.default.post(name: .systemExtensionInstalled, object: nil)
            } catch {
                alert = AlertState(action: "install system extension", error: error)
            }
        }

        private func updateSystemExtension() async {
            do {
                if let result = try await SystemExtension.install(forceUpdate: true) {
                    switch result {
                    case .completed:
                        alert = AlertState(
                            title: String(localized: "Update"),
                            message: String(localized: "System Extension updated.")
                        )
                    case .willCompleteAfterReboot:
                        alert = AlertState(
                            title: String(localized: "Update"),
                            message: String(localized: "Reboot required.")
                        )
                    }
                }
            } catch {
                alert = AlertState(action: "update system extension", error: error)
            }
        }

        private func uninstallSystemExtension() async {
            do {
                if let result = try await SystemExtension.uninstall() {
                    switch result {
                    case .completed:
                        systemExtensionInstalled = false
                        alert = AlertState(
                            title: String(localized: "Uninstall"),
                            message: String(localized: "System Extension removed.")
                        )
                    case .willCompleteAfterReboot:
                        alert = AlertState(
                            title: String(localized: "Uninstall"),
                            message: String(localized: "Reboot required.")
                        )
                    }
                }
            } catch {
                alert = AlertState(action: "uninstall system extension", error: error)
            }
        }

        private func performHelperAction(actionName: String, _ action: () throws -> Void) {
            do {
                try action()
                refreshHelperStatus()
            } catch {
                refreshHelperStatus()
                if rootHelperRegistrationStatus == .requiresApproval {
                    HelperServiceManager.openApprovalSettings()
                } else {
                    alert = AlertState(action: actionName, error: error)
                }
            }
        }

        private func refreshHelperStatus() {
            rootHelperRegistrationStatus = HelperServiceManager.rootHelperStatus
        }

        /// SMAppService.status keeps reporting requiresApproval for a while after the user turns the
        /// daemon on in System Settings, so a single read on activation can still be stale.
        private func refreshHelperStatusUntilSettled() async {
            let previousStatus = rootHelperRegistrationStatus
            refreshHelperStatus()
            guard previousStatus == .requiresApproval else {
                return
            }
            for _ in 0 ..< 5 {
                guard rootHelperRegistrationStatus == .requiresApproval else {
                    return
                }
                try? await Task.sleep(for: .seconds(1))
                refreshHelperStatus()
            }
        }

    #endif

}
