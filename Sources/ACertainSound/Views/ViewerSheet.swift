import SwiftUI
import CoreImage.CIFilterBuiltins
import AppKit

/// Set up the second-screen viewer: toggle it on, then show the link + QR code
/// for a co-host's phone to open (same Wi-Fi or a hotspot).
struct ViewerSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Second Screen").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider().overlay(Theme.hairline)

            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: Binding(get: { app.viewerRunning }, set: { app.setViewer($0) })) {
                    Text("Share now-playing to a phone")
                        .font(.system(size: 14, weight: .medium))
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)

                if app.viewerRunning, let url = app.viewerURL {
                    Text("On the same Wi-Fi (or a phone hotspot), open this on the phone:")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)

                    HStack(spacing: 8) {
                        Text(url)
                            .font(Theme.mono(14, .medium))
                            .foregroundStyle(Theme.accent)
                            .textSelection(.enabled)
                        Button { copy(url) } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .help("Copy link")
                    }

                    if let qr = qr(url) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 180, height: 180)
                            .padding(10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    }

                    Text("Scan the QR with the phone's camera. If macOS asks to allow incoming connections, click Allow.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Text("Turn this on to serve a live now-playing / up-next / countdown page your co-host can watch on their phone. Both devices need to be on the same network — a phone hotspot works in any venue.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()
            }
            .padding(20)
        }
        .frame(width: 380, height: 470)
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func qr(_ s: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(s.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 180, height: 180))
    }
}
