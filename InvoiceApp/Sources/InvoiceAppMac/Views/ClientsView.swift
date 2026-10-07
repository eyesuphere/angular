import SwiftUI
import SwiftData
import InvoiceCore

struct ClientsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Client.name) private var clients: [Client]
    @State private var search = ""

    private var service: InvoiceService { InvoiceService(context: context) }

    private var filtered: [Client] {
        guard !search.isEmpty else { return clients }
        let needle = search.lowercased()
        return clients.filter {
            $0.name.lowercased().contains(needle) || $0.email.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { client in
                    NavigationLink(value: client) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(client.displayName).font(.headline)
                                if !client.email.isEmpty {
                                    Text(client.email).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if !client.invoices.isEmpty {
                                Text("\(client.invoices.count) invoice"
                                     + (client.invoices.count == 1 ? "" : "s"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    // Same hazard as the invoice list: resolve first, then delete.
                    service.delete(offsets.map { filtered[$0] })
                }
            }
            .searchable(text: $search, prompt: "Name or email")
            .navigationTitle("Clients")
            .navigationDestination(for: Client.self) { ClientEditorView(client: $0) }
            .toolbar {
                Button {
                    let client = Client(name: "")
                    context.insert(client)
                } label: {
                    Label("New Client", systemImage: "plus")
                }
            }
            .overlay {
                if clients.isEmpty {
                    ContentUnavailableView("No clients yet", systemImage: "person.2",
                                           description: Text("Add one to start invoicing."))
                }
            }
        }
    }
}

struct ClientEditorView: View {
    @Bindable var client: Client

    var body: some View {
        Form {
            Section("Who they are") {
                TextField("Business name", text: $client.name)
                TextField("Contact person", text: $client.contactName)
                TextField("Email", text: $client.email)
                TextField("Phone", text: $client.phone)
            }

            Section("Address") {
                TextField("Street", text: $client.addressLine1)
                TextField("Street (second line)", text: $client.addressLine2)
                TextField("Postcode", text: $client.postcode)
                TextField("City", text: $client.city)
                CountryCodeField(code: $client.countryCode)
            }

            Section("Tax") {
                TextField("VAT number", text: $client.vatID)
                    .help("Required to invoice a business in another EU country under "
                          + "reverse charge.")
                TextField("Company registration", text: $client.legalRegistrationID)
            }

            Section("Defaults") {
                TextField("Standing PO / reference", text: $client.defaultBuyerReference)
            }

            Section("Notes") {
                TextField("Private notes, not printed", text: $client.notes, axis: .vertical)
                    .lineLimit(2...6)
            }

            if !client.invoices.isEmpty {
                Section("History") {
                    ForEach(client.invoices.sorted { $0.issueDate > $1.issueDate }) { invoice in
                        HStack {
                            Text(invoice.number).monospacedDigit()
                            StatusBadge(status: invoice.status, isOverdue: invoice.isOverdue)
                            Spacer()
                            Text(invoice.document.totals.grandTotal.formatted()).monospacedDigit()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(client.displayName)
    }
}

/// A two-letter country code is mandatory on both parties, and a free text field invites
/// "Germany" where "DE" is required, so the field is a picker over the real list.
struct CountryCodeField: View {
    @Binding var code: String

    private static let codes: [String] = Locale.Region.isoRegions
        .map(\.identifier)
        .filter { $0.count == 2 }
        .sorted()

    var body: some View {
        Picker("Country", selection: $code) {
            Text("Not set").tag("")
            ForEach(Self.codes, id: \.self) { identifier in
                Text("\(name(for: identifier)) (\(identifier))").tag(identifier)
            }
        }
    }

    private func name(for identifier: String) -> String {
        Locale.current.localizedString(forRegionCode: identifier) ?? identifier
    }
}
