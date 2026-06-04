import SwiftUI

/// High-level lifecycle of the Velox VM engine, lifted from `VMManager`'s
/// implicit (`vm == nil`) state into something the UI can switch on and render.
enum EngineState: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)

    /// Human-readable label for the menu bar and status pills.
    var label: String {
        switch self {
        case .stopped:  return "Stopped"
        case .starting: return "Starting…"
        case .running:  return "Running"
        case .stopping: return "Stopping…"
        case .failed:   return "Error"
        }
    }

    /// SF Symbol shown in the menu bar. Filled when the engine is live.
    var menuBarSymbol: String {
        switch self {
        case .running:  return "shippingbox.fill"
        case .starting, .stopping: return "shippingbox"
        case .stopped:  return "shippingbox"
        case .failed:   return "exclamationmark.triangle.fill"
        }
    }

    /// Status-dot tint used across the menu and dashboard.
    var tint: Color {
        switch self {
        case .running:  return .green
        case .starting, .stopping: return .yellow
        case .stopped:  return .secondary
        case .failed:   return .red
        }
    }

    var isBusy: Bool { self == .starting || self == .stopping }
    var isRunning: Bool { self == .running }
    var isStopped: Bool { if case .stopped = self { return true } else { return false } }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
