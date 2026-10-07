import Foundation

/// A minimal, order-preserving XML emitter.
///
/// CII is a sequence-based schema: every child element has a fixed position and a
/// validator rejects a document whose elements are correct but out of order. Building
/// the tree with explicit nested calls makes that order visible in the source, which a
/// dictionary-based encoder would not.
///
/// A class rather than a struct on purpose: a struct would need `element` to be
/// `mutating` and to pass `&self` into its own body closure, which is an overlapping
/// exclusive access to `self`.
final class XMLWriter {
    private var out: String = ""
    private var depth: Int = 0

    init(declaration: Bool = true) {
        if declaration { out += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" }
    }

    var result: String { out }

    private var indent: String { String(repeating: "    ", count: depth) }

    /// Opens an element, runs `body` to emit its children, then closes it.
    func element(_ name: String, _ attributes: [(String, String)] = [], body: () -> Void) {
        out += indent + "<" + name + Self.attributeString(attributes) + ">\n"
        depth += 1
        body()
        depth -= 1
        out += indent + "</" + name + ">\n"
    }

    /// A leaf element with text content. Skipped entirely when `text` is nil.
    func leaf(_ name: String, _ text: String?, _ attributes: [(String, String)] = []) {
        guard let text else { return }
        out += indent + "<" + name + Self.attributeString(attributes) + ">"
            + Self.escape(text) + "</" + name + ">\n"
    }

    /// A leaf that is emitted only when the text is non-empty after trimming.
    func optionalLeaf(_ name: String, _ text: String?, _ attributes: [(String, String)] = []) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        leaf(name, text, attributes)
    }

    private static func attributeString(_ attributes: [(String, String)]) -> String {
        attributes.map { " \($0.0)=\"\(escape($0.1))\"" }.joined()
    }

    /// Escapes the five XML predefined entities, and drops control characters that are
    /// not legal in XML 1.0 at all — otherwise an innocuous paste into a description
    /// field produces a document no parser will read.
    static func escape(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\n", "\r", "\t": result.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
