import SwiftUI
import Virtualization
import VeloxCore

/// First-launch setup wizard, shown when host virtualization support or the
/// guest image is missing. Walks through a welcome, the gating checks, and a
/// finish step that boots the engine.
struct OnboardingView: View {
    @Environment(EngineController.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    /// Mirrors `GuestInstall.guestAvailable` into observable state. Reading the static
    /// directly in `body` meant a successful "Re-check" changed nothing SwiftUI watches, so
    /// the ✗ row never flipped and the button looked broken even when it had just worked.
    @State private var guestInstalled = GuestInstall.guestAvailable
    @State private var rechecking = false

    private enum Step: Int, CaseIterable { case welcome, checks, finish }
    private var current: Step { Step(rawValue: step) ?? .welcome }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            Divider()
            footer.padding(16)
        }
        .frame(width: 520, height: 420)
    }

    @ViewBuilder
    private var content: some View {
        switch current {
        case .welcome:
            stepBody(icon: "shippingbox.fill", title: "Welcome to Velox",
                     subtitle: "A lightweight, native Docker engine for macOS.") {
                Text("Velox runs a minimal Linux VM with Docker inside it, and talks to it directly. Let's make sure your Mac is ready.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        case .checks:
            stepBody(icon: "checklist", title: "System Check",
                     subtitle: "Velox needs Apple Virtualization and a guest image.") {
                VStack(alignment: .leading, spacing: 12) {
                    checkRow("Virtualization supported", ok: VZVirtualMachine.isSupported,
                             hint: "Requires Apple Silicon and macOS 15+.")
                    checkRow("Guest image installed", ok: guestInstalled,
                             hint: "The guest image ships with Velox and installs on first launch.")
                    Button(rechecking ? "Checking…" : "Re-check") {
                        rechecking = true
                        Task {
                            await engine.refreshReadiness()
                            guestInstalled = GuestInstall.guestAvailable
                            rechecking = false
                        }
                    }
                    .disabled(rechecking)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .finish:
            stepBody(icon: EngineController.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                     title: EngineController.isReady ? "You're all set" : "Almost there",
                     subtitle: EngineController.isReady
                        ? "Start the engine to launch Docker."
                        : "Finish the remaining setup steps, then come back.") {
                Text(EngineController.isReady
                     ? "You can manage the engine from the menu bar at any time."
                     : "The engine can't start until the checks above pass.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            PageDots(count: Step.allCases.count, index: step)
            Spacer()
            switch current {
            case .welcome, .checks:
                Button("Continue") { step += 1 }
                    .keyboardShortcut(.defaultAction)
            case .finish:
                Button(EngineController.isReady ? "Start Engine" : "Done") {
                    engine.completeOnboarding()
                    dismiss()
                    if EngineController.isReady {
                        Task { await engine.start() }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func stepBody(icon: String, title: String, subtitle: String,
                          @ViewBuilder body: () -> some View) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 46)).foregroundStyle(.tint)
            Text(title).font(.title.bold())
            Text(subtitle).font(.headline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            body().padding(.top, 8)
        }
    }

    @ViewBuilder
    private func checkRow(_ title: String, ok: Bool, hint: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            VStack(alignment: .leading) {
                Text(title)
                if !ok { Text(hint).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(i == index ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
        }
    }
}

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView().environment(EngineController())
    }
}
#endif
