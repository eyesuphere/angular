import XCTest
@testable import InvoiceCore

final class FacturXPDFAttacherTests: XCTestCase {
    private let xml = Data("<?xml version=\"1.0\"?><rsm:CrossIndustryInvoice/>".utf8)

    private func attach(icc: Data? = nil) throws -> FacturXPDFAttacher.Result {
        try FacturXPDFAttacher(profile: .en16931, iccProfile: icc, documentTitle: "INV-2026-0007")
            .attach(xml: xml, to: MinimalPDF.make())
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// An incremental update appends; it must never rewrite what was already there.
    func testOriginalBytesArePreserved() throws {
        let original = MinimalPDF.make()
        let result = try FacturXPDFAttacher().attach(xml: xml, to: original)
        XCTAssertTrue(result.data.starts(with: original))
        XCTAssertGreaterThan(result.data.count, original.count)
    }

    func testPayloadIsEmbeddedVerbatim() throws {
        let output = text(try attach().data)
        XCTAssertTrue(output.contains("/Type /EmbeddedFile"))
        XCTAssertTrue(output.contains("/Subtype /text#2Fxml"))
        XCTAssertTrue(output.contains("<?xml version=\"1.0\"?><rsm:CrossIndustryInvoice/>"))
        XCTAssertTrue(output.contains("/Length \(xml.count)"))
    }

    /// Factur-X requires this exact filename and this relationship; a reader looks for
    /// both and ignores an attachment that has either wrong.
    func testFileSpecificationFollowsTheStandard() throws {
        let output = text(try attach().data)
        XCTAssertTrue(output.contains("/F (factur-x.xml)"))
        XCTAssertTrue(output.contains("/UF (factur-x.xml)"))
        XCTAssertTrue(output.contains("/AFRelationship /Data"))
    }

    /// The payload must be reachable both ways: through /AF, which PDF/A-3 requires,
    /// and through the EmbeddedFiles name tree, which is how most readers find it.
    func testCatalogueGainsBothReferencePaths() throws {
        let output = text(try attach().data)
        XCTAssertTrue(output.contains("/AF ["))
        XCTAssertTrue(output.contains("/Names << /EmbeddedFiles << /Names [(factur-x.xml)"))
        XCTAssertTrue(output.contains("/Metadata "))
    }

    /// Splicing must preserve the original catalogue keys. Losing /Pages here produces
    /// a file that no longer has any pages.
    func testOriginalCatalogueKeysSurvive() throws {
        let output = text(try attach().data)
        guard let last = output.range(of: "1 0 obj", options: .backwards) else {
            return XCTFail("replacement catalogue not found")
        }
        let replacement = output[last.lowerBound...]
        XCTAssertTrue(replacement.contains("/Type /Catalog"))
        XCTAssertTrue(replacement.contains("/Pages 2 0 R"))
    }

    func testTrailerChainsToThePreviousCrossReferenceTable() throws {
        let output = text(try attach().data)
        XCTAssertTrue(output.contains("/Prev "))
        XCTAssertTrue(output.contains("/Root 1 0 R"))
        // The original /ID must be carried over; PDF/A requires one.
        XCTAssertTrue(output.contains("/ID [<deadbeef> <deadbeef>]"))
        XCTAssertTrue(output.hasSuffix("%%EOF"))
    }

    /// startxref must point at the literal "xref" keyword of the section we appended.
    /// If this is off by even one byte, readers fall back to repair mode or fail.
    func testStartxrefPointsAtTheNewTable() throws {
        let data = try attach().data
        let output = text(data)
        guard let marker = output.range(of: "startxref", options: .backwards) else {
            return XCTFail("no startxref")
        }
        let tail = output[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let offset = Int(tail.prefix { $0.isNumber }) else { return XCTFail("unreadable offset") }
        XCTAssertLessThan(offset, data.count)
        let atOffset = String(decoding: data[offset..<min(data.count, offset + 4)], as: UTF8.self)
        XCTAssertEqual(atOffset, "xref")
    }

    /// Every xref entry is exactly 20 bytes. This is the detail that silently breaks
    /// a PDF, because most viewers repair it and only strict validators complain.
    func testXrefEntriesAreExactlyTwentyBytes() {
        let section = FacturXPDFAttacher.xrefSection(offsets: [4: 100, 5: 200, 6: 300])
        let lines = section.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "xref")
        XCTAssertEqual(lines[1], "4 3")
        for entry in lines[2...4] {
            XCTAssertEqual(entry.count + 1, 20, "entry '\(entry)' is not 20 bytes")
        }
    }

    /// Non-contiguous object numbers must be split into separate subsections, in
    /// ascending order.
    func testXrefSplitsNonContiguousRuns() {
        let section = FacturXPDFAttacher.xrefSection(offsets: [1: 10, 7: 70, 8: 80])
        let lines = section.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "xref")
        XCTAssertEqual(lines[1], "1 1")
        XCTAssertEqual(lines[3], "7 2")
    }

    func testOutputIntentOnlyAppearsWithAnICCProfile() throws {
        let without = try attach()
        XCTAssertFalse(text(without.data).contains("/OutputIntent"))
        XCTAssertFalse(without.declaresPDFA3Conformance)
        XCTAssertFalse(without.warnings.isEmpty)

        let with = try attach(icc: Data(repeating: 0, count: 128))
        XCTAssertTrue(text(with.data).contains("/Type /OutputIntent"))
        XCTAssertTrue(text(with.data).contains("/S /GTS_PDFA1"))
        XCTAssertTrue(with.declaresPDFA3Conformance)
    }

    func testXMPDeclaresProfileAndPayloadName() throws {
        let output = text(try attach(icc: Data(repeating: 0, count: 4)).data)
        XCTAssertTrue(output.contains("<pdfaid:part>3</pdfaid:part>"))
        XCTAssertTrue(output.contains("<pdfaid:conformance>B</pdfaid:conformance>"))
        XCTAssertTrue(output.contains("<fx:ConformanceLevel>EN 16931</fx:ConformanceLevel>"))
        XCTAssertTrue(output.contains("<fx:DocumentFileName>factur-x.xml</fx:DocumentFileName>"))
        // A validator rejects XMP using a namespace it was not told about.
        XCTAssertTrue(output.contains("pdfaExtension:schemas"))
    }

    func testXMPEscapesTheTitle() throws {
        let result = try FacturXPDFAttacher(documentTitle: "Smith & Sons <Ltd>")
            .attach(xml: xml, to: MinimalPDF.make())
        XCTAssertTrue(text(result.data).contains("Smith &amp; Sons &lt;Ltd&gt;"))
    }

    // MARK: Refusals

    func testRejectsNonPDFInput() {
        XCTAssertThrowsError(try FacturXPDFAttacher().attach(xml: xml, to: Data("not a pdf".utf8))) {
            XCTAssertEqual($0 as? FacturXPDFAttacher.AttachError, .notAPDF)
        }
    }

    /// Corrupting a file we cannot fully parse is far worse than refusing it.
    func testRejectsCrossReferenceStreams() {
        XCTAssertThrowsError(
            try FacturXPDFAttacher().attach(xml: xml, to: MinimalPDF.withCrossReferenceStream())
        ) {
            XCTAssertEqual($0 as? FacturXPDFAttacher.AttachError, .unsupportedCrossReferenceStream)
        }
    }

    /// Two payloads in one file is an invalid Factur-X invoice, and a reader would pick
    /// one arbitrarily. Refuse instead.
    func testRefusesToAttachTwice() throws {
        let once = try attach().data
        XCTAssertThrowsError(try FacturXPDFAttacher().attach(xml: xml, to: once)) {
            XCTAssertEqual($0 as? FacturXPDFAttacher.AttachError, .catalogAlreadyHasAttachments)
        }
    }

    func testRejectsAMissingStartxref() {
        let broken = Data("%PDF-1.4\n1 0 obj\n<< >>\nendobj\n".utf8)
        XCTAssertThrowsError(try FacturXPDFAttacher().attach(xml: xml, to: broken)) {
            XCTAssertEqual($0 as? FacturXPDFAttacher.AttachError, .missingStartxref)
        }
    }

    // MARK: Dictionary scanning

    /// A ">>" inside a literal string must not close the dictionary early. A filename
    /// in a /Desc is exactly where this bites.
    func testBalancedDictionaryIgnoresDelimitersInsideStrings() {
        let data = Data("<< /Desc (a >> b) /Next << /Inner 1 >> >>trailing".utf8)
        guard let range = PDFStructure.balancedDictionary(in: data, from: 0) else {
            return XCTFail("no dictionary found")
        }
        XCTAssertEqual(String(decoding: data[range], as: UTF8.self),
                       "<< /Desc (a >> b) /Next << /Inner 1 >> >>")
    }

    func testBalancedDictionaryHandlesEscapedParentheses() {
        let data = Data("<< /Desc (a \\) >> b) >>".utf8)
        guard let range = PDFStructure.balancedDictionary(in: data, from: 0) else {
            return XCTFail("no dictionary found")
        }
        XCTAssertEqual(range.upperBound, data.count)
    }

    func testTrailerValueParsing() {
        let trailer = "<< /Size 12 /Root 3 0 R /ID [<aa> <bb>] /Prev 99 >>"
        XCTAssertEqual(PDFStructure.integer(named: "/Size", in: trailer), 12)
        XCTAssertEqual(PDFStructure.indirectReference(named: "/Root", in: trailer), 3)
        XCTAssertEqual(PDFStructure.arrayValue(named: "/ID", in: trailer), "[<aa> <bb>]")
        XCTAssertNil(PDFStructure.indirectReference(named: "/Missing", in: trailer))
    }
}
