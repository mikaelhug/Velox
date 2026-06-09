import SwiftUI
import VeloxCore

@MainActor
@Observable
final class NetworksModel {
    let docker: any DockerClientProtocol
    let store: DockerResourceStore

    init(docker: any DockerClientProtocol, store: DockerResourceStore) {
        self.docker = docker; self.store = store
    }

    // Data is read from the shared store (persistent across pane switches).
    var networks: [NetworkSummary] { store.networks }
    var loadError: String? { store.networksError }
    var hasLoaded: Bool { store.networksLoaded }

    func refresh() async { await store.refreshNetworks() }
}

struct NetworksView: View {
    @State private var model: NetworksModel

    init(docker: any DockerClientProtocol, store: DockerResourceStore) {
        _model = State(initialValue: NetworksModel(docker: docker, store: store))
    }

    var body: some View {
        List {
            ForEach(model.networks) { network in
                NetworkRow(network: network)
            }
        }
        .overlay {
            if model.hasLoaded && model.networks.isEmpty {
                ContentUnavailableView("No Networks", systemImage: SidebarItem.networks.systemImage,
                                       description: Text(model.loadError ?? "Docker networks appear here."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
        }
    }
}

private struct NetworkRow: View {
    let network: NetworkSummary

    var body: some View {
        DisclosureGroup {
            if network.attachedContainers.isEmpty {
                Text("No attached containers")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 4)
            } else {
                ForEach(network.attachedContainers) { c in
                    HStack {
                        Image(systemName: "shippingbox").foregroundStyle(.secondary)
                        Text(c.name)
                        Spacer()
                        if let ip = c.ipv4, !ip.isEmpty {
                            Text(ip).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .foregroundStyle(driverTint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(network.name).fontWeight(.medium)
                    HStack(spacing: 6) {
                        Text(network.driver)
                        if !network.subnets.isEmpty {
                            Text("·"); Text(network.subnets.joined(separator: ", ")).monospaced()
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !network.attachedContainers.isEmpty {
                    Text("\(network.attachedContainers.count)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    private var driverTint: Color {
        switch network.driver {
        case "bridge": return .blue
        case "host":   return .purple
        case "null":   return .secondary
        default:        return .teal
        }
    }
}

#if DEBUG
struct NetworksView_Previews: PreviewProvider {
    static var previews: some View {
        NetworksView(docker: MockDockerClient(), store: DockerResourceStore(docker: MockDockerClient()))
            .frame(width: 760, height: 420)
    }
}
#endif
