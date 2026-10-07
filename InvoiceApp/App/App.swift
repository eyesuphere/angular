import SwiftUI
import SwiftData
import InvoiceCore

@main
struct InvoiceApp: App {
    /// One local store. No account, no sync, no server: the data sits in the app's
    /// support directory and is the user's to back up, which is the point.
    let container: ModelContainer

    init() {
        let schema = Schema([BusinessProfile.self, Client.self, Invoice.self, LineItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            // A store that cannot open is unrecoverable, and continuing with an
            // in-memory one would silently discard the user's invoices.
            fatalError("The invoice store could not be opened: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 1000, minHeight: 640)
        }
        .modelContainer(container)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Intentionally empty: a new invoice is created from the invoice list,
                // where the service that assigns its number lives.
            }
        }

        Settings {
            SettingsView()
                .frame(width: 560, height: 520)
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard, invoices, clients

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: return "Overview"
        case .invoices: return "Invoices"
        case .clients: return "Clients"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "chart.bar"
        case .invoices: return "doc.text"
        case .clients: return "person.2"
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var selection: SidebarItem? = .dashboard
    @State private var showingSetup = false

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.label, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch selection {
            case .clients: ClientsView()
            case .invoices: InvoiceListView()
            default: DashboardView()
            }
        }
        .task {
            // Creating the profile up front means no view has to cope with its absence.
            let service = InvoiceService(context: context)
            let profile = service.profile()
            showingSetup = profile.needsSetup
        }
        .sheet(isPresented: $showingSetup) {
            SetupSheet()
        }
    }
}

/// Shown once, on first launch. An invoice without the seller's legal details is not a
/// valid invoice anywhere, so this is not a step worth letting people skip past silently.
struct SetupSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your business details").font(.title2.bold())
            Text("These appear on every invoice you issue, and tax rules require them. "
                 + "You can change them later in Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            BusinessProfileForm(profile: InvoiceService(context: context).profile())

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
