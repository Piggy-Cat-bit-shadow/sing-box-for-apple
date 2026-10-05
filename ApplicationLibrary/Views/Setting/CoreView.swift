import Libbox
import Library
import SwiftUI
#if os(iOS)
    import FileProvider
    import UIKit
#elseif os(macOS)
    import ServiceManagement
#endif

@MainActor
public struct CoreView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var isLoading = true
    @State private var alert: AlertState?

    @State private var disableDeprecatedWarnings = false

    @State private var version = ""
    @State private var dataSize: String?
    @State private var dataSizeLoaded = false

    #if os(macOS)
        @State private var helperUnavailable = false
    #endif

    public init() {}

    public var body: some View {
        HakoSettingsScaffold(title: String(localized: "Core")) {
            if isLoading {
                HakoLoadingState()
                    .onAppear {
                        Task {
                            await loadSettings()
                        }
                    }
            } else {
                versionSection
                if Variant.isBeta {
                    betaSection
                }
                workingDirectorySection
            }
        }
        .alert($alert)
        .onAppear {
            guard !isLoading else {
                return
            }
            Task {
                await refreshWorkingDirectorySize()
            }
        }
        .onChangeCompat(of: scenePhase) { newValue in
            guard newValue == .active, !isLoading else {
                return
            }
            Task {
                await refreshWorkingDirectorySize()
            }
        }
    }

    private var versionSection: some View {
        HakoSettingsSection {
            HakoMetricRow(String(localized: "Version"), value: version, systemImage: "shippingbox.fill", tint: .indigo)
            dataSizeRow
        }
    }

    @ViewBuilder
    private var dataSizeRow: some View {
        if let dataSize {
            HakoMetricRow(String(localized: "Data Size"), value: dataSize, systemImage: "internaldrive.fill", tint: .teal)
        } else if !dataSizeLoaded {
            HakoValueRow(String(localized: "Data Size")) {
                ProgressView()
            }
        } else {
            #if os(macOS)
                Button {
                    alert = helperRequiredAlert()
                } label: {
                    HakoMetricRow(
                        String(localized: "Data Size"),
                        value: String(localized: "Unavailable"),
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }
                .buttonStyle(.plain)
            #endif
        }
    }

    private var betaSection: some View {
        HakoSettingsSection(
            String(localized: "Beta"),
            footnote: "These options belong to a beta build and may change or disappear."
        ) {
            HakoToggleRow(
                String(localized: "Disable Deprecated Warnings"),
                subtitle: String(localized: "Do not warn about configuration that uses deprecated features."),
                isOn: $disableDeprecatedWarnings
            ) { newValue in
                Task {
                    await SharedPreferences.disableDeprecatedWarnings.set(newValue)
                }
            }
        }
    }

    private var workingDirectorySection: some View {
        HakoSettingsSection(
            String(localized: "Working Directory"),
            footnote: "Where the core keeps its data, its caches and the configuration it is running."
        ) {
            #if os(macOS)
                if !Variant.useSystemExtension {
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: FilePath.workingDirectory.relativePath)
                    } label: {
                        HakoNavigationRow(
                            title: String(localized: "Show in Finder"),
                            subtitle: nil,
                            systemImage: "folder.fill",
                            tint: HakoAccentRole.blue.color,
                            showsDisclosure: false
                        )
                    }
                    .buttonStyle(HakoPushRowButtonStyle())
                    .hakoContainerDrawsDisclosure(true)
                }
            #elseif os(iOS)
                if #available(iOS 16.0, *) {
                    Button {
                        Task {
                            await openInFilesApp()
                        }
                    } label: {
                        HakoNavigationRow(
                            title: String(localized: "Browse in Files"),
                            subtitle: nil,
                            systemImage: "folder.fill",
                            tint: HakoAccentRole.blue.color,
                            showsDisclosure: false
                        )
                    }
                    .buttonStyle(HakoPushRowButtonStyle())
                    .hakoContainerDrawsDisclosure(true)
                }
            #endif

            HakoDestructiveRow(
                String(localized: "Erase Working Directory"),
                subtitle: String(localized: "Deletes the core's data, caches and downloaded resources on this device."),
                systemImage: "trash.fill"
            ) {
                Task {
                    await confirmDestroyWorkingDirectory()
                }
            }
        }
    }

    private nonisolated func loadSettings() async {
        if Variant.screenshotMode {
            await MainActor.run {
                version = "<redacted>"
                dataSize = LibboxFormatBytes(1000 * 1000 * 10)
                isLoading = false
            }
        } else {
            await MainActor.run {
                version = LibboxVersion()
                isLoading = false
            }
            await loadSettingsBackground()
        }
    }

    private nonisolated func loadSettingsBackground() async {
        let disableDeprecatedWarnings = await SharedPreferences.disableDeprecatedWarnings.get()
        await MainActor.run {
            self.disableDeprecatedWarnings = disableDeprecatedWarnings
        }
        await refreshWorkingDirectorySize()
    }

    private nonisolated func refreshWorkingDirectorySize() async {
        guard !Variant.screenshotMode else {
            return
        }
        #if os(macOS)
            let helperUnavailable = Variant.useSystemExtension && HelperServiceManager.rootHelperStatus != .enabled
        #endif
        let workingDirectory = FilePath.workingDirectory
        let dataSize: String? = await BlockingIO.run {
            #if os(macOS)
                if Variant.useSystemExtension {
                    if helperUnavailable {
                        return nil
                    }
                    guard let size = try? RootHelperClient.shared.getWorkingDirectorySize() else {
                        return nil
                    }
                    return LibboxFormatBytes(size)
                } else {
                    return (try? workingDirectory.formattedSize()) ?? "Unknown"
                }
            #else
                return (try? workingDirectory.formattedSize()) ?? "Unknown"
            #endif
        }
        await MainActor.run {
            #if os(macOS)
                self.helperUnavailable = helperUnavailable
            #endif
            self.dataSize = dataSize
            dataSizeLoaded = true
        }
    }

    private func confirmDestroyWorkingDirectory() async {
        #if os(macOS)
            if helperUnavailable {
                alert = helperRequiredAlert()
                return
            }
        #endif
        if environments.extensionProfile?.status.isConnected == true {
            alert = AlertState(
                title: String(localized: "Service is Running"),
                message: String(localized: "The service must be stopped before destroying the working directory."),
                primaryButton: .destructive(String(localized: "Stop Service and Continue")) { [self] in
                    Task {
                        await stopServiceAndDestroy()
                    }
                },
                secondaryButton: .cancel()
            )
        } else {
            await destroyWorkingDirectory()
        }
    }

    private func stopServiceAndDestroy() async {
        do {
            try await environments.extensionProfile!.stop()
            await destroyWorkingDirectory()
        } catch {
            alert = AlertState(action: "stop service before destroying working directory", error: error)
        }
    }

    private func destroyWorkingDirectory() async {
        do {
            let workingDirectory = FilePath.workingDirectory
            #if os(macOS)
                if Variant.useSystemExtension {
                    try await BlockingIO.run {
                        try RootHelperClient.shared.cleanWorkingDirectory()
                    }
                } else {
                    try await BlockingIO.run {
                        try Self.clearWorkingDirectoryContents(at: workingDirectory)
                    }
                }
            #else
                try await BlockingIO.run {
                    try Self.clearWorkingDirectoryContents(at: workingDirectory)
                }
                #if os(iOS)
                    if #available(iOS 16.0, *) {
                        await notifyFileProviderWorkingDirectoryChanged()
                    }
                #endif
            #endif
            isLoading = true
        } catch {
            alert = AlertState(action: "destroy working directory", error: error)
        }
    }

    private nonisolated static func clearWorkingDirectoryContents(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        for item in contents {
            try FileManager.default.removeItem(at: item)
        }
    }

    #if os(macOS)
        private func helperRequiredAlert() -> AlertState {
            AlertState(
                title: String(localized: "Helper Service Required"),
                message: String(localized: "Managing working directory requires Helper Service."),
                primaryButton: .default(String(localized: "App Settings")) {
                    NotificationCenter.default.post(name: .navigateToSettingsPage, object: SettingsPage.app)
                },
                secondaryButton: .cancel(String(localized: "Ok"))
            )
        }
    #endif

    #if os(iOS)
        @available(iOS 16.0, *)
        private nonisolated func fileProviderManager() async throws -> NSFileProviderManager {
            let domains = try await NSFileProviderManager.domains()
            guard let domain = domains.first(where: { $0.identifier.rawValue == AppConfiguration.fileProviderDomainID }) else {
                throw NSError(domain: "CoreView", code: 0, userInfo: [NSLocalizedDescriptionKey: "File provider domain not found"])
            }
            guard let manager = NSFileProviderManager(for: domain) else {
                throw NSError(domain: "CoreView", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to get file provider manager"])
            }
            return manager
        }

        @available(iOS 16.0, *)
        private nonisolated func notifyFileProviderWorkingDirectoryChanged() async {
            do {
                let manager = try await fileProviderManager()
                try await manager.signalEnumerator(for: .rootContainer)
                try await manager.signalEnumerator(for: .workingSet)
            } catch {
                await MainActor.run {
                    alert = AlertState(action: "notify Files app about working directory changes", error: error)
                }
            }
        }

        @available(iOS 16.0, *)
        private nonisolated func openInFilesApp() async {
            do {
                let manager = try await fileProviderManager()
                try await manager.signalEnumerator(for: .workingSet)
                let url = try await manager.getUserVisibleURL(for: .rootContainer)
                guard let sharedURL = URL(string: "shareddocuments://\(url.path)") else {
                    throw NSError(domain: "CoreView", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to create shared documents URL"])
                }
                await MainActor.run {
                    UIApplication.shared.open(sharedURL)
                }
            } catch {
                await MainActor.run {
                    alert = AlertState(action: "open working directory in Files", error: error)
                }
            }
        }
    #endif
}

private extension URL {
    func formattedSize() throws -> String? {
        guard let enumerator = FileManager.default.enumerator(
            at: self,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else {
            return nil
        }
        var size = 0
        while let url = enumerator.nextObject() as? URL {
            size += try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        guard let byteCount = formatter.string(for: size) else {
            return nil
        }
        return byteCount
    }
}
