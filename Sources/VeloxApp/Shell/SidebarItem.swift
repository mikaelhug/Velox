import SwiftUI

/// The four resource dashboards reachable from the sidebar.
enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case containers
    case images
    case volumes
    case networks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: return "Containers"
        case .images:     return "Images"
        case .volumes:    return "Volumes"
        case .networks:   return "Networks"
        }
    }

    var systemImage: String {
        switch self {
        case .containers: return "shippingbox"
        case .images:     return "square.stack.3d.up"
        case .volumes:    return "externaldrive"
        case .networks:   return "network"
        }
    }
}
