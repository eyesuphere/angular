import XCTest
@testable import InvoiceCore

final class MoneyTests: XCTestCase {
    /// The reason Money exists. With Double, 0.1 summed ten times is not 1.0, and an
    /// invoice total that is out by a cent is a defect a tax authority can act on.
    func testTenthsSumExactly() {
        let tenth = Money(Decimal(string: "0.10")!, .eur)
        let total = Money.sum(Array(repeating: tenth, count: 10), currency: .eur)
        XCTAssertEqual(total.amount, Decimal(1))
        XCTAssertEqual(total.xmlValue, "1.00")
    }

    func testRoundsHalfAwayFromZero() {
        // Commercial rounding, not banker's: 0.005 goes up, not to even.
        XCTAssertEqual(Money(Decimal(string: "0.005")!, .eur).rounded.xmlValue, "0.01")
        XCTAssertEqual(Money(Decimal(string: "0.015")!, .eur).rounded.xmlValue, "0.02")
        XCTAssertEqual(Money(Decimal(string: "2.345")!, .eur).rounded.xmlValue, "2.35")
    }

    func testXMLValueIsFixedScaleAndDotSeparated() {
        XCTAssertEqual(Money(Decimal(string: "1899.95")!, .eur).xmlValue, "1899.95")
        XCTAssertEqual(Money(7, .eur).xmlValue, "7.00")
        XCTAssertEqual(Money(Decimal(string: "0.1")!, .eur).xmlValue, "0.10")
    }

    func testZeroDecimalCurrency() {
        let yen = Money(Decimal(string: "1234.6")!, .jpy)
        XCTAssertEqual(yen.xmlValue, "1235")
    }

    func testThreeDecimalCurrency() {
        let dinar = Money(Decimal(string: "19.9995")!, Currency.named("TND"))
        XCTAssertEqual(dinar.xmlValue, "20.000")
    }

    /// A value that rounds away to nothing must not print as "-0.00": validators and
    /// humans both read that as a different number.
    func testNegativeZeroNeverPrinted() {
        XCTAssertEqual(Money(Decimal(string: "-0.001")!, .eur).xmlValue, "0.00")
    }

    func testNegativeValuesKeepSign() {
        XCTAssertEqual(Money(Decimal(string: "-12.50")!, .eur).xmlValue, "-12.50")
    }

    func testParsingRespectsLocaleSeparators() {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(Money(string: "1.234,56", currency: .eur, locale: german)?.amount,
                       Decimal(string: "1234.56"))
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(Money(string: "1,234.56", currency: .eur, locale: us)?.amount,
                       Decimal(string: "1234.56"))
    }

    /// A typo must become a validation error, not a silent zero. This is the bug the
    /// original `TextField(value:format:.number)` had.
    func testParsingRejectsNonsense() {
        XCTAssertNil(Money(string: "", currency: .eur))
        XCTAssertNil(Money(string: "abc", currency: .eur))
        XCTAssertNil(Money(string: "  ", currency: .eur))
    }

    func testRateStringTrimsTrailingZeros() {
        XCTAssertEqual(Decimal(19).rateString, "19")
        XCTAssertEqual(Decimal(string: "8.875")!.rateString, "8.875")
        XCTAssertEqual(Decimal(string: "7.50")!.rateString, "7.5")
        XCTAssertEqual(Decimal.zero.rateString, "0")
    }
}
