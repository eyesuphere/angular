import Foundation

/// One row of the VAT breakdown (BG-23). EN 16931 requires one per distinct
/// category-and-rate pair, and the document total must equal the sum of these.
public struct VATBreakdownRow: Hashable, Sendable {
    public let category: VATCategory
    public let rate: Decimal
    /// Sum of the line nets in this group (BT-116).
    public let taxableBase: Money
    /// VAT on that base (BT-117).
    public let taxAmount: Money
    public let exemptionReason: String?
}

/// The EN 16931 calculation model.
///
/// The order of rounding is not an implementation detail; it is specified. Each line
/// net is rounded, those are summed per VAT group, VAT is computed on the *rounded
/// group base* and then rounded, and the document total is the sum of rounded parts.
/// Computing VAT per line and summing instead produces off-by-a-cent totals that
/// validators reject.
public struct InvoiceTotals: Hashable, Sendable {
    public let currency: Currency
    /// BT-106: sum of line net amounts.
    public let lineTotal: Money
    /// BT-109: the amount VAT is calculated on.
    public let taxBasisTotal: Money
    /// BT-110: total VAT.
    public let taxTotal: Money
    /// BT-112: total including VAT.
    public let grandTotal: Money
    /// BT-113: already paid.
    public let prepaid: Money
    /// BT-115: what the buyer still owes.
    public let duePayable: Money
    public let breakdown: [VATBreakdownRow]

    public init(_ invoice: InvoiceDocument) {
        let currency = invoice.currency
        self.currency = currency

        // Step 1: line nets, each already rounded by InvoiceLine.netAmount.
        let nets = invoice.lines.map(\.netAmount)
        let lineTotal = Money.sum(nets, currency: currency).rounded
        self.lineTotal = lineTotal

        // Step 2: group by (category, rate). A Dictionary would lose ordering, and the
        // breakdown is printed, so the first appearance of each group sets its position.
        var order: [(VATCategory, Decimal)] = []
        var bases: [String: Money] = [:]
        for line in invoice.lines {
            let key = Self.key(line.vatCategory, line.vatRate)
            if bases[key] == nil {
                order.append((line.vatCategory, line.vatRate))
                bases[key] = Money.zero(currency)
            }
            bases[key] = bases[key]! + line.netAmount
        }

        // Step 3: VAT per group, on the rounded group base.
        var rows: [VATBreakdownRow] = []
        for (category, rate) in order {
            let base = bases[Self.key(category, rate)]!.rounded
            let effectiveRate = category.requiresExemptionReason ? Decimal.zero : rate
            let tax = (base * (effectiveRate / 100)).rounded
            rows.append(VATBreakdownRow(
                category: category,
                rate: effectiveRate,
                taxableBase: base,
                taxAmount: tax,
                exemptionReason: invoice.exemptionReason(for: category)
            ))
        }
        self.breakdown = rows

        let taxBasis = Money.sum(rows.map(\.taxableBase), currency: currency).rounded
        let taxTotal = Money.sum(rows.map(\.taxAmount), currency: currency).rounded
        self.taxBasisTotal = taxBasis
        self.taxTotal = taxTotal

        let grand = (taxBasis + taxTotal).rounded
        self.grandTotal = grand

        let prepaid = (invoice.prepaidAmount ?? Money.zero(currency)).rounded
        self.prepaid = prepaid
        self.duePayable = (grand - prepaid).rounded
    }

    private static func key(_ category: VATCategory, _ rate: Decimal) -> String {
        "\(category.rawValue)|\(rate.rateString)"
    }

    /// True when every line is in a category that charges no VAT. The printed page
    /// then needs the exemption note prominently rather than a "VAT 0.00" row.
    public var isWhollyUntaxed: Bool {
        !breakdown.isEmpty && breakdown.allSatisfy { $0.category.requiresExemptionReason }
    }
}
