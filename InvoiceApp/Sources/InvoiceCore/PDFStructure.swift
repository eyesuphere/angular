import Foundation

/// Just enough PDF parsing to perform an incremental update.
///
/// This is deliberately not a PDF reader. It locates the last cross-reference table,
/// the trailer, and the byte range of the document catalogue — nothing else. Anything
/// it does not understand is an error rather than a guess, because a wrong guess here
/// produces a file that opens in Preview and fails in a tax authority's validator.
struct PDFStructure {
    let bytes: Data
    /// Object number of the document catalogue.
    let catalogNumber: Int
    /// The `/Size` from the trailer: the first free object number.
    let size: Int
    /// Byte offset of the cross-reference table we are chaining from.
    let previousXrefOffset: Int
    /// The trailer's `/ID` array, verbatim, so the incremental update can repeat it.
    let idEntry: String?

    private let objectOffsets: [Int: Int]

    init(_ input: Data) throws {
        // Force a 0-based, contiguous buffer: a Data slice keeps its parent's indices,
        // and every offset below is absolute.
        let data = Data(input)
        self.bytes = data

        guard let startxrefRange = Self.lastRange(of: "startxref", in: data) else {
            throw FacturXPDFAttacher.AttachError.missingStartxref
        }
        let tail = Self.ascii(data[startxrefRange.upperBound..<min(data.count, startxrefRange.upperBound + 64)])
        guard let xrefOffset = Int(tail.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.whitespacesAndNewlines).first ?? ""),
              xrefOffset > 0, xrefOffset < data.count else {
            throw FacturXPDFAttacher.AttachError.missingStartxref
        }
        self.previousXrefOffset = xrefOffset

        // A classic table starts with the literal keyword. Anything else at this offset
        // — in practice "N 0 obj" introducing a cross-reference stream — is unsupported.
        let atOffset = Self.ascii(data[xrefOffset..<min(data.count, xrefOffset + 16)])
        guard atOffset.hasPrefix("xref") else {
            throw FacturXPDFAttacher.AttachError.unsupportedCrossReferenceStream
        }

        let (offsets, trailerStart) = try Self.parseXrefTable(data, from: xrefOffset)
        self.objectOffsets = offsets

        guard let trailerRange = Self.range(of: "trailer", in: data, from: trailerStart) else {
            throw FacturXPDFAttacher.AttachError.malformedTrailer
        }
        guard let dictRange = Self.balancedDictionary(in: data, from: trailerRange.upperBound) else {
            throw FacturXPDFAttacher.AttachError.malformedTrailer
        }
        let trailer = Self.ascii(data[dictRange])

        guard let root = Self.indirectReference(named: "/Root", in: trailer) else {
            throw FacturXPDFAttacher.AttachError.missingCatalogReference
        }
        self.catalogNumber = root

        let declaredSize = Self.integer(named: "/Size", in: trailer) ?? 0
        // Never allocate over an object the table already knows about.
        self.size = max(declaredSize, (offsets.keys.max() ?? 0) + 1)

        self.idEntry = Self.arrayValue(named: "/ID", in: trailer)
    }

    /// The inner text of the catalogue dictionary, without the enclosing `<<` `>>`.
    func catalogDictionaryBody() throws -> String {
        guard let offset = objectOffsets[catalogNumber], offset < bytes.count else {
            throw FacturXPDFAttacher.AttachError.catalogNotFound(catalogNumber)
        }
        // Confirm the object header matches, rather than trusting the index blindly.
        let header = Self.ascii(bytes[offset..<min(bytes.count, offset + 48)])
        guard header.hasPrefix("\(catalogNumber) ") , header.contains("obj") else {
            throw FacturXPDFAttacher.AttachError.catalogNotFound(catalogNumber)
        }
        guard let objKeyword = Self.range(of: "obj", in: bytes, from: offset),
              let dictRange = Self.balancedDictionary(in: bytes, from: objKeyword.upperBound) else {
            throw FacturXPDFAttacher.AttachError.catalogNotFound(catalogNumber)
        }
        let full = Self.ascii(bytes[dictRange])
        // Strip the outer << >> so the caller can splice in extra keys.
        let inner = full.dropFirst(2).dropLast(2)
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cross-reference table

    /// Reads the subsections of a classic xref table. Returns the offsets it found and
    /// the position where the table ends.
    private static func parseXrefTable(_ data: Data, from start: Int) throws -> ([Int: Int], Int) {
        var offsets: [Int: Int] = [:]
        var cursor = start + 4   // past "xref"
        var guardCounter = 0

        while cursor < data.count {
            guardCounter += 1
            if guardCounter > 10_000 { throw FacturXPDFAttacher.AttachError.malformedTrailer }

            cursor = skipWhitespace(data, from: cursor)
            // The table ends at "trailer".
            if ascii(data[cursor..<min(data.count, cursor + 7)]) == "trailer" { return (offsets, cursor) }

            // Subsection header: "<first> <count>".
            guard let first = readInteger(data, at: &cursor) else { return (offsets, cursor) }
            cursor = skipWhitespace(data, from: cursor)
            guard let count = readInteger(data, at: &cursor), count >= 0 else {
                throw FacturXPDFAttacher.AttachError.malformedTrailer
            }

            for index in 0..<count {
                cursor = skipWhitespace(data, from: cursor)
                guard cursor + 18 <= data.count else {
                    throw FacturXPDFAttacher.AttachError.malformedTrailer
                }
                let entry = ascii(data[cursor..<cursor + 18])
                let fields = entry.split(separator: " ", omittingEmptySubsequences: true)
                if fields.count >= 3, fields[2].hasPrefix("n"), let offset = Int(fields[0]) {
                    offsets[first + index] = offset
                }
                cursor += 18
            }
        }
        return (offsets, cursor)
    }

    // MARK: - Byte scanning

    private static func skipWhitespace(_ data: Data, from index: Int) -> Int {
        var i = index
        while i < data.count, data[i] == 0x20 || data[i] == 0x0A || data[i] == 0x0D || data[i] == 0x09 {
            i += 1
        }
        return i
    }

    private static func readInteger(_ data: Data, at cursor: inout Int) -> Int? {
        var digits = ""
        while cursor < data.count, let scalar = Unicode.Scalar(UInt32(data[cursor])),
              Character(scalar).isNumber {
            digits.append(Character(scalar))
            cursor += 1
        }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Finds a balanced `<< ... >>` starting at or after `from`, skipping over literal
    /// strings so that a `>>` inside `(text)` does not close the dictionary early.
    static func balancedDictionary(in data: Data, from start: Int) -> Range<Int>? {
        var i = skipWhitespace(data, from: start)
        guard i + 1 < data.count, data[i] == 0x3C, data[i + 1] == 0x3C else { return nil }

        let open = i
        var depth = 0
        var inString = false
        var stringDepth = 0
        var escaped = false

        while i < data.count {
            let byte = data[i]
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }          // backslash
                else if byte == 0x28 { stringDepth += 1 }        // (
                else if byte == 0x29 {                           // )
                    stringDepth -= 1
                    if stringDepth == 0 { inString = false }
                }
                i += 1
                continue
            }
            if byte == 0x28 {                                    // (
                inString = true
                stringDepth = 1
                i += 1
                continue
            }
            if byte == 0x3C, i + 1 < data.count, data[i + 1] == 0x3C {
                depth += 1
                i += 2
                continue
            }
            if byte == 0x3E, i + 1 < data.count, data[i + 1] == 0x3E {
                depth -= 1
                i += 2
                if depth == 0 { return open..<i }
                continue
            }
            i += 1
        }
        return nil
    }

    private static func ascii(_ slice: Data) -> String {
        String(decoding: slice, as: UTF8.self)
    }

    private static func lastRange(of needle: String, in data: Data) -> Range<Int>? {
        let pattern = Data(needle.utf8)
        guard data.count >= pattern.count else { return nil }
        var index = data.count - pattern.count
        while index >= 0 {
            if data[index..<index + pattern.count].elementsEqual(pattern) {
                return index..<index + pattern.count
            }
            index -= 1
        }
        return nil
    }

    private static func range(of needle: String, in data: Data, from start: Int) -> Range<Int>? {
        let pattern = Data(needle.utf8)
        guard start >= 0, data.count >= pattern.count else { return nil }
        var index = start
        while index + pattern.count <= data.count {
            if data[index..<index + pattern.count].elementsEqual(pattern) {
                return index..<index + pattern.count
            }
            index += 1
        }
        return nil
    }

    // MARK: - Trailer values

    static func integer(named key: String, in dictionary: String) -> Int? {
        guard let range = dictionary.range(of: key) else { return nil }
        let rest = dictionary[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }

    /// Reads `/Root 3 0 R` and returns 3.
    static func indirectReference(named key: String, in dictionary: String) -> Int? {
        guard let range = dictionary.range(of: key) else { return nil }
        let rest = dictionary[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, rest.dropFirst(digits.count).contains("R") else { return nil }
        return Int(digits)
    }

    /// Returns an array value such as `[<a1b2> <c3d4>]` verbatim, brackets included.
    static func arrayValue(named key: String, in dictionary: String) -> String? {
        guard let keyRange = dictionary.range(of: key),
              let open = dictionary[keyRange.upperBound...].firstIndex(of: "[") else { return nil }
        var depth = 0
        var index = open
        while index < dictionary.endIndex {
            if dictionary[index] == "[" { depth += 1 }
            if dictionary[index] == "]" {
                depth -= 1
                if depth == 0 {
                    return String(dictionary[open...index])
                }
            }
            index = dictionary.index(after: index)
        }
        return nil
    }
}
