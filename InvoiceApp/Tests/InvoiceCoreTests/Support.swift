import Foundation
import XCTest
@testable import InvoiceCore

/// The invoice the committed fixture (Fixtures/reference-invoice.xml) describes.
/// Deliberately awkward: a fractional quantity, a line discount, and a VAT rate that
/// does not divide cleanly, so the rounding points are exercised rather than assumed.
enum Reference {
    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    static var seller: TradeParty {
        TradeParty(
            name: "Ada Consulting GmbH",
            contactName: "Ada Lovelace",
            email: "billing@ada.example",
            phone: "+49 30 123456",
            address: PostalAddress(line1: "Chausseestr. 12", city: "Berlin",
                                   postcode: "10115", countryCode: "DE"),
            vatID: "DE123456789",
            taxRegistrationID: "30/123/45678",
            legalRegistrationID: "HRB 12345")
    }

    static var buyer: TradeParty {
        TradeParty(
            name: "Atelier Dupont SARL",
            contactName: "Marie Dupont",
            email: "compta@dupont.example",
            address: PostalAddress(line1: "24 Rue de la Roquette", city: "Paris",
                                   postcode: "75011", countryCode: "FR"),
            vatID: "FR40303265045")
    }

    static var invoice: InvoiceDocument {
        InvoiceDocument(
            number: "INV-2026-0007",
            issueDate: date(2026, 1, 15),
            dueDate: date(2026, 2, 14),
            deliveryDate: date(2026, 1, 12),
            currency: .eur,
            seller: seller,
            buyer: buyer,
            lines: [
                InvoiceLine(name: "Interface design", quantity: Decimal(string: "7.5")!,
                            unitCode: "HUR", unitPrice: Money(Decimal(string: "95.00")!, .eur),
                            vatCategory: .standard, vatRate: 19,
                            discount: Money(Decimal(string: "12.55")!, .eur)),
                InvoiceLine(name: "Research workshop", quantity: 1, unitCode: "C62",
                            unitPrice: Money(Decimal(string: "1200.00")!, .eur),
                            vatCategory: .standard, vatRate: 19),
            ],
            paymentMeans: .creditTransfer,
            bank: BankDetails(accountName: "Ada Consulting GmbH",
                              iban: "DE89370400440532013000", bic: "COBADEFFXXX"),
            paymentTerms: "Net 30 days",
            notes: "Thank you for your business.",
            buyerReference: "PO-44182",
            prepaidAmount: Money(Decimal(string: "500.00")!, .eur))
    }
}

/// Where the committed fixture lives at runtime.
///
/// `Bundle.module` is synthesised by SwiftPM and does not exist when these same files are
/// compiled by the Xcode test target, so the lookup has to branch on which built them.
/// SwiftPM defines SWIFT_PACKAGE; Xcode does not.
enum Fixtures {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return Bundle(for: ElementPathCollector.self)
        #endif
    }

    /// Loads a fixture, tolerating either layout: SwiftPM's `.copy` preserves the
    /// Fixtures/ directory, while Xcode flattens resources into the bundle root.
    static func text(_ name: String, extension ext: String) throws -> String {
        let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext)
        guard let url else {
            throw XCTSkip("fixture \(name).\(ext) is not in \(bundle.bundlePath)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// Collects element paths in document order, so a test can assert on CII sequence.
/// Order is load-bearing in CII: right elements in the wrong order fail validation.
final class ElementPathCollector: NSObject, XMLParserDelegate {
    private(set) var paths: [String] = []
    private(set) var texts: [String: String] = [:]
    private var stack: [String] = []
    private var current = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        stack.append(name)
        paths.append(stack.joined(separator: "/"))
        current = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        let path = stack.joined(separator: "/")
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, texts[path] == nil { texts[path] = trimmed }
        stack.removeLast()
        current = ""
    }

    static func parse(_ xml: String) throws -> ElementPathCollector {
        let collector = ElementPathCollector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        guard parser.parse() else {
            throw NSError(domain: "xml", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        parser.parserError?.localizedDescription ?? "parse failed"])
        }
        return collector
    }
}

/// A minimal PDF with a classic cross-reference table, standing in for a Core Graphics
/// rendering. Built by hand so the attacher tests do not need AppKit.
enum MinimalPDF {
    static func make() -> Data {
        let objects: [(Int, String)] = [
            (1, "<< /Type /Catalog /Pages 2 0 R >>"),
            (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            (3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> >>"),
        ]
        var out = Data("%PDF-1.4\n".utf8)
        var offsets: [Int: Int] = [:]
        for (number, body) in objects {
            offsets[number] = out.count
            out.append(Data("\(number) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for (number, _) in objects {
            table += String(format: "%010d 00000 n \n", offsets[number]!)
        }
        out.append(Data(table.utf8))
        out.append(Data("""
        trailer
        << /Size \(objects.count + 1) /Root 1 0 R /ID [<deadbeef> <deadbeef>] >>
        startxref
        \(xref)
        %%EOF

        """.utf8))
        return out
    }

    /// The same document but with the xref replaced by something that looks like a
    /// cross-reference stream, to prove the attacher refuses rather than corrupts.
    static func withCrossReferenceStream() -> Data {
        var out = Data("%PDF-1.5\n1 0 obj\n<< /Type /Catalog >>\nendobj\n".utf8)
        let offset = out.count
        out.append(Data("2 0 obj\n<< /Type /XRef /Size 3 /Root 1 0 R /W [1 2 1] >>\nstream\nxx\nendstream\nendobj\n".utf8))
        out.append(Data("startxref\n\(offset)\n%%EOF\n".utf8))
        return out
    }
}
