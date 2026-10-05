import Foundation
import Libbox
import Library
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct NewProfileMenuView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @Environment(\.dismiss) private var dismiss
    @State private var alert: AlertState?
    @State private var importRequest: NewProfileView.ImportRequest?
    @State private var localImportRequest: NewProfileView.LocalImportRequest?
    @State private var manualCreateSucceeded = false
    #if !os(tvOS)
        @State private var showFileImporter = false
        @State private var showQRScanner = false
    #endif
    /// The manual-creation push, on the touch client.
    @State private var showManualCreate = false
    #if os(macOS)
        @State private var showNewProfile = false
    #endif
    private var onComplete: (() -> Void)?

    public init(onComplete: (() -> Void)? = nil) {
        self.onComplete = onComplete
    }

    public var body: some View {
        #if os(macOS)
            macOSBody
        #else
            otherBody
        #endif
    }

    #if os(macOS)
        private var macOSBody: some View {
            VStack(alignment: .leading, spacing: 0) {
                Text("New Profile")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                menuContent
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }
            .alert($alert)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.profile, .json],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .sheet(isPresented: $showNewProfile) {
                NewProfileView(onSuccess: { profile in
                    await SharedPreferences.selectedProfileID.set(profile.mustID)
                    complete()
                })
                .environmentObject(environments)
            }
            .sheet(item: $localImportRequest) { request in
                NewProfileView(localImportRequest: request, onSuccess: { profile in
                    await SharedPreferences.selectedProfileID.set(profile.mustID)
                    complete()
                })
                .environmentObject(environments)
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { result in
                    handleQRScanResult(result)
                }
                .frame(minWidth: 500, minHeight: 400)
            }
            .sheet(item: $importRequest) { request in
                NewProfileView(request, onSuccess: { profile in
                    await SharedPreferences.selectedProfileID.set(profile.mustID)
                    complete()
                })
                .environmentObject(environments)
            }
        }
    #endif

    private var otherBody: some View {
        HakoModalScaffold(title: String(localized: "Add Configuration")) {
            Group {
                if let request = importRequest {
                    NewProfileView(request, onSuccess: { profile in
                        await SharedPreferences.selectedProfileID.set(profile.mustID)
                        complete()
                    })
                    .environmentObject(environments)
                } else if let request = localImportRequest {
                    NewProfileView(localImportRequest: request, onSuccess: { profile in
                        await SharedPreferences.selectedProfileID.set(profile.mustID)
                        complete()
                    })
                    .environmentObject(environments)
                } else {
                    menuContent
                }
            }
            // The hidden destination belongs outside the form, which is where the rest of this
            // client puts one: inside a form it is a row, and a row is laid out as one.
            //
            // Note for whoever picks this up: a stray disclosure indicator still draws at the
            // trailing edge of the tile row in this modal, and it is *not* from here. Replacing
            // the third tile's `NavigationLink` with a `Button` and moving this destination out
            // of the form both left it in place, so the cause is something else - most likely
            // the grouped `Form` giving an accessory to a section whose row holds interactive
            // content. It is cosmetic and it is written down rather than guessed at again.
            .background {
                #if !os(tvOS)
                    NavigationDestinationCompat(isPresented: $showManualCreate) {
                        // Capturing anything that holds the sheet's DismissAction here makes
                        // SwiftUI on iOS 17 loop forever laying the pushed view out.
                        NewProfileView(onSuccess: { [$manualCreateSucceeded] profile in
                            await SharedPreferences.selectedProfileID.set(profile.mustID)
                            $manualCreateSucceeded.wrappedValue = true
                        })
                        .environmentObject(environments)
                    }
                #endif
            }
            .onChangeCompat(of: manualCreateSucceeded) { newValue in
                if newValue {
                    complete()
                }
            }
            .alert($alert)
            #if !os(tvOS)
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: [.profile, .json],
                    allowsMultipleSelection: false
                ) { result in
                    handleFileImport(result)
                }
                .sheet(isPresented: $showQRScanner) {
                    QRScannerView { result in
                        handleQRScanResult(result)
                    }
                }
            #endif
        }
    }

    private func complete() {
        if let onComplete {
            onComplete()
        } else {
            dismiss()
        }
    }

    /// How a configuration gets in.
    ///
    /// The three ways in are the page's whole content, so they are tiles rather than rows:
    /// a row would say "Import from File" in the same voice as every setting on every other
    /// page, and this is not a setting - it is the choice the sheet exists to offer. The
    /// focus platform keeps its rows, whose larger type suits a television.
    @ViewBuilder
    private var menuContent: some View {
        #if os(tvOS)
            FormView {
                Section {
                    FormNavigationLink {
                        ImportProfileView(onComplete: {
                            complete()
                        })
                        .environmentObject(environments)
                    } label: {
                        Label("Import from iPhone or iPad", systemImage: "iphone.and.arrow.forward")
                    }
                }
            }
        #else
            HakoSettingsSection {
                HStack(alignment: .top, spacing: HakoTheme.Spacing.standard) {
                    HakoActionTile(
                        String(localized: "Import from File"),
                        systemImage: "doc.badge.plus",
                        tint: .blue
                    ) {
                        showFileImporter = true
                    }

                    HakoActionTile(
                        String(localized: "Scan QR Code"),
                        systemImage: "qrcode.viewfinder",
                        tint: .teal
                    ) {
                        showQRScanner = true
                    }

                    #if os(macOS)
                        HakoActionTile(
                            String(localized: "Create Manually"),
                            systemImage: "square.and.pencil",
                            tint: .indigo
                        ) {
                            showNewProfile = true
                        }
                    #else
                        // A button, not a `NavigationLink`. A link inside a form is a row, and
                        // the platform gives a row that navigates a disclosure indicator - which
                        // on a row of three action tiles lands at the card's trailing edge, where
                        // it reads as belonging to the card rather than to the third tile. The
                        // tile is its own affordance, named and illustrated, and the reference's
                        // tiles carry no chevron at all. The push is the same hidden destination
                        // the rest of this client uses.
                        HakoActionTile(
                            String(localized: "Create Manually"),
                            systemImage: "square.and.pencil",
                            tint: .indigo
                        ) {
                            showManualCreate = true
                        }
                    #endif
                }
            }
        #endif
    }

    #if !os(tvOS)
        private func handleFileImport(_ result: Result<[URL], Error>) {
            Task { @MainActor in
                do {
                    let urls = try result.get()
                    guard let url = urls.first else { return }

                    if url.pathExtension.lowercased() == "json" {
                        let fileName = url.deletingPathExtension().lastPathComponent
                        localImportRequest = NewProfileView.LocalImportRequest(name: fileName, fileURL: url)
                        return
                    }

                    let data = try await BlockingIO.run {
                        try url.withRequiredSecurityScopedAccess(
                            or: NSError(domain: "NewProfileMenuView", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Missing access to selected file")])
                        ) {
                            try Data(contentsOf: url)
                        }
                    }
                    let content = try LibboxProfileContent.from(data)

                    alert = AlertState(
                        title: String(localized: "Import Profile"),
                        message: String(localized: "Are you sure to import profile \(content.name)?"),
                        primaryButton: .default(String(localized: "Import")) {
                            Task {
                                do {
                                    try await content.importProfile()
                                    environments.profileUpdate.send()
                                    complete()
                                } catch {
                                    alert = AlertState(action: "import profile", error: error)
                                }
                            }
                        },
                        secondaryButton: .cancel()
                    )
                } catch {
                    alert = AlertState(action: "read imported profile file", error: error)
                }
            }
        }
    #endif

    #if !os(tvOS)
        private func handleQRScanResult(_ result: QRScanResult) {
            switch result {
            case let .qrCode(string, _):
                handleQRCodeString(string)
            case let .qrsData(data):
                handleQRSData(data)
            }
        }

        private func handleQRCodeString(_ string: String) {
            var error: NSError?
            let remoteProfile = LibboxParseRemoteProfileImportLink(string, &error)
            if let error {
                alert = AlertState(action: "parse QR code profile link", error: error)
                return
            }
            guard let remoteProfile else {
                alert = AlertState(errorMessage: String(localized: "The QR code does not contain a valid profile import link."))
                return
            }
            importRequest = NewProfileView.ImportRequest(name: remoteProfile.name, url: remoteProfile.url)
        }

        private func handleQRSData(_ data: Data) {
            do {
                let (actualData, _, _) = try BinaryMeta.readFileHeaderMeta(buffer: data)
                let content = try LibboxProfileContent.from(actualData)
                alert = AlertState(
                    title: String(localized: "Import Profile"),
                    message: String(localized: "Are you sure to import profile \(content.name)?"),
                    primaryButton: .default(String(localized: "Import")) {
                        Task {
                            do {
                                try await BlockingIO.run {
                                    var error: NSError?
                                    LibboxCheckConfig(content.config, &error)
                                    if let error {
                                        throw error
                                    }
                                }
                                try await content.importProfile()
                                environments.profileUpdate.send()
                                complete()
                            } catch {
                                alert = AlertState(action: "import profile", error: error)
                            }
                        }
                    },
                    secondaryButton: .cancel()
                )
            } catch {
                alert = AlertState(action: "decode QRS profile data", error: error)
            }
        }
    #endif
}
