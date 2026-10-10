//
//  HakoTerminalSessionContentView.swift
//  ApplicationLibrary
//
//  The phone's copy of `ApplicationLibrary/Views/Terminal/TerminalSessionContentView.swift`, from
//  `hako-ui` @ `c1935cf`.
//
//  A copy rather than an edit, because that file is upstream's and an iPad or a Mac loads it too. The
//  file-level `#if canImport(GhosttyTerminal)` and the `os(iOS)`/`os(macOS)` colour split are the
//  original's own and are kept as they stand: this file is inside the shared `ApplicationLibrary` target,
//  which is built for iOS, macOS and tvOS, and the type it declares reads `TailsshTerminalSurfaceView`
//  and `TerminalWrapperViewModel`, both of which are themselves behind `#if canImport(GhosttyTerminal)`.
//  A declaration that outlives its dependency does not compile.
//
//  Derived from that original by `scripts/dev/restore_terminal_guards.py`, which applies the rename and
//  nothing else.
//

#if canImport(GhosttyTerminal)
    import GhosttyTerminal
    import Library
    import SwiftUI

    @MainActor
    struct HakoTerminalSessionContentView: View {
        @ObservedObject var viewModel: TerminalWrapperViewModel
        let presentedSession: TailscaleSSHPresentedSession
        var isActive: Bool = true
        var onCloseSession: (() -> Void)?
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            ZStack {
                #if os(iOS)
                    Color(uiColor: .systemBackground)
                        .ignoresSafeArea()
                #elseif os(macOS)
                    Color(nsColor: .windowBackgroundColor)
                        .ignoresSafeArea()
                #endif
                if let terminalState = viewModel.terminalState {
                    TailsshTerminalSurfaceView(
                        state: terminalState,
                        extras: viewModel.extras,
                        isActive: isActive
                    )
                    .opacity(viewModel.hasReceivedOutput ? 1 : 0)
                }
                if case .connecting = viewModel.phase {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        if let banner = viewModel.authBanner, !banner.isEmpty {
                            Text(Self.bannerAttributedString(banner))
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                                .foregroundColor(.primary)
                                .padding()
                                .background(HakoProductPalette.system.control, in: RoundedRectangle(cornerRadius: HakoTheme.Radius.control, style: .continuous))
                                .padding(.horizontal)
                                .frame(maxWidth: 480)
                                .textSelection(.enabled)
                        }
                    }
                } else if case let .finished(reason) = viewModel.phase {
                    VStack {
                        Spacer()
                        if let banner = viewModel.authBanner, !banner.isEmpty {
                            Text(Self.bannerAttributedString(banner))
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                                .foregroundColor(.primary)
                                .padding()
                                .background(HakoProductPalette.system.control, in: RoundedRectangle(cornerRadius: HakoTheme.Radius.control, style: .continuous))
                                .padding(.horizontal)
                                .frame(maxWidth: 480)
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 12) {
                            Text(reason.displayText)
                                .font(.callout)
                                .multilineTextAlignment(.leading)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button("Close") {
                                if let onCloseSession {
                                    onCloseSession()
                                } else {
                                    dismiss()
                                }
                            }
                            .hakoPrimaryActionButtonStyle()
                        }
                        .padding()
                        .background(HakoProductPalette.system.card, in: RoundedRectangle(cornerRadius: HakoTheme.Radius.card, style: .continuous))
                        .padding()
                    }
                }
            }
        }

        var displayedTitle: String {
            Self.displayTitle(
                phase: viewModel.phase,
                extrasTitle: viewModel.extras.title,
                peerDisplayName: presentedSession.peerDisplayName
            )
        }

        static func displayTitle(
            phase: TerminalWrapperViewModel.Phase,
            extrasTitle: String,
            peerDisplayName: String
        ) -> String {
            if case .connecting = phase {
                return peerDisplayName
            }
            let remote = extrasTitle.trimmingCharacters(in: .whitespaces)
            return remote.isEmpty ? peerDisplayName : remote
        }

        static func bannerAttributedString(_ text: String) -> AttributedString {
            var attributed = AttributedString(text)
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
                return attributed
            }
            let nsText = text as NSString
            let matches = detector.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                guard let url = match.url,
                      let range = Range(match.range, in: attributed) else { continue }
                attributed[range].link = url
                attributed[range].foregroundColor = .accentColor
                attributed[range].underlineStyle = .single
            }
            return attributed
        }
    }
#endif
