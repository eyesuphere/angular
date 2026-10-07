import SwiftUI
import SwiftData
import InvoiceCore

struct InvoiceListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Invoice.issueDate, order: .reverse) private var invoices: [Invoice]
    @State private var path: [Invoice] = []
    @State private var search = ""
    @State private var statusFilter: InvoiceStatus?
    @State private var deleteTarget: [Invoice] = []

    private var service: InvoiceService { InvoiceService(context: context) }

    private var filtered: [Invoice] {
        invoices.filter { invoice in
            let matchesStatus = statusFilter == nil || invoice.status == statusFilter
            guard matchesStatus else { return false }
            guard !search.isEmpty else { return true }
            let needle = search.lowercased()
            return invoice.number.lowercased().contains(needle)
                || (invoice.client?.name.lowercased().contains(needle) ?? false)
                || invoice.buyerReference.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(filtered) { invoice in
                    NavigationLink(value: invoice) { row(invoice) }
                        .contextMenu { menu(for: invoice) }
                }
                .onDelete { offsets in
                    // Resolve the objects before deleting anything: the array is a live
                    // query result and shifts under the remaining indices otherwise.
                    let targets = offsets.map { filtered[$0] }
                    let issued = targets.filter { !service.canDelete($0) }
                    if issued.isEmpty {
                        service.delete(targets)
                    } else {
                        deleteTarget = targets
                    }
                }
            }
            .searchable(text: $search, prompt: "Number, client or reference")
            .navigationTitle("Invoices")
            .navigationDestination(for: Invoice.self) { InvoiceEditorView(invoice: $0) }
            .toolbar {
                ToolbarItem {
                    Picker("Status", selection: $statusFilter) {
                        Text("All").tag(InvoiceStatus?.none)
                        ForEach(InvoiceStatus.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    .pickerStyle(.menu)
                }
                ToolbarItem {
                    Button {
                        path.append(service.createDraft())
                    } label: {
                        Label("New Invoice", systemImage: "plus")
                    }
                    .keyboardShortcut("n")
                }
            }
            .overlay {
                if invoices.isEmpty {
                    ContentUnavailableView("No invoices yet", systemImage: "doc.text",
                                           description: Text("Press ⌘N to create one."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .alert("Some of these have been issued",
                   isPresented: Binding(get: { !deleteTarget.isEmpty },
                                        set: { if !$0 { deleteTarget = [] } })) {
                Button("Cancel", role: .cancel) { deleteTarget = [] }
                Button("Delete drafts only") {
                    service.delete(deleteTarget.filter { service.canDelete($0) })
                    deleteTarget = []
                }
            } message: {
                Text("An issued invoice is an accounting record and deleting it would leave a "
                     + "gap in your numbering. Cancel it instead, from its own page.")
            }
        }
    }

    private func row(_ invoice: Invoice) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(invoice.number).font(.headline).monospacedDigit()
                    if invoice.kind == .creditNote {
                        Text("credit").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(invoice.client?.displayName ?? "No client")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let due = invoice.dueDate, invoice.status == .issued {
                Text(due, format: .dateTime.day().month(.abbreviated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            StatusBadge(status: invoice.status, isOverdue: invoice.isOverdue)
            Text(invoice.document.totals.grandTotal.formatted())
                .monospacedDigit()
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func menu(for invoice: Invoice) -> some View {
        Button("Duplicate as draft") { path.append(service.duplicate(invoice)) }
        if invoice.status == .issued {
            Button("Mark as paid") { service.markPaid(invoice) }
            Button("Create credit note") { path.append(service.createCreditNote(for: invoice)) }
        }
        if invoice.status == .paid {
            Button("Reopen as unpaid") { service.reopen(invoice) }
        }
        if service.canDelete(invoice) {
            Divider()
            Button("Delete draft", role: .destructive) { service.delete([invoice]) }
        }
    }
}
