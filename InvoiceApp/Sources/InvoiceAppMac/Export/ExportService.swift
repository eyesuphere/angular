import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InvoiceCore

/// Turns an invoice into a file on disk.
@MainActor
struct ExportService {
    enum Format: String, CaseIterable, Identifiable {
        /// A plain PDF. Fine for a domestic invoice today, and nothing more.
        case pdf
        /// A Factur-X / ZUGFeRD hybrid: the same PDF with EN 16931 XML embedded. This
        /// is what the French and German mandates require, and what a buyer's platform
        /// can actually read without a human retyping it.
        case facturX
        /// The bare XML, for an accountant or a platform that ingests it directly.
        case xml

        var id: String { rawValue }

        var label: String {
            switch self {
            case .pdf: return "PDF"
            case .facturX: return "Factur-X PDF (e-invoice)"
            case .xml: return "Factur-X XML only"
            }
        }

        var contentType: UTType { self == .xml ? .xml : .pdf }
        var fileExtension: String { self == .xml ? "xml" : "pdf" }
    }

    struct Outcome {
        let url: URL
        let format: Format
        let warnings: [String]
    }

    let document: InvoiceDocument
    let logo: NSImage?
    let profile: FacturXProfile
    let pageSize: InvoicePDFRenderer.PageSize
    let locale: Locale
    /// An sRGB ICC profile from the app bundle, when one is shipped. Without it the
    /// output carries the Factur-X payload but does not declare PDF/A-3.
    let iccProfile: Data?

    init(document: InvoiceDocument, logo: NSImage? = nil, profile: FacturXProfile = .en16931,
         pageSize: InvoicePDFRenderer.PageSize = .usLetter, locale: Locale = .current,
         iccProfile: Data? = ExportService.bundledSRGBProfile()) {
        self.document = document
        self.logo = logo
        self.profile = profile
        self.pageSize = pageSize
        self.locale = locale
        self.iccProfile = iccProfile
    }

    /// Looks for an sRGB profile shipped in the bundle. Returning nil is not an error;
    /// it only downgrades the PDF/A claim, which `Outcome.warnings` then reports.
    static func bundledSRGBProfile() -> Data? {
        guard let url = Bundle.main.url(forResource: "sRGB-IEC61966-2.1", withExtension: "icc")
        else { return nil }
        return try? Data(contentsOf: url)
    }

    func data(for format: Format) throws -> (Data, [String]) {
        let builder = FacturXBuilder(profile: profile)
        switch format {
        case .xml:
            return (builder.xmlData(for: document), [])

        case .pdf:
            let pdf = try InvoicePDFRenderer(document: document, logo: logo,
                                             locale: locale, pageSize: pageSize).render()
            return (pdf, [])

        case .facturX:
            let pdf = try InvoicePDFRenderer(document: document, logo: logo,
                                             locale: locale, pageSize: pageSize).render()
            let attacher = FacturXPDFAttacher(
                profile: profile, iccProfile: iccProfile,
                documentTitle: "\(document.kind == .creditNote ? "Credit note" : "Invoice") \(document.number)",
                documentAuthor: document.seller.name)
            let result = try attacher.attach(xml: builder.xmlData(for: document), to: pdf)
            return (result.data, result.warnings)
        }
    }

    /// Asks for a destination, then writes. The save panel runs before any rendering so
    /// a cancelled export does no work.
    func save(format: Format) throws -> Outcome? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(sanitise(document.number)).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let (bytes, warnings) = try data(for: format)
        // Atomic: a crash mid-write must not leave a truncated invoice where the old
        // one was.
        try bytes.write(to: url, options: .atomic)
        return Outcome(url: url, format: format, warnings: warnings)
    }

    /// An invoice number can legitimately contain "/", which is a path separator.
    private func sanitise(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "invoice" : cleaned
    }
}
