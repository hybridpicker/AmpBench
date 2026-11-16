import AmpText
import SparkDesign
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What the window says while the amp cannot be reached because of Bluetooth itself: off, not allowed, or missing.
/// Nil while Bluetooth can be used, or while the link is not wanted (after "Disconnect").
struct BluetoothHintContent: Equatable {
    let text: String
    /// The key that leads to the right place in the settings, nil where none can be opened.
    let button: String?
    let url: URL?

    enum Platform { case mac, pad }

    #if os(macOS)
    static let platform = Platform.mac
    #else
    static let platform = Platform.pad
    #endif

    static func make(status: SparkLink.Status, wanted: Bool, on platform: Platform = platform) -> BluetoothHintContent? {
        guard wanted else { return nil }
        switch (status, platform) {
        case (.bluetoothOff, .mac):
            return .init(text: tr("Bluetooth is off on this Mac, so AmpBench cannot find the amp. Turn it on and AmpBench connects by itself."),
                         button: tr("Bluetooth Settings …"),
                         url: URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings"))
        case (.bluetoothOff, .pad):
            return .init(text: tr("Bluetooth is off on this iPad, so AmpBench cannot find the amp. Turn it on in Control Center or Settings and AmpBench connects by itself."),
                         button: nil, url: nil)
        case (.unauthorized, .mac):
            return .init(text: tr("AmpBench may not use Bluetooth, so it cannot find the amp. Allow it under Privacy & Security → Bluetooth."),
                         button: tr("Privacy Settings …"),
                         url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"))
        case (.unauthorized, .pad):
            return .init(text: tr("AmpBench may not use Bluetooth, so it cannot find the amp. Allow it in Settings → AmpBench."),
                         button: tr("Settings …"), url: appSettings)
        case (.unsupported, _):
            return .init(text: tr("This device has no Bluetooth LE, so AmpBench cannot reach the amp."), button: nil, url: nil)
        default:
            return nil
        }
    }

    private static var appSettings: URL? {
        #if canImport(UIKit)
        URL(string: UIApplication.openSettingsURLString)
        #else
        nil
        #endif
    }
}

/// A strip on top of every area while Bluetooth keeps AmpBench from the amp. It goes away by itself once Bluetooth
/// works again; closing it hides it until the state changes.
struct BluetoothHint: View {
    @EnvironmentObject private var link: SparkLink
    @Environment(\.openURL) private var openURL
    @State private var closedFor: SparkLink.Status?

    private var tint: Color { Theme.device.amberHot.color }

    var body: some View {
        if let content = BluetoothHintContent.make(status: link.status, wanted: link.wanted), closedFor != link.status {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tint).accessibilityHidden(true)
                Text(content.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let button = content.button, let url = content.url {
                    Button(button) { openURL(url) }.controlSize(.small)
                }
                Button {
                    closedFor = link.status
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Close message"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 720)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.13)))
            .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.6)))
            .accessibilityElement(children: .contain)
        }
    }
}
