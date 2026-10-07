import Foundation

/// Attaches the Factur-X XML to a finished PDF as a PDF/A-3 embedded file.
///
/// A Factur-X invoice is one file, not two: the XML lives *inside* the PDF, referenced
/// from the catalogue's `/AF` array and the `/Names /EmbeddedFiles` name tree, and the
/// XMP metadata declares both PDF/A-3 conformance and the Factur-X profile. A PDF with
/// the XML merely sitting next to it is not a Factur-X invoice and will be rejected.
///
/// The attachment is done as an *incremental update*: the original bytes are left
/// untouched and the new objects, a replacement catalogue, and a fresh cross-reference
/// section are appended. That avoids rewriting and possibly corrupting a PDF produced
/// by Core Graphics, and it is the lowest-risk way to add objects without a full PDF
/// parser.
///
/// Scope: this handles classic cross-reference *tables*, which is what Core Graphics
/// emits. A PDF using cross-reference *streams* (1.5+) is rejected rather than
/// corrupted — see `AttachError.unsupportedCrossReferenceStream`.
public struct FacturXPDFAttacher {
    public enum AttachError: Error, LocalizedError, Equatable {
        case notAPDF
        case missingStartxref
        case unsupportedCrossReferenceStream
        case malformedTrailer
        case missingCatalogReference
        case catalogNotFound(Int)
        case catalogAlreadyHasAttachments

        public var errorDescription: String? {
            switch self {
            case .notAPDF:
                return "That file does not start with a PDF header."
            case .missingStartxref:
                return "The PDF has no startxref, so its object table cannot be located."
            case .unsupportedCrossReferenceStream:
                return "This PDF uses a cross-reference stream, which this attacher does not write. "
                    + "Re-render the page with Core Graphics, which produces a classic table."
            case .malformedTrailer:
                return "The PDF trailer could not be read."
            case .missingCatalogReference:
                return "The PDF trailer has no /Root entry."
            case .catalogNotFound(let number):
                return "Object \(number), the document catalogue, was not found at its indexed offset."
            case .catalogAlreadyHasAttachments:
                return "This PDF already carries embedded files or XMP metadata. Attaching again "
                    + "would produce two invoice payloads in one file."
            }
        }
    }

    public struct Result: Sendable {
        public let data: Data
        /// Whether the file *declares* PDF/A-3 conformance (XMP pdfaid plus an output
        /// intent). Declaring it is not the same as being it: the base PDF must also
        /// satisfy PDF/A itself — all fonts embedded and subset, no transparency, no
        /// encryption — which a Core Graphics rendering does not guarantee. Treat this
        /// as "the Factur-X envelope is complete", and run a real PDF/A validator
        /// before relying on the claim.
        public let declaresPDFA3Conformance: Bool
        public let warnings: [String]
    }

    public let profile: FacturXProfile
    /// An sRGB ICC profile. PDF/A requires an OutputIntent, and an OutputIntent requires
    /// an embedded profile; there is no way to be conformant without shipping one.
    public let iccProfile: Data?
    public let documentTitle: String
    public let documentAuthor: String

    public init(profile: FacturXProfile = .en16931, iccProfile: Data? = nil,
                documentTitle: String = "Invoice", documentAuthor: String = "") {
        self.profile = profile
        self.iccProfile = iccProfile
        self.documentTitle = documentTitle
        self.documentAuthor = documentAuthor
    }

    public func attach(xml: Data, to pdf: Data, modified: Date = Date()) throws -> Result {
        guard pdf.starts(with: Data("%PDF-".utf8)) else { throw AttachError.notAPDF }

        let structure = try PDFStructure(pdf)
        let catalogBody = try structure.catalogDictionaryBody()
        if catalogBody.contains("/EmbeddedFiles") || catalogBody.contains("/Metadata") || catalogBody.contains("/AF ") {
            throw AttachError.catalogAlreadyHasAttachments
        }

        var warnings: [String] = []
        let embedICC = iccProfile != nil
        if !embedICC {
            warnings.append("No ICC profile was supplied, so no PDF/A output intent was written. "
                + "The Factur-X data is present and readable, but the file does not declare PDF/A-3.")
        } else {
            warnings.append("PDF/A-3 is declared, but conformance also depends on the rendered page "
                + "itself (embedded fonts, no transparency). Validate before relying on the claim.")
        }

        // Object numbers for what we are about to append.
        let firstNew = structure.size
        let embeddedFileObj = firstNew
        let filespecObj = firstNew + 1
        let metadataObj = firstNew + 2
        let iccObj = embedICC ? firstNew + 3 : nil
        let outputIntentObj = embedICC ? firstNew + 4 : nil
        let newSize = firstNew + (embedICC ? 5 : 3)

        var out = pdf
        // An incremental update must begin on its own line.
        if out.last != 0x0A { out.append(0x0A) }

        var offsets: [Int: Int] = [:]

        func appendObject(_ number: Int, _ body: Data) {
            offsets[number] = out.count
            out.append(Data("\(number) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }

        // 1. The XML payload, as an uncompressed embedded file stream.
        //    Uncompressed keeps the file inspectable and avoids a Flate dependency; an
        //    invoice XML is a few kilobytes, so there is nothing to gain by deflating it.
        var embedded = Data()
        embedded.append(Data("""
        << /Type /EmbeddedFile /Subtype /text#2Fxml \
        /Params << /ModDate (\(Self.pdfDate(modified))) /Size \(xml.count) >> \
        /Length \(xml.count) >>
        stream\n
        """.utf8))
        embedded.append(xml)
        embedded.append(Data("\nendstream".utf8))
        appendObject(embeddedFileObj, embedded)

        // 2. The file specification. /AFRelationship /Data is what Factur-X requires;
        //    /UF must be present for PDF/A-3 and carries the Unicode filename.
        let filename = FacturXBuilder.attachmentFilename
        appendObject(filespecObj, Data("""
        << /Type /Filespec /F (\(filename)) /UF (\(filename)) \
        /AFRelationship /Data \
        /Desc (Factur-X/ZUGFeRD \(profile.conformanceLevel) invoice data) \
        /EF << /F \(embeddedFileObj) 0 R /UF \(embeddedFileObj) 0 R >> >>
        """.utf8))

        // 3. XMP metadata. PDF/A conformance and the Factur-X profile are both declared
        //    here, and a reader uses fx:DocumentFileName to find the payload.
        let xmp = Data(Self.xmpMetadata(
            profile: profile, filename: filename, title: documentTitle,
            author: documentAuthor, modified: modified, pdfa: embedICC).utf8)
        var metadata = Data()
        metadata.append(Data("<< /Type /Metadata /Subtype /XML /Length \(xmp.count) >>\nstream\n".utf8))
        metadata.append(xmp)
        metadata.append(Data("\nendstream".utf8))
        appendObject(metadataObj, metadata)

        // 4. Output intent, only when we have a profile to point it at.
        if let iccObj, let outputIntentObj, let icc = iccProfile {
            var iccStream = Data()
            iccStream.append(Data("<< /N 3 /Length \(icc.count) >>\nstream\n".utf8))
            iccStream.append(icc)
            iccStream.append(Data("\nendstream".utf8))
            appendObject(iccObj, iccStream)

            appendObject(outputIntentObj, Data("""
            << /Type /OutputIntent /S /GTS_PDFA1 \
            /OutputConditionIdentifier (sRGB IEC61966-2.1) \
            /Info (sRGB IEC61966-2.1) \
            /DestOutputProfile \(iccObj) 0 R >>
            """.utf8))
        }

        // 5. The replacement catalogue: the original dictionary plus our keys.
        var catalogKeys = "/AF [\(filespecObj) 0 R] "
            + "/Names << /EmbeddedFiles << /Names [(\(filename)) \(filespecObj) 0 R] >> >> "
            + "/Metadata \(metadataObj) 0 R "
        if let outputIntentObj {
            catalogKeys += "/OutputIntents [\(outputIntentObj) 0 R] "
        }
        appendObject(structure.catalogNumber, Data("<< \(catalogKeys)\(catalogBody) >>".utf8))

        // 6. A new cross-reference section covering only what changed, then a trailer
        //    chained to the previous one via /Prev.
        let xrefOffset = out.count
        out.append(Data(Self.xrefSection(offsets: offsets).utf8))
        out.append(Data("""
        trailer
        << /Size \(newSize) /Root \(structure.catalogNumber) 0 R /Prev \(structure.previousXrefOffset)\
        \(structure.idEntry.map { " /ID \($0)" } ?? "") >>
        startxref
        \(xrefOffset)
        %%EOF
        """.utf8))

        return Result(data: out, declaresPDFA3Conformance: embedICC, warnings: warnings)
    }

    // MARK: - Serialisation helpers

    /// Builds the xref subsections. Entries must be exactly 20 bytes, and object
    /// numbers must ascend within and across subsections.
    static func xrefSection(offsets: [Int: Int]) -> String {
        var text = "xref\n"
        let numbers = offsets.keys.sorted()
        var index = 0
        while index < numbers.count {
            var end = index
            while end + 1 < numbers.count, numbers[end + 1] == numbers[end] + 1 { end += 1 }
            let run = numbers[index...end]
            text += "\(run.first!) \(run.count)\n"
            for number in run {
                text += String(format: "%010d %05d n \n", offsets[number]!, 0)
            }
            index = end + 1
        }
        return text
    }

    static func pdfDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "D:%04d%02d%02d%02d%02d%02dZ",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// The XMP packet. The Factur-X extension schema description is not decoration:
    /// a PDF/A validator rejects XMP that uses a namespace it has not been told about.
    static func xmpMetadata(profile: FacturXProfile, filename: String, title: String,
                            author: String, modified: Date, pdfa: Bool) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        let timestamp = iso.string(from: modified)
        let pdfaBlock = pdfa ? """

                <rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">
                    <pdfaid:part>3</pdfaid:part>
                    <pdfaid:conformance>B</pdfaid:conformance>
                </rdf:Description>
        """ : ""

        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\(pdfaBlock)
                <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(XMLWriter.escape(title))</rdf:li></rdf:Alt></dc:title>
                    <dc:creator><rdf:Seq><rdf:li>\(XMLWriter.escape(author))</rdf:li></rdf:Seq></dc:creator>
                </rdf:Description>
                <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
                    <xmp:CreatorTool>InvoiceApp</xmp:CreatorTool>
                    <xmp:ModifyDate>\(timestamp)</xmp:ModifyDate>
                </rdf:Description>
                <rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">
                    <pdfaExtension:schemas>
                        <rdf:Bag>
                            <rdf:li rdf:parseType="Resource">
                                <pdfaSchema:schema>Factur-X PDFA Extension Schema</pdfaSchema:schema>
                                <pdfaSchema:namespaceURI>urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#</pdfaSchema:namespaceURI>
                                <pdfaSchema:prefix>fx</pdfaSchema:prefix>
                                <pdfaSchema:property>
                                    <rdf:Seq>
                                        <rdf:li rdf:parseType="Resource">
                                            <pdfaProperty:name>DocumentFileName</pdfaProperty:name>
                                            <pdfaProperty:valueType>Text</pdfaProperty:valueType>
                                            <pdfaProperty:category>external</pdfaProperty:category>
                                            <pdfaProperty:description>name of the embedded XML invoice file</pdfaProperty:description>
                                        </rdf:li>
                                        <rdf:li rdf:parseType="Resource">
                                            <pdfaProperty:name>DocumentType</pdfaProperty:name>
                                            <pdfaProperty:valueType>Text</pdfaProperty:valueType>
                                            <pdfaProperty:category>external</pdfaProperty:category>
                                            <pdfaProperty:description>INVOICE</pdfaProperty:description>
                                        </rdf:li>
                                        <rdf:li rdf:parseType="Resource">
                                            <pdfaProperty:name>Version</pdfaProperty:name>
                                            <pdfaProperty:valueType>Text</pdfaProperty:valueType>
                                            <pdfaProperty:category>external</pdfaProperty:category>
                                            <pdfaProperty:description>version of the Factur-X standard</pdfaProperty:description>
                                        </rdf:li>
                                        <rdf:li rdf:parseType="Resource">
                                            <pdfaProperty:name>ConformanceLevel</pdfaProperty:name>
                                            <pdfaProperty:valueType>Text</pdfaProperty:valueType>
                                            <pdfaProperty:category>external</pdfaProperty:category>
                                            <pdfaProperty:description>conformance level of the embedded data</pdfaProperty:description>
                                        </rdf:li>
                                    </rdf:Seq>
                                </pdfaSchema:property>
                            </rdf:li>
                        </rdf:Bag>
                    </pdfaExtension:schemas>
                </rdf:Description>
                <rdf:Description rdf:about="" xmlns:fx="urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#">
                    <fx:DocumentType>INVOICE</fx:DocumentType>
                    <fx:DocumentFileName>\(filename)</fx:DocumentFileName>
                    <fx:Version>1.0</fx:Version>
                    <fx:ConformanceLevel>\(profile.conformanceLevel)</fx:ConformanceLevel>
                </rdf:Description>
            </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }
}
