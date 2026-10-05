import SwiftUI

// Section is a top-level navigation item in the sidebar, OrbStack-style.
enum Section: String, CaseIterable, Identifiable {
    case containers, images, volumes, networks, machines, commands, hardware, operatorAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: return "Containers"
        case .images: return "Images"
        case .volumes: return "Volumes"
        case .networks: return "Networks"
        case .machines: return "Machines"
        case .commands: return "Commands"
        case .hardware: return "Hardware"
        case .operatorAI: return "Operator"
        }
    }

    var icon: String {
        switch self {
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .volumes: return "externaldrive"
        case .networks: return "point.3.connected.trianglepath.dotted"
        case .machines: return "desktopcomputer"
        case .commands: return "chevron.left.forwardslash.chevron.right"
        case .hardware: return "cpu"
        case .operatorAI: return "wand.and.stars"
        }
    }

    var group: String {
        switch self {
        case .containers, .images, .volumes, .networks: return "Docker"
        case .machines: return "Linux"
        case .commands, .hardware, .operatorAI: return "General"
        }
    }
}

// Sidebar groups in display order.
let sidebarGroups: [(name: String, sections: [Section])] = [
    ("Docker", [.containers, .images, .volumes, .networks]),
    ("Linux", [.machines]),
    ("General", [.commands, .hardware, .operatorAI]),
]
