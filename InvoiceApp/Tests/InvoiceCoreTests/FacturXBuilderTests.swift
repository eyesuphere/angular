import XCTest
@testable import InvoiceCore

final class FacturXBuilderTests: XCTestCase {
    private let builder = FacturXBuilder(profile: .en16931)

    func testOutputIsWellFormed() throws {
        _ = try ElementPathCollector.parse(builder.xml(for: Reference.invoice))
    }

    func testGuidelineIdentifiesTheProfile() throws {
        let parsed = try ElementPathCollector.parse(builder.xml(for: Reference.invoice))
        XCTAssertEqual(
            parsed.texts["rsm:CrossIndustryInvoice/rsm:ExchangedDocumentContext/"
                + "ram:GuidelineSpecifiedDocumentContextParameter/ram:ID"],
            "urn:cen.eu:en16931:2017")
        XCTAssertEqual(
            FacturXBuilder(profile: .basic).xml(for: Reference.invoice)
                .contains("#compliant#urn:factur-x.eu:1p0:basic"), true)
    }

    /// CII is sequence-based: the right elements in the wrong order fail validation.
    /// This pins the order of the four top-level sections and of the monetary summation,
    /// which is where an accidental reordering would otherwise go unnoticed.
    func testTopLevelSectionOrder() throws {
        let parsed = try ElementPathCollector.parse(builder.xml(for: Reference.invoice))
        let top = parsed.paths
            .filter { $0.split(separator: "/").count == 2 }
            .map { String($0.split(separator: "/")[1]) }
        XCTAssertEqual(top, ["rsm:ExchangedDocumentContext", "rsm:ExchangedDocument",
                             "rsm:SupplyChainTradeTransaction"])

        let transactionChildren = parsed.paths
            .filter { $0.hasPrefix("rsm:CrossIndustryInvoice/rsm:SupplyChainTradeTransaction/") }
            .filter { $0.split(separator: "/").count == 3 }
            .map { String($0.split(separator: "/")[2]) }
        XCTAssertEqual(transactionChildren, [
            "ram:IncludedSupplyChainTradeLineItem",
            "ram:IncludedSupplyChainTradeLineItem",
            "ram:ApplicableHeaderTradeAgreement",
            "ram:ApplicableHeaderTradeDelivery",
            "ram:ApplicableHeaderTradeSettlement",
        ])
    }

    func testMonetarySummationOrderAndValues() throws {
        let xml = builder.xml(for: Reference.invoice)
        let parsed = try ElementPathCollector.parse(xml)
        let prefix = "rsm:CrossIndustryInvoice/rsm:SupplyChainTradeTransaction/"
            + "ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeSettlementHeaderMonetarySummation/"
        let order = parsed.paths.filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
        XCTAssertEqual(order, ["ram:LineTotalAmount", "ram:TaxBasisTotalAmount",
                               "ram:TaxTotalAmount", "ram:GrandTotalAmount",
                               "ram:TotalPrepaidAmount", "ram:DuePayableAmount"])
        XCTAssertEqual(parsed.texts[prefix + "ram:GrandTotalAmount"], "2260.94")
        XCTAssertEqual(parsed.texts[prefix + "ram:DuePayableAmount"], "1760.94")
        // TaxTotalAmount is the one amount that must carry a currencyID attribute.
        XCTAssertTrue(xml.contains("<ram:TaxTotalAmount currencyID=\"EUR\">360.99</ram:TaxTotalAmount>"))
    }

    func testPrepaidAmountIsOmittedWhenZero() {
        var invoice = Reference.invoice
        invoice.prepaidAmount = nil
        XCTAssertFalse(builder.xml(for: invoice).contains("TotalPrepaidAmount"))
    }

    func testLineItemsCarryPositionQuantityAndUnit() throws {
        let parsed = try ElementPathCollector.parse(builder.xml(for: Reference.invoice))
        let base = "rsm:CrossIndustryInvoice/rsm:SupplyChainTradeTransaction/"
            + "ram:IncludedSupplyChainTradeLineItem/"
        XCTAssertEqual(parsed.texts[base + "ram:AssociatedDocumentLineDocument/ram:LineID"], "1")
        XCTAssertEqual(parsed.texts[base + "ram:SpecifiedTradeProduct/ram:Name"], "Interface design")
        XCTAssertTrue(builder.xml(for: Reference.invoice)
            .contains("<ram:BilledQuantity unitCode=\"HUR\">7.5</ram:BilledQuantity>"))
    }

    func testLineDiscountIsWrittenAsAnAllowance() {
        let xml = builder.xml(for: Reference.invoice)
        XCTAssertTrue(xml.contains("<udt:Indicator>false</udt:Indicator>"))
        XCTAssertTrue(xml.contains("<ram:ActualAmount>12.55</ram:ActualAmount>"))
        XCTAssertTrue(xml.contains("<ram:LineTotalAmount>699.95</ram:LineTotalAmount>"))
    }

    func testPartyVATRegistrationsUseTheRightSchemes() {
        let xml = builder.xml(for: Reference.invoice)
        XCTAssertTrue(xml.contains("<ram:ID schemeID=\"VA\">DE123456789</ram:ID>"))
        XCTAssertTrue(xml.contains("<ram:ID schemeID=\"FC\">30/123/45678</ram:ID>"))
        XCTAssertTrue(xml.contains("<ram:ID schemeID=\"VA\">FR40303265045</ram:ID>"))
    }

    func testDatesUseTheCCYYMMDDQualifier() {
        let xml = builder.xml(for: Reference.invoice)
        XCTAssertTrue(xml.contains("<udt:DateTimeString format=\"102\">20260115</udt:DateTimeString>"))
        XCTAssertTrue(xml.contains("<udt:DateTimeString format=\"102\">20260112</udt:DateTimeString>"))
        XCTAssertTrue(xml.contains("<udt:DateTimeString format=\"102\">20260214</udt:DateTimeString>"))
    }

    /// An exemption reason must reach the document as a note, not only the tax breakdown:
    /// the buyer's accountant reads the note.
    func testExemptionReasonAppearsAsADocumentNote() throws {
        var invoice = Reference.invoice
        invoice.lines = [InvoiceLine(name: "consulting", unitPrice: Money(1000, .eur),
                                     vatCategory: .reverseCharge)]
        let xml = builder.xml(for: invoice)
        XCTAssertTrue(xml.contains("<ram:SubjectCode>TXD</ram:SubjectCode>"))
        XCTAssertTrue(xml.contains("VAT to be accounted for by the recipient"))
        XCTAssertTrue(xml.contains("<ram:ExemptionReason>"))
        XCTAssertTrue(xml.contains("<ram:CategoryCode>AE</ram:CategoryCode>"))
    }

    func testCustomExemptionReasonOverridesTheDefault() {
        var invoice = Reference.invoice
        invoice.lines = [InvoiceLine(name: "x", unitPrice: Money(10, .eur), vatCategory: .exempt)]
        invoice.exemptionReasons[.exempt] = "Kleinunternehmer nach §19 UStG"
        XCTAssertTrue(builder.xml(for: invoice).contains("Kleinunternehmer nach §19 UStG"))
    }

    /// A client called "Smith & Sons <Holdings>" must not produce broken XML. This is
    /// the kind of input that reaches an invoice from a paste.
    func testSpecialCharactersAreEscaped() throws {
        var invoice = Reference.invoice
        invoice.buyer.name = "Smith & Sons <Holdings> \"Ltd\""
        let xml = builder.xml(for: invoice)
        XCTAssertTrue(xml.contains("Smith &amp; Sons &lt;Holdings&gt;"))
        let parsed = try ElementPathCollector.parse(xml)
        XCTAssertEqual(
            parsed.texts["rsm:CrossIndustryInvoice/rsm:SupplyChainTradeTransaction/"
                + "ram:ApplicableHeaderTradeAgreement/ram:BuyerTradeParty/ram:Name"],
            "Smith & Sons <Holdings> \"Ltd\"")
    }

    /// A control character pasted into a description would make the XML unparseable,
    /// so it is dropped rather than escaped.
    func testControlCharactersAreStripped() throws {
        var invoice = Reference.invoice
        invoice.lines[0].name = "Design\u{0001}work"
        _ = try ElementPathCollector.parse(builder.xml(for: invoice))
        XCTAssertTrue(builder.xml(for: invoice).contains("Designwork"))
    }

    /// The BASIC WL and MINIMUM profiles carry no line detail by design.
    func testWithoutLinesProfilesOmitLineItems() {
        let xml = FacturXBuilder(profile: .basicWL).xml(for: Reference.invoice)
        XCTAssertFalse(xml.contains("IncludedSupplyChainTradeLineItem"))
        XCTAssertTrue(xml.contains("GrandTotalAmount"))
    }

    func testCreditNoteUsesTypeCode381AndReferencesTheInvoice() {
        var invoice = Reference.invoice
        invoice.kind = .creditNote
        invoice.precedingInvoiceNumber = "INV-2026-0006"
        let xml = builder.xml(for: invoice)
        XCTAssertTrue(xml.contains("<ram:TypeCode>381</ram:TypeCode>"))
        XCTAssertTrue(xml.contains("<ram:IssuerAssignedID>INV-2026-0006</ram:IssuerAssignedID>"))
    }

    /// The committed fixture is the human-readable reference for this mapping. It was
    /// checked for well-formedness and cross-field arithmetic outside the test suite;
    /// here we assert the generator agrees with it on every element path and value.
    func testAgreesWithCommittedFixture() throws {
        let expected = try ElementPathCollector.parse(
            try Fixtures.text("reference-invoice", extension: "xml"))
        let actual = try ElementPathCollector.parse(builder.xml(for: Reference.invoice))
        XCTAssertEqual(actual.paths, expected.paths, "element order diverged from the fixture")
        for (path, value) in expected.texts {
            XCTAssertEqual(actual.texts[path], value, "value mismatch at \(path)")
        }
    }
}
