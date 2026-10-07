import SwiftUI
import InvoiceCore

/// One printed page.
///
/// Forced into light appearance and explicit black-on-white: a view rendered while the
/// app is in dark mode otherwise picks up the dark palette, and `.secondary` resolves
/// to a light grey that is invisible on paper.
struct InvoicePDFPage: View {
    struct Content {
        let lines: [InvoiceLine]
        let firstLineNumber: Int
        let isFirst: Bool
        let isLast: Bool
        let pageNumber: Int
        let pageCount: Int
    }

    let document: InvoiceDocument
    let content: Content
    let logo: NSImage?
    let locale: Locale
    let size: CGSize

    private var totals: InvoiceTotals { document.totals }

    private var title: String {
        switch document.kind {
        case .invoice: return "INVOICE"
        case .creditNote: return "CREDIT NOTE"
        case .correctedInvoice: return "CORRECTED INVOICE"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if content.isFirst {
                header
                parties
            } else {
                continuationHeader
            }

            lineTable

            if content.isLast {
                Divider()
                totalsBlock
                if !document.paymentTerms.isEmpty || !document.bank.isEmpty {
                    paymentBlock
                }
                if !document.notes.isEmpty {
                    Text(document.notes)
                        .font(.system(size: 9))
                        .foregroundStyle(Color(white: 0.3))
                }
            }

            Spacer(minLength: 0)
            footer
        }
        .font(.system(size: 10))
        .foregroundStyle(.black)
        .padding(48)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .environment(\.locale, locale)
    }

    // MARK: Blocks

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                if let logo {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 160, maxHeight: 56, alignment: .leading)
                }
                Text(title).font(.system(size: 24, weight: .bold)).tracking(1.5)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                labelled("Number", document.number, emphasised: true)
                labelled("Issued", formatted(document.issueDate))
                if let delivery = document.deliveryDate, delivery != document.issueDate {
                    labelled("Supplied", formatted(delivery))
                }
                if let due = document.dueDate {
                    labelled("Due", formatted(due))
                }
                if !document.buyerReference.isEmpty {
                    labelled("Reference", document.buyerReference)
                }
                if let preceding = document.precedingInvoiceNumber, !preceding.isEmpty {
                    labelled("Corrects", preceding)
                }
            }
        }
    }

    private var continuationHeader: some View {
        HStack {
            Text("\(title) \(document.number)").font(.system(size: 11, weight: .semibold))
            Spacer()
            Text("continued").font(.system(size: 9)).foregroundStyle(Color(white: 0.4))
        }
    }

    private var parties: some View {
        HStack(alignment: .top, spacing: 40) {
            party("From", document.seller)
            party("Bill to", document.buyer)
        }
    }

    private func party(_ caption: String, _ value: TradeParty) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color(white: 0.45))
                .padding(.bottom, 2)
            Text(value.name).font(.system(size: 10, weight: .semibold))
            ForEach(value.address.displayLines, id: \.self) { Text($0) }
            if !value.vatID.isEmpty {
                Text("VAT \(value.vatID)").padding(.top, 2)
            }
            if !value.email.isEmpty { Text(value.email) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lineTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("#").frame(width: 16, alignment: .leading)
                Text("Description").frame(maxWidth: .infinity, alignment: .leading)
                Text("Qty").frame(width: 54, alignment: .trailing)
                Text("Unit price").frame(width: 72, alignment: .trailing)
                Text("VAT").frame(width: 38, alignment: .trailing)
                Text("Amount").frame(width: 78, alignment: .trailing)
            }
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Color(white: 0.45))
            .padding(.bottom, 4)

            Rectangle().fill(Color(white: 0.8)).frame(height: 0.5)

            ForEach(Array(content.lines.enumerated()), id: \.element.id) { offset, line in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(content.firstLineNumber + offset)")
                            .frame(width: 16, alignment: .leading)
                            .foregroundStyle(Color(white: 0.5))
                        Text(line.name).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(line.quantity.rateString) \(UnitCode.label(for: line.unitCode))")
                            .frame(width: 54, alignment: .trailing)
                        Text(line.unitPrice.formatted(locale: locale))
                            .frame(width: 72, alignment: .trailing)
                        Text(line.vatCategory.requiresExemptionReason
                             ? line.vatCategory.rawValue : "\(line.vatRate.rateString)%")
                            .frame(width: 38, alignment: .trailing)
                        Text(line.netAmount.formatted(locale: locale))
                            .frame(width: 78, alignment: .trailing)
                            .monospacedDigit()
                    }
                    if !line.note.isEmpty {
                        Text(line.note)
                            .font(.system(size: 8))
                            .foregroundStyle(Color(white: 0.4))
                            .padding(.leading, 24)
                    }
                    if let discount = line.discount, !discount.isZero {
                        Text("includes discount of \(discount.formatted(locale: locale))")
                            .font(.system(size: 8))
                            .foregroundStyle(Color(white: 0.4))
                            .padding(.leading, 24)
                    }
                }
                .padding(.vertical, 3)
                Rectangle().fill(Color(white: 0.92)).frame(height: 0.5)
            }
        }
    }

    private var totalsBlock: some View {
        HStack(alignment: .top) {
            // The exemption reason belongs next to the totals, where the reader looks
            // for the tax. It is a legal requirement, not a footnote.
            VStack(alignment: .leading, spacing: 3) {
                ForEach(totals.breakdown.compactMap(\.exemptionReason), id: \.self) { reason in
                    Text(reason).font(.system(size: 9, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                amountRow("Subtotal", totals.lineTotal)
                ForEach(totals.breakdown, id: \.self) { row in
                    if !row.category.requiresExemptionReason {
                        amountRow("VAT \(row.rate.rateString)% on \(row.taxableBase.formatted(locale: locale))",
                                  row.taxAmount)
                    }
                }
                Rectangle().fill(Color(white: 0.8)).frame(width: 220, height: 0.5).padding(.vertical, 2)
                amountRow("Total", totals.grandTotal, emphasised: true)
                if !totals.prepaid.isZero {
                    amountRow("Already paid", totals.prepaid)
                    amountRow("Amount due", totals.duePayable, emphasised: true)
                }
            }
        }
    }

    private var paymentBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !document.paymentTerms.isEmpty {
                Text(document.paymentTerms).font(.system(size: 9, weight: .medium))
            }
            if !document.bank.isEmpty {
                Text("\(document.bank.accountName) · IBAN \(document.bank.iban)"
                     + (document.bank.bic.isEmpty ? "" : " · BIC \(document.bank.bic)"))
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.3))
            }
        }
        .padding(.top, 4)
    }

    private var footer: some View {
        HStack {
            Text(document.seller.name).font(.system(size: 8))
            Spacer()
            if content.pageCount > 1 {
                Text("Page \(content.pageNumber) of \(content.pageCount)").font(.system(size: 8))
            }
        }
        .foregroundStyle(Color(white: 0.5))
    }

    // MARK: Pieces

    private func labelled(_ caption: String, _ value: String, emphasised: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(caption).font(.system(size: 8)).foregroundStyle(Color(white: 0.45))
            Text(value).font(.system(size: emphasised ? 11 : 9,
                                     weight: emphasised ? .semibold : .regular))
        }
    }

    private func amountRow(_ caption: String, _ value: Money, emphasised: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(caption)
                .font(.system(size: emphasised ? 10 : 9,
                              weight: emphasised ? .semibold : .regular))
            Text(value.formatted(locale: locale))
                .font(.system(size: emphasised ? 12 : 10,
                              weight: emphasised ? .bold : .regular))
                .monospacedDigit()
                .frame(width: 88, alignment: .trailing)
        }
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }
}
