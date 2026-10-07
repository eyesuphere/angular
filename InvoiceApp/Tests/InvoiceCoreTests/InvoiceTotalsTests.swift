import XCTest
@testable import InvoiceCore

final class InvoiceTotalsTests: XCTestCase {
    /// These figures are the ones in the committed reference fixture, cross-checked
    /// independently: 7.5 × 95.00 = 712.50, less 12.55 = 699.95; plus 1200.00 = 1899.95;
    /// 19% of that is 360.9905, which rounds to 360.99.
    func testReferenceInvoiceTotals() {
        let totals = Reference.invoice.totals
        XCTAssertEqual(totals.lineTotal.xmlValue, "1899.95")
        XCTAssertEqual(totals.taxBasisTotal.xmlValue, "1899.95")
        XCTAssertEqual(totals.taxTotal.xmlValue, "360.99")
        XCTAssertEqual(totals.grandTotal.xmlValue, "2260.94")
        XCTAssertEqual(totals.prepaid.xmlValue, "500.00")
        XCTAssertEqual(totals.duePayable.xmlValue, "1760.94")
    }

    /// EN 16931 requires VAT on the rounded *group* base, not the sum of per-line VAT.
    /// Three lines of 0.025 each round to 0.03, so the group base is 0.09 and VAT is
    /// 0.0171 -> 0.02. Computing VAT per line would give 0.00 three times and a total
    /// that contradicts the breakdown. That mismatch is what validators reject.
    func testVATIsComputedOnTheGroupBaseNotPerLine() {
        let penny = Money(Decimal(string: "0.025")!, .eur)
        let invoice = InvoiceDocument(
            number: "T", currency: .eur,
            lines: (0..<3).map { _ in
                InvoiceLine(name: "x", quantity: 1, unitPrice: penny,
                            vatCategory: .standard, vatRate: 19)
            })
        let totals = invoice.totals
        // Each line net rounds to 0.03, so the base is 0.09 and VAT is 0.0171 -> 0.02.
        XCTAssertEqual(totals.lineTotal.xmlValue, "0.09")
        XCTAssertEqual(totals.taxTotal.xmlValue, "0.02")
        XCTAssertEqual(totals.grandTotal.xmlValue, "0.11")
    }

    func testBreakdownGroupsByCategoryAndRate() {
        let invoice = InvoiceDocument(
            number: "T", currency: .eur,
            lines: [
                InvoiceLine(name: "a", unitPrice: Money(100, .eur), vatCategory: .standard, vatRate: 19),
                InvoiceLine(name: "b", unitPrice: Money(200, .eur), vatCategory: .standard, vatRate: 19),
                InvoiceLine(name: "c", unitPrice: Money(50, .eur), vatCategory: .standard, vatRate: 7),
                InvoiceLine(name: "d", unitPrice: Money(10, .eur), vatCategory: .exempt),
            ])
        let rows = invoice.totals.breakdown
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].taxableBase.xmlValue, "300.00")
        XCTAssertEqual(rows[0].taxAmount.xmlValue, "57.00")
        XCTAssertEqual(rows[1].taxableBase.xmlValue, "50.00")
        XCTAssertEqual(rows[1].taxAmount.xmlValue, "3.50")
        XCTAssertEqual(rows[2].category, .exempt)
        XCTAssertEqual(rows[2].taxAmount.xmlValue, "0.00")
    }

    /// Breakdown order follows first appearance, because it is printed on the page and
    /// a dictionary's order would shuffle between runs.
    func testBreakdownOrderIsStable() {
        let invoice = InvoiceDocument(
            number: "T", currency: .eur,
            lines: [
                InvoiceLine(name: "a", unitPrice: Money(10, .eur), vatCategory: .standard, vatRate: 7),
                InvoiceLine(name: "b", unitPrice: Money(10, .eur), vatCategory: .standard, vatRate: 19),
                InvoiceLine(name: "c", unitPrice: Money(10, .eur), vatCategory: .standard, vatRate: 7),
            ])
        let rates = invoice.totals.breakdown.map(\.rate)
        XCTAssertEqual(rates, [Decimal(7), Decimal(19)])
        XCTAssertEqual(invoice.totals.breakdown[0].taxableBase.xmlValue, "20.00")
    }

    /// A category that charges no VAT must force the rate to zero even if the editor
    /// left a stale rate behind, otherwise the XML contradicts itself.
    func testUntaxedCategoryForcesZeroRate() {
        let invoice = InvoiceDocument(
            number: "T", currency: .eur,
            lines: [InvoiceLine(name: "a", unitPrice: Money(1000, .eur),
                                vatCategory: .reverseCharge, vatRate: 19)])
        let totals = invoice.totals
        XCTAssertEqual(totals.breakdown[0].rate, .zero)
        XCTAssertEqual(totals.taxTotal.xmlValue, "0.00")
        XCTAssertEqual(totals.grandTotal.xmlValue, "1000.00")
        XCTAssertTrue(totals.isWhollyUntaxed)
        XCTAssertNotNil(totals.breakdown[0].exemptionReason)
    }

    func testLineDiscountReducesNet() {
        let line = InvoiceLine(name: "a", quantity: 2, unitPrice: Money(100, .eur),
                               vatCategory: .standard, vatRate: 0,
                               discount: Money(Decimal(string: "15.50")!, .eur))
        XCTAssertEqual(line.netAmount.xmlValue, "184.50")
    }

    func testEmptyInvoiceHasZeroTotals() {
        let totals = InvoiceDocument(number: "T", currency: .eur).totals
        XCTAssertEqual(totals.grandTotal.xmlValue, "0.00")
        XCTAssertTrue(totals.breakdown.isEmpty)
        XCTAssertFalse(totals.isWhollyUntaxed)
    }
}
