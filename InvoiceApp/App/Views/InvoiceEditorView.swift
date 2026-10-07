import SwiftUI
import SwiftData
import AppKit
import InvoiceCore

struct InvoiceEditorView: View {
    @Environment(\.modelContext) private var context
    @Bindable var invoice: Invoice
    @Query(sort: \Client.name) private var clients: [Client]

    @State private var exportError: String?
    @State private var exportNotice: String?
    @State private var issueError: String?
    @State private var showingPreview = false

    private var service: InvoiceService { InvoiceService(context: context) }
    private var profile: BusinessProfile { service.profile() }
    private var document: InvoiceDocument { invoice.document(profile: profile) }
    private var totals: InvoiceTotals { document.totals }
    private var issues: [ValidationIssue] { InvoiceValidator().validate(document) }
    private var editable: Bool { invoice.status.isEditable }

    private var orderedItems: [LineItem] {
        invoice.items.sorted { $0.position < $1.position }
    }

    var body: some View {
        Form {
            if !editable {
                Section {
                    Label("This invoice has been issued, so its details are locked. "
                          + "Correct it with a credit note.", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ValidationBanner(issues: issues)
            }

            detailsSection
            linesSection
            totalsSection

            Section("Notes") {
                TextField("Payment terms shown on the invoice", text: $invoice.paymentTerms)
                    .disabled(!editable)
                TextField("Thank-you note, reference, anything else",
                          text: $invoice.notes, axis: .vertical)
                    .lineLimit(2...6)
                    .disabled(!editable)
            }

            exemptionSection
        }
        .formStyle(.grouped)
        .navigationTitle(invoice.number)
        .navigationSubtitle(invoice.status.label)
        .toolbar { toolbar }
        .alert("Export failed", isPresented: binding($exportError)) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
        .alert("Cannot issue yet", isPresented: binding($issueError)) {
            Button("OK", role: .cancel) { issueError = nil }
        } message: { Text(issueError ?? "") }
        .alert("Exported", isPresented: binding($exportNotice)) {
            Button("OK", role: .cancel) { exportNotice = nil }
        } message: { Text(exportNotice ?? "") }
        .sheet(isPresented: $showingPreview) {
            PDFPreviewSheet(document: document, logo: logoImage)
        }
    }

    // MARK: Sections

    private var detailsSection: some View {
        Section("Details") {
            // Never editable, in either state. A draft shows what it *will* be called,
            // because letting someone type a number here would either be overwritten on
            // issue (confusing) or punch a hole in the sequence (illegal in much of the
            // EU). Showing the next number is the useful half of that affordance.
            if invoice.status == .draft {
                LabeledContent("Invoice number") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(service.nextIssuedNumber(on: invoice.issueDate))
                            .monospacedDigit()
                        Text("assigned when you issue this invoice")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                LabeledContent("Invoice number", value: invoice.number)
            }

            Picker("Client", selection: $invoice.client) {
                Text("None").tag(Client?.none)
                ForEach(clients) { Text($0.displayName).tag(Optional($0)) }
            }
            .disabled(!editable)

            Picker("Currency", selection: $invoice.currencyCode) {
                ForEach(["EUR", "USD", "GBP", "CHF", "SEK", "DKK", "NOK", "PLN", "CAD", "AUD", "JPY"],
                        id: \.self) { Text($0).tag($0) }
            }
            .disabled(!editable)

            DatePicker("Issued", selection: $invoice.issueDate, displayedComponents: .date)
                .disabled(!editable)
            DatePicker("Supplied",
                       selection: Binding(get: { invoice.deliveryDate ?? invoice.issueDate },
                                          set: { invoice.deliveryDate = $0 }),
                       displayedComponents: .date)
                .help("The date the work was delivered. This determines the VAT period, "
                      + "and it is not always the issue date.")
                .disabled(!editable)
            DatePicker("Due",
                       selection: Binding(get: { invoice.dueDate ?? invoice.issueDate },
                                          set: { invoice.dueDate = $0 }),
                       displayedComponents: .date)
                .disabled(!editable)

            TextField("Client's reference / PO number", text: $invoice.buyerReference)
                .help("Many corporate buyers reject an invoice that has no purchase order "
                      + "reference.")
                .disabled(!editable)

            Picker("Payment by", selection: Binding(get: { invoice.paymentMeans },
                                                    set: { invoice.paymentMeans = $0 })) {
                ForEach(PaymentMeans.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .disabled(!editable)
        }
    }

    private var linesSection: some View {
        Section("Line items") {
            ForEach(orderedItems) { item in
                LineItemRow(item: item, currency: invoice.currency, editable: editable)
            }
            .onDelete { offsets in
                let targets = offsets.map { orderedItems[$0] }
                service.deleteLines(targets, from: invoice)
            }
            .onMove { source, destination in
                var ordered = orderedItems
                ordered.move(fromOffsets: source, toOffset: destination)
                for (index, item) in ordered.enumerated() { item.position = index }
            }

            if editable {
                Button { _ = service.addLine(to: invoice) } label: {
                    Label("Add line", systemImage: "plus.circle")
                }
            }
        }
    }

    private var totalsSection: some View {
        Section("Totals") {
            LabeledContent("Subtotal", value: totals.lineTotal.formatted())
            ForEach(totals.breakdown, id: \.self) { row in
                if row.category.requiresExemptionReason {
                    LabeledContent(row.category.label, value: "no VAT")
                } else {
                    LabeledContent("VAT \(row.rate.rateString)% on "
                                   + row.taxableBase.formatted(),
                                   value: row.taxAmount.formatted())
                }
            }
            LabeledContent("Total") {
                Text(totals.grandTotal.formatted()).bold().monospacedDigit()
            }
            HStack {
                Text("Already paid")
                Spacer()
                MoneyField(title: "Prepaid", value: $invoice.prepaidAmountValue,
                           currency: invoice.currency)
                    .disabled(!editable)
            }
            if !totals.prepaid.isZero {
                LabeledContent("Amount due") {
                    Text(totals.duePayable.formatted()).bold().monospacedDigit()
                }
            }
        }
    }

    /// Only shown when a line actually needs a reason, so the form does not nag about
    /// VAT categories nobody is using.
    @ViewBuilder
    private var exemptionSection: some View {
        let needed = Set(invoice.items.map(\.vatCategory).filter(\.requiresExemptionReason))
        if !needed.isEmpty {
            Section("Why no VAT is charged") {
                ForEach(Array(needed).sorted { $0.rawValue < $1.rawValue }, id: \.self) { category in
                    TextField(category.label,
                              text: Binding(
                                get: { invoice.exemptionReasons[category]
                                        ?? category.defaultExemptionReason ?? "" },
                                set: { invoice.exemptionReasons[category] = $0 }))
                        .disabled(!editable)
                }
                Text("This wording is printed on the invoice and carried in the e-invoice XML. "
                     + "Tax rules require it whenever VAT is not charged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button { showingPreview = true } label: { Label("Preview", systemImage: "eye") }
        }
        ToolbarItem {
            Menu {
                ForEach(ExportService.Format.allCases) { format in
                    Button(format.label) { export(format) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
        ToolbarItem {
            if invoice.status == .draft {
                Button("Issue") { issue() }
                    .disabled(InvoiceValidator().blocksExport(issues))
                    .help(InvoiceValidator().blocksExport(issues)
                          ? "Fix the problems listed above first."
                          : "Assigns the next number in your sequence and locks the invoice.")
            } else if invoice.status == .issued {
                Button("Mark paid") { service.markPaid(invoice) }
            }
        }
    }

    // MARK: Actions

    private var logoImage: NSImage? {
        profile.logo.flatMap(NSImage.init(data:))
    }

    private func issue() {
        do {
            try service.issue(invoice)
        } catch {
            issueError = error.localizedDescription
        }
    }

    private func export(_ format: ExportService.Format) {
        do {
            let exporter = ExportService(document: document, logo: logoImage,
                                        pageSize: profile.defaultCurrencyCode == "USD"
                                            ? .usLetter : .a4)
            guard let outcome = try exporter.save(format: format) else { return }
            if !outcome.warnings.isEmpty {
                exportNotice = "Saved to \(outcome.url.lastPathComponent).\n\n"
                    + outcome.warnings.joined(separator: "\n\n")
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func binding(_ source: Binding<String?>) -> Binding<Bool> {
        Binding(get: { source.wrappedValue != nil },
                set: { if !$0 { source.wrappedValue = nil } })
    }
}

struct LineItemRow: View {
    @Bindable var item: LineItem
    let currency: Currency
    let editable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Description", text: $item.details)
                    .textFieldStyle(.roundedBorder)

                DecimalField(title: "Qty", value: $item.quantity, width: 56)

                Picker("", selection: $item.unitCode) {
                    ForEach(UnitCode.options, id: \.code) { Text($0.label).tag($0.code) }
                }
                .labelsHidden()
                .frame(width: 96)

                MoneyField(title: "Price", value: $item.unitPriceValue, currency: currency)

                Text(item.total(currency: currency).formatted())
                    .monospacedDigit()
                    .frame(width: 92, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Picker("VAT", selection: Binding(get: { item.vatCategory },
                                                 set: { item.vatCategory = $0 })) {
                    ForEach(VATCategory.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 220)

                if !item.vatCategory.requiresExemptionReason {
                    DecimalField(title: "Rate", value: $item.vatRate, width: 56)
                    Text("%").foregroundStyle(.secondary)
                }

                Spacer()

                Text("Discount").font(.caption).foregroundStyle(.secondary)
                MoneyField(title: "Discount", value: $item.discountValue,
                           currency: currency, width: 84)
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
        .disabled(!editable)
    }
}

/// Renders the real pages and shows them, so what is checked is what is exported.
struct PDFPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: InvoiceDocument
    let logo: NSImage?

    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Divider()

            ScrollView {
                let renderer = InvoicePDFRenderer(document: document, logo: logo)
                VStack(spacing: 16) {
                    ForEach(Array(renderer.pages().enumerated()), id: \.offset) { _, content in
                        InvoicePDFPage(document: document, content: content, logo: logo,
                                       locale: .current, size: CGSize(width: 612, height: 792))
                            .scaleEffect(0.82, anchor: .top)
                            .frame(width: 612 * 0.82, height: 792 * 0.82)
                            .shadow(radius: 3)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 620, height: 760)
    }
}
