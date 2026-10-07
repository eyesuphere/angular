import XCTest
@testable import InvoiceCore

final class ValidationTests: XCTestCase {
    private let validator = InvoiceValidator()

    func testReferenceInvoicePassesWithoutErrors() {
        let issues = validator.validate(Reference.invoice)
        let errors = issues.filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty, "unexpected errors: \(errors.map(\.message))")
        XCTAssertFalse(validator.blocksExport(issues))
    }

    func testMissingPartyDetailsAreErrors() {
        var invoice = Reference.invoice
        invoice.seller.name = ""
        invoice.buyer.address.countryCode = ""
        let rules = Set(validator.validate(invoice).map(\.rule))
        XCTAssertTrue(rules.contains("BR-06"))
        XCTAssertTrue(rules.contains("BR-11"))
    }

    func testEmptyInvoiceIsRejected() {
        let invoice = InvoiceDocument(number: "X", seller: Reference.seller, buyer: Reference.buyer)
        XCTAssertTrue(validator.validate(invoice).contains { $0.rule == "BR-16" })
    }

    /// Reverse charge without both VAT numbers is the single most common rejection for
    /// a freelancer billing across an EU border.
    func testReverseChargeNeedsBothVATNumbers() {
        var invoice = Reference.invoice
        invoice.lines = [InvoiceLine(name: "work", unitPrice: Money(500, .eur),
                                     vatCategory: .reverseCharge)]
        invoice.seller.vatID = ""
        invoice.buyer.vatID = ""
        let rules = Set(validator.validate(invoice).map(\.rule))
        XCTAssertTrue(rules.contains("BR-AE-02"))
        XCTAssertTrue(rules.contains("BR-AE-03"))
    }

    func testUntaxedCategoryWithANonZeroRateIsAnError() {
        var invoice = Reference.invoice
        invoice.lines = [InvoiceLine(name: "work", unitPrice: Money(100, .eur),
                                     vatCategory: .exempt, vatRate: 19)]
        XCTAssertTrue(validator.validate(invoice).contains { $0.rule == "BR-E-05" })
    }

    func testChargingVATWithoutAVATNumberIsAnError() {
        var invoice = Reference.invoice
        invoice.seller.vatID = ""
        invoice.seller.taxRegistrationID = ""
        XCTAssertTrue(validator.validate(invoice).contains { $0.rule == "BR-S-02" })
    }

    func testMixedCurrencyLineIsAnError() {
        var invoice = Reference.invoice
        invoice.lines.append(InvoiceLine(name: "in dollars", unitPrice: Money(10, .usd),
                                         vatCategory: .standard, vatRate: 19))
        XCTAssertTrue(validator.validate(invoice).contains { $0.rule == "BR-CL-05" })
    }

    func testBankTransferRequiresAnIBAN() {
        var invoice = Reference.invoice
        invoice.bank = BankDetails()
        XCTAssertTrue(validator.validate(invoice).contains { $0.rule == "BR-61" })
    }

    func testCreditNoteMustReferenceAnInvoice() {
        var invoice = Reference.invoice
        invoice.kind = .creditNote
        XCTAssertTrue(validator.validate(invoice).contains { $0.rule == "BR-55" })
        invoice.precedingInvoiceNumber = "INV-2026-0006"
        XCTAssertFalse(validator.validate(invoice).contains { $0.rule == "BR-55" })
    }

    func testNonCompliantProfileWarns() {
        let issues = validator.validate(Reference.invoice, profile: .minimum)
        XCTAssertTrue(issues.contains { $0.severity == .warning && $0.message.contains("MINIMUM") })
        // A warning must not block the export.
        XCTAssertFalse(validator.blocksExport(issues))
    }

    func testIBANChecksum() {
        XCTAssertTrue(IBAN.isPlausible("DE89 3704 0044 0532 0130 00"))
        XCTAssertTrue(IBAN.isPlausible("FR1420041010050500013M02606"))
        XCTAssertTrue(IBAN.isPlausible("GB82WEST12345698765432"))
        // A single transposed digit must fail.
        XCTAssertFalse(IBAN.isPlausible("DE89370400440532013001"))
        XCTAssertFalse(IBAN.isPlausible("nonsense"))
        XCTAssertFalse(IBAN.isPlausible("DE89"))
    }
}
