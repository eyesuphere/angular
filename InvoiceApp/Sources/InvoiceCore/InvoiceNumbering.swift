import Foundation

/// Generates invoice numbers from a pattern.
///
/// Most EU jurisdictions require the sequence to be continuous and gap-free: you may
/// not skip a number, and you may not reuse one. That rules out the obvious
/// `count + 1`, which silently reuses a number as soon as anything is deleted. Here
/// the next value is derived from the highest number ever issued for the period, and
/// the caller is expected to persist the counter rather than recompute it from live
/// rows, so a deleted draft cannot free its number up again.
public struct InvoiceNumberFormat: Hashable, Sendable, Codable {
    /// Literal prefix, e.g. "INV-".
    public var prefix: String
    /// Whether the year is part of the number. Required if the counter resets yearly.
    public var includesYear: Bool
    /// Separator between the year and the counter.
    public var separator: String
    /// Zero-padded width of the counter.
    public var digits: Int
    /// Whether the counter restarts at 1 each calendar year.
    public var resetsAnnually: Bool

    public init(prefix: String = "INV-", includesYear: Bool = true, separator: String = "-",
                digits: Int = 4, resetsAnnually: Bool = true) {
        self.prefix = prefix
        self.includesYear = includesYear
        self.separator = separator
        self.digits = max(1, min(digits, 12))
        self.resetsAnnually = resetsAnnually
    }

    public static let `default` = InvoiceNumberFormat()

    /// Renders a number for a given counter and year, e.g. "INV-2026-0007".
    public func format(counter: Int, year: Int) -> String {
        let padded = String(format: "%0\(digits)d", counter)
        if includesYear {
            return "\(prefix)\(year)\(separator)\(padded)"
        }
        return "\(prefix)\(padded)"
    }

    /// Extracts the counter from a number this format produced. Returns nil for a
    /// number from a different scheme, so a hand-edited or imported number is ignored
    /// when computing the next one rather than corrupting the sequence.
    public func counter(in number: String, year: Int) -> Int? {
        let expectedPrefix = includesYear ? "\(prefix)\(year)\(separator)" : prefix
        guard number.hasPrefix(expectedPrefix) else { return nil }
        let tail = String(number.dropFirst(expectedPrefix.count))
        guard !tail.isEmpty, tail.allSatisfy(\.isNumber), let value = Int(tail) else { return nil }
        return value
    }
}

/// The persisted state of a numbering sequence.
///
/// `lastIssued` only ever moves forward. `peek` shows what the next number will be
/// without consuming it; `issue` consumes one and is the only mutation.
public struct InvoiceNumberSequence: Hashable, Sendable, Codable {
    public var format: InvoiceNumberFormat
    /// Highest counter issued, keyed by year (or by 0 when the counter never resets).
    public var lastIssued: [Int: Int]

    public init(format: InvoiceNumberFormat = .default, lastIssued: [Int: Int] = [:]) {
        self.format = format
        self.lastIssued = lastIssued
    }

    private func key(for year: Int) -> Int { format.resetsAnnually ? year : 0 }

    public func peek(year: Int) -> String {
        let next = (lastIssued[key(for: year)] ?? 0) + 1
        return format.format(counter: next, year: year)
    }

    /// Consumes and returns the next number.
    public mutating func issue(year: Int) -> String {
        let k = key(for: year)
        let next = (lastIssued[k] ?? 0) + 1
        lastIssued[k] = next
        return format.format(counter: next, year: year)
    }

    /// Raises the watermark to cover numbers already in the store. Used once when
    /// migrating an existing data set, or after an import, so the sequence never
    /// re-issues a number that is already on a sent invoice.
    public mutating func absorb(existingNumbers: [String], year: Int) {
        let k = key(for: year)
        let highest = existingNumbers.compactMap { format.counter(in: $0, year: year) }.max()
        guard let highest else { return }
        lastIssued[k] = max(lastIssued[k] ?? 0, highest)
    }
}
