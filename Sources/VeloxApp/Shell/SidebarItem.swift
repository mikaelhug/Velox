import SwiftUI

/// The resource dashboards (and the engine log) reachable from the sidebar.
enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case containers
    case images
    case volumes
    case networks
    case engineLogs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: return "Containers"
        case .images:     return "Images"
        case .volumes:    return "Volumes"
        case .networks:   return "Networks"
        case .engineLogs: return "Engine Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .containers: return "shippingbox"
        case .images:     return "square.stack.3d.up"
        case .volumes:    return "externaldrive"
        case .networks:   return "network"
        case .engineLogs: return "doc.text.magnifyingglass"
        }
    }
}
