import SwiftUI
import AppKit
import CoreGraphics
import InvoiceCore

/// Renders an invoice to PDF data, paginating the line items.
///
/// Two things the naive version gets wrong. First, it renders to a file URL, which
/// makes the bytes unavailable for the Factur-X attachment step; this renders to a
/// `CGDataConsumer` so the result is `Data` that can still be post-processed. Second,
/// it assumes one page, so an invoice with thirty lines silently loses most of them —
/// the clipped rows are gone from the customer's copy with no warning at all.
@MainActor
struct InvoicePDFRenderer {
    /// US Letter. A4 (595.28 × 841.89) is the other sensible default; the page size is
    /// a user setting rather than a constant because the two markets differ.
    enum PageSize {
        case usLetter, a4

        var rect: CGRect {
            switch self {
            case .usLetter: return CGRect(x: 0, y: 0, width: 612, height: 792)
            case .a4: return CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
            }
        }
    }

    enum RenderError: Error, LocalizedError {
        case couldNotCreateContext
        case nothingRendered

        var errorDescription: String? {
            switch self {
            case .couldNotCreateContext: return "The PDF context could not be created."
            case .nothingRendered: return "The invoice produced no pages."
            }
        }
    }

    let document: InvoiceDocument
    let logo: NSImage?
    let locale: Locale
    let pageSize: PageSize

    init(document: InvoiceDocument, logo: NSImage? = nil,
         locale: Locale = .current, pageSize: PageSize = .usLetter) {
        self.document = document
        self.logo = logo
        self.locale = locale
        self.pageSize = pageSize
    }

    /// How many line rows fit, which differs between the first page (which carries the
    /// addresses) and later ones. Deliberately conservative: a row that wraps to two
    /// lines still fits rather than pushing the totals off the page.
    private var rowsOnFirstPage: Int { 16 }
    private var rowsOnLaterPages: Int { 30 }

    func pages() -> [InvoicePDFPage.Content] {
        let lines = document.lines
        guard !lines.isEmpty else {
            return [InvoicePDFPage.Content(lines: [], firstLineNumber: 1, isFirst: true,
                                           isLast: true, pageNumber: 1, pageCount: 1)]
        }

        var chunks: [[InvoiceLine]] = []
        var remaining = lines[...]
        var isFirst = true
        while !remaining.isEmpty {
            let capacity = isFirst ? rowsOnFirstPage : rowsOnLaterPages
            chunks.append(Array(remaining.prefix(capacity)))
            remaining = remaining.dropFirst(capacity)
            isFirst = false
        }

        // The totals block needs room. If the final page is full, give the totals a page
        // of their own rather than letting them collide with the last row.
        let lastCapacity = chunks.count == 1 ? rowsOnFirstPage : rowsOnLaterPages
        let totalsRows = document.totals.breakdown.count + 4
        if let last = chunks.last, last.count + totalsRows > lastCapacity {
            chunks.append([])
        }

        var result: [InvoicePDFPage.Content] = []
        var lineNumber = 1
        for (index, chunk) in chunks.enumerated() {
            result.append(InvoicePDFPage.Content(
                lines: chunk,
                firstLineNumber: lineNumber,
                isFirst: index == 0,
                isLast: index == chunks.count - 1,
                pageNumber: index + 1,
                pageCount: chunks.count))
            lineNumber += chunk.count
        }
        return result
    }

    /// Renders every page into one in-memory PDF.
    func render() throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw RenderError.couldNotCreateContext
        }
        var box = pageSize.rect
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw RenderError.couldNotCreateContext
        }

        var rendered = 0
        for content in pages() {
            let view = InvoicePDFPage(document: document, content: content,
                                      logo: logo, locale: locale, size: box.size)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(box.size)

            // `render` invokes its closure synchronously, once per rendering. The guard
            // below is not about asynchrony: it catches the case where SwiftUI declines
            // to lay the content out at all, which would otherwise close an empty PDF.
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
                rendered += 1
            }
        }
        context.closePDF()

        guard rendered > 0, output.length > 0 else { throw RenderError.nothingRendered }
        return output as Data
    }
}
