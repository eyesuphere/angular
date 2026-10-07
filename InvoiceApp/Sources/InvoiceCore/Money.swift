import Foundation

/// A currency, with the number of minor units it rounds to.
///
/// Only the units needed for invoicing are modelled. `minorUnits` follows ISO 4217:
/// most currencies use 2, JPY and KRW use 0, and a few (TND, BHD) use 3.
public struct Currency: Hashable, Sendable, Codable {
    public let code: String          // ISO 4217 alphabetic, e.g. "EUR"
    public let minorUnits: Int

    public init(code: String, minorUnits: Int = 2) {
        self.code = code.uppercased()
        self.minorUnits = minorUnits
    }

    public static let eur = Currency(code: "EUR")
    public static let usd = Currency(code: "USD")
    public static let gbp = Currency(code: "GBP")
    public static let chf = Currency(code: "CHF")
    public static let jpy = Currency(code: "JPY", minorUnits: 0)

    private static let known: [String: Int] = [
        "JPY": 0, "KRW": 0, "VND": 0, "CLP": 0, "ISK": 0,
        "BHD": 3, "JOD": 3, "KWD": 3, "OMR": 3, "TND": 3,
    ]

    /// Looks up the minor-unit count for a code, defaulting to 2.
    public static func named(_ code: String) -> Currency {
        let c = code.uppercased()
        return Currency(code: c, minorUnits: known[c] ?? 2)
    }
}

/// An exact monetary amount.
///
/// Backed by `Decimal` rather than `Double`. A binary float cannot represent 0.10
/// exactly, so totals built from floats drift: summing 0.1 ten times does not give 1.0.
/// On an invoice that drift is a legal defect, and tax authorities reconcile to the cent.
///
/// `Money` keeps the full unrounded `Decimal` internally and rounds only where the
/// EN 16931 calculation model says a value is rounded — at line totals, at VAT
/// category subtotals, and at the document total. See `InvoiceTotals`.
public struct Money: Hashable, Sendable, Comparable, Codable {
    public let amount: Decimal
    public let currency: Currency

    public init(_ amount: Decimal, _ currency: Currency) {
        self.amount = amount
        self.currency = currency
    }

    public init(_ amount: Int, _ currency: Currency) {
        self.init(Decimal(amount), currency)
    }

    /// Parses a user-entered amount. Returns nil for anything that is not a plain
    /// decimal number, so a typo becomes a validation error rather than a silent zero.
    public init?(string: String, currency: Currency, locale: Locale = .current) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let separator = locale.decimalSeparator ?? "."
        let normalised = trimmed
            .replacingOccurrences(of: locale.groupingSeparator ?? ",", with: "")
            .replacingOccurrences(of: separator, with: ".")
        guard let value = Decimal(string: normalised, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        self.init(value, currency)
    }

    public static func zero(_ currency: Currency) -> Money { Money(Decimal.zero, currency) }

    public var isZero: Bool { amount == .zero }
    public var isNegative: Bool { amount < .zero }

    /// The amount rounded to the currency's minor units, half away from zero.
    ///
    /// EN 16931 and the national mandates built on it expect commercial rounding at
    /// the points the calculation model defines, not banker's rounding.
    public var rounded: Money {
        Money(Money.round(amount, scale: currency.minorUnits), currency)
    }

    static func round(_ value: Decimal, scale: Int) -> Decimal {
        var input = value
        var result = Decimal.zero
        NSDecimalRound(&result, &input, scale, .plain)
        return result
    }

    // MARK: Arithmetic
    //
    // Operations between different currencies are a programming error, not a runtime
    // condition to recover from: there is no exchange rate in scope here. They trap.

    public static func + (a: Money, b: Money) -> Money {
        precondition(a.currency == b.currency, "cannot add \(a.currency.code) to \(b.currency.code)")
        return Money(a.amount + b.amount, a.currency)
    }

    public static func - (a: Money, b: Money) -> Money {
        precondition(a.currency == b.currency, "cannot subtract \(b.currency.code) from \(a.currency.code)")
        return Money(a.amount - b.amount, a.currency)
    }

    public static func * (a: Money, factor: Decimal) -> Money {
        Money(a.amount * factor, a.currency)
    }

    public static prefix func - (a: Money) -> Money { Money(-a.amount, a.currency) }

    public static func < (a: Money, b: Money) -> Bool {
        precondition(a.currency == b.currency, "cannot compare \(a.currency.code) with \(b.currency.code)")
        return a.amount < b.amount
    }

    public static func sum(_ values: [Money], currency: Currency) -> Money {
        values.reduce(Money.zero(currency), +)
    }

    // MARK: Formatting

    /// Formats for display, honouring the user's locale for separators but always
    /// showing this invoice's currency rather than the locale's.
    public func formatted(locale: Locale = .current) -> String {
        amount.formatted(
            .currency(code: currency.code)
                .precision(.fractionLength(currency.minorUnits))
                .locale(locale)
        )
    }

    /// The representation EN 16931 requires in the XML: a plain decimal, dot separator,
    /// fixed to the currency's minor units, no grouping and no currency symbol.
    public var xmlValue: String {
        let r = Money.round(amount, scale: currency.minorUnits)
        return Money.plainString(r, scale: currency.minorUnits)
    }

    /// Renders a Decimal with a dot separator, no grouping, fixed to `scale` digits.
    static func plainString(_ value: Decimal, scale: Int) -> String {
        let negative = value < .zero
        var magnitude = negative ? -value : value
        // NSDecimalString is locale-sensitive; force POSIX so the separator is a dot.
        let raw = NSDecimalString(&magnitude, Locale(identifier: "en_US_POSIX"))

        var parts = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 { parts.append("") }

        let body: String
        if scale == 0 {
            body = parts[0]
        } else {
            let padded = parts[1] + String(repeating: "0", count: scale)
            body = parts[0] + "." + String(padded.prefix(scale))
        }

        // Never emit "-0.00": a rounded-away negative is just zero.
        let isZero = !body.contains { ("1"..."9").contains($0) }
        return (negative && !isZero) ? "-" + body : body
    }
}

extension Decimal {
    /// Renders a rate such as 19 or 8.875 for the XML, without trailing-zero noise.
    public var rateString: String {
        let rounded = Money.round(self, scale: 4)
        var s = Money.plainString(rounded, scale: 4)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
