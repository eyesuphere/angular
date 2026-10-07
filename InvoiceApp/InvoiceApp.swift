import SwiftUI
import SwiftData
import AppKit
import Foundation
import UniformTypeIdentifiers


@main
struct InvoiceApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .modelContainer(for: [Client.self, Invoice.self, LineItem.self])
    }
}


enum InvoiceStatus: String, CaseIterable, Identifiable {
    case draft = "Draft", sent = "Sent", paid = "Paid"
    var id: String { rawValue }
}

@Model
final class Client {
    var name: String
    var email: String
    var address: String
    @Relationship(deleteRule: .nullify, inverse: \Invoice.client)
    var invoices: [Invoice] = []

    init(name: String = "", email: String = "", address: String = "") {
        self.name = name
        self.email = email
        self.address = address
    }

    var displayName: String { name.isEmpty ? "Unnamed client" : name }
}

@Model
final class Invoice {
    var number: String
    var issueDate: Date
    var dueDate: Date
    var statusRaw: String
    var notes: String
    var taxRate: Double            // percent, e.g. 8.875
    var client: Client?
    @Relationship(deleteRule: .cascade, inverse: \LineItem.invoice)
    var items: [LineItem] = []

    init(number: String, client: Client? = nil) {
        self.number = number
        self.issueDate = .now
        self.dueDate = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
        self.statusRaw = InvoiceStatus.draft.rawValue
        self.notes = ""
        self.taxRate = 0
        self.client = client
    }

    var status: InvoiceStatus {
        get { InvoiceStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }
    var subtotal: Double { items.reduce(0) { $0 + $1.total } }
    var tax: Double { subtotal * taxRate / 100 }
    var total: Double { subtotal + tax }
}

@Model
final class LineItem {
    var details: String
    var quantity: Double
    var unitPrice: Double
    var invoice: Invoice?

    init(details: String = "", quantity: Double = 1, unitPrice: Double = 0) {
        self.details = details
        self.quantity = quantity
        self.unitPrice = unitPrice
    }

    var total: Double { quantity * unitPrice }
}

extension Double {
    var money: String {
        formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }
}


enum SidebarItem: String, CaseIterable, Identifiable {
    case invoices = "Invoices", clients = "Clients"
    var id: String { rawValue }
    var icon: String { self == .invoices ? "doc.text" : "person.2" }
}

struct RootView: View {
    @State private var selection: SidebarItem? = .invoices

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch selection {
            case .clients: ClientListView()
            default: InvoiceListView()
            }
        }
    }
}

// MARK: - Invoices

struct InvoiceListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Invoice.issueDate, order: .reverse) private var invoices: [Invoice]
    @State private var path: [Invoice] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(invoices) { invoice in
                    NavigationLink(value: invoice) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(invoice.number).font(.headline)
                                Text(invoice.client?.name ?? "No client")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(invoice.status.rawValue)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(color(for: invoice.status).opacity(0.2), in: Capsule())
                            Text(invoice.total.money).monospacedDigit()
                        }
                    }
                }
                .onDelete { offsets in
                    // Resolve targets first: deleting mutates the query result.
                    let targets = offsets.map { invoices[$0] }
                    targets.forEach { context.delete($0) }
                }
            }
            .navigationTitle("Invoices")
            .navigationDestination(for: Invoice.self) { InvoiceEditor(invoice: $0) }
            .toolbar {
                Button { addInvoice() } label: { Label("New Invoice", systemImage: "plus") }
            }
            .overlay {
                if invoices.isEmpty {
                    ContentUnavailableView("No invoices yet", systemImage: "doc.text",
                                           description: Text("Click + to create one."))
                }
            }
        }
    }

    /// Next number is one past the highest existing INV-#### so deletions never cause duplicates.
    private func nextNumber() -> String {
        let highest = invoices
            .compactMap { Int($0.number.replacingOccurrences(of: "INV-", with: "")) }
            .max() ?? 0
        return String(format: "INV-%04d", highest + 1)
    }

    private func addInvoice() {
        let invoice = Invoice(number: nextNumber())
        context.insert(invoice)
        invoice.items.append(LineItem())
        path.append(invoice)
    }

    private func color(for status: InvoiceStatus) -> Color {
        switch status { case .draft: .gray; case .sent: .blue; case .paid: .green }
    }
}

// MARK: - Clients

struct ClientListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Client.name) private var clients: [Client]

    var body: some View {
        NavigationStack {
            List {
                ForEach(clients) { client in
                    NavigationLink(client.displayName, value: client)
                }
                .onDelete { offsets in
                    let targets = offsets.map { clients[$0] }
                    targets.forEach { context.delete($0) }
                }
            }
            .navigationTitle("Clients")
            .navigationDestination(for: Client.self) { ClientEditor(client: $0) }
            .toolbar {
                Button { context.insert(Client(name: "New Client")) } label: {
                    Label("New Client", systemImage: "plus")
                }
            }
            .overlay {
                if clients.isEmpty {
                    ContentUnavailableView("No clients yet", systemImage: "person.2",
                                           description: Text("Click + to add one."))
                }
            }
        }
    }
}

struct ClientEditor: View {
    @Bindable var client: Client

    var body: some View {
        Form {
            TextField("Name", text: $client.name)
            TextField("Email", text: $client.email)
            TextField("Address", text: $client.address, axis: .vertical)
                .lineLimit(2...5)
        }
        .formStyle(.grouped)
        .navigationTitle(client.displayName)
    }
}


struct InvoiceEditor: View {
    @Environment(\.modelContext) private var context
    @Bindable var invoice: Invoice
    @Query(sort: \Client.name) private var clients: [Client]
    @State private var exportError: String?

    var body: some View {
        Form {
            Section("Details") {
                TextField("Invoice #", text: $invoice.number)
                Picker("Client", selection: $invoice.client) {
                    Text("None").tag(Client?.none)
                    ForEach(clients) { Text($0.displayName).tag(Optional($0)) }
                }
                DatePicker("Issued", selection: $invoice.issueDate, displayedComponents: .date)
                DatePicker("Due", selection: $invoice.dueDate, displayedComponents: .date)
                Picker("Status", selection: $invoice.status) {
                    ForEach(InvoiceStatus.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section("Line items") {
                ForEach(invoice.items) { item in
                    LineItemRow(item: item)
                }
                .onDelete { offsets in
                    // Snapshot targets before mutating the relationship array.
                    let targets = offsets.map { invoice.items[$0] }
                    for item in targets {
                        invoice.items.removeAll { $0 === item }
                        context.delete(item)
                    }
                }
                Button { invoice.items.append(LineItem()) } label: {
                    Label("Add item", systemImage: "plus.circle")
                }
            }

            Section("Totals") {
                HStack {
                    Text("Tax rate (%)")
                    Spacer()
                    TextField("Tax rate", value: $invoice.taxRate, format: .number)
                        .labelsHidden()
                        .frame(width: 80).multilineTextAlignment(.trailing)
                }
                LabeledContent("Subtotal", value: invoice.subtotal.money)
                LabeledContent("Tax", value: invoice.tax.money)
                LabeledContent("Total") { Text(invoice.total.money).bold() }
            }

            Section("Notes") {
                TextField("Payment terms, thank-you note…", text: $invoice.notes, axis: .vertical)
                    .lineLimit(2...6)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(invoice.number)
        .toolbar {
            Button { exportPDF() } label: { Label("Export PDF", systemImage: "square.and.arrow.up") }
        }
        .alert("Couldn't export PDF", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    @MainActor private func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(invoice.number).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Create the PDF context up front so failures are reported instead of swallowed.
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)   // US Letter
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            exportError = "Could not write to \(url.path)."
            return
        }

        let renderer = ImageRenderer(content: InvoicePDFPage(invoice: invoice))
        var drew = false
        renderer.render { _, draw in
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            drew = true
        }
        ctx.closePDF()

        if !drew {
            try? FileManager.default.removeItem(at: url)
            exportError = "The invoice could not be rendered."
        }
    }
}

struct LineItemRow: View {
    @Bindable var item: LineItem

    var body: some View {
        HStack {
            TextField("Description", text: $item.details)
            TextField("Qty", value: $item.quantity, format: .number)
                .frame(width: 60).multilineTextAlignment(.trailing)
            TextField("Price", value: $item.unitPrice, format: .number)
                .frame(width: 90).multilineTextAlignment(.trailing)
            Text(item.total.money).monospacedDigit()
                .frame(width: 100, alignment: .trailing)
        }
    }
}

/// The printable page. Single page, US Letter (612 x 792 pt).
struct InvoicePDFPage: View {
    let invoice: Invoice

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                Text("INVOICE").font(.system(size: 28, weight: .bold))
                Spacer()
                VStack(alignment: .trailing) {
                    Text(invoice.number).font(.headline)
                    Text("Issued \(invoice.issueDate.formatted(date: .abbreviated, time: .omitted))")
                    Text("Due \(invoice.dueDate.formatted(date: .abbreviated, time: .omitted))")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Bill to").font(.caption).foregroundStyle(.secondary)
                Text(invoice.client?.name ?? "").font(.headline)
                Text(invoice.client?.address ?? "")
                Text(invoice.client?.email ?? "")
            }

            Divider()

            ForEach(invoice.items) { item in
                HStack {
                    Text(item.details)
                    Spacer()
                    Text("\(item.quantity.formatted()) × \(item.unitPrice.money)")
                        .foregroundStyle(.secondary)
                    Text(item.total.money).frame(width: 90, alignment: .trailing)
                }
            }

            Divider()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Subtotal  \(invoice.subtotal.money)")
                Text("Tax  \(invoice.tax.money)")
                Text("Total  \(invoice.total.money)").font(.title3.bold())
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            if !invoice.notes.isEmpty {
                Text(invoice.notes).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
        .padding(48)
        .frame(width: 612, height: 792, alignment: .topLeading)
        .background(.white)
    }
}
