import XCTest
@testable import InvoiceCore

final class InvoiceNumberingTests: XCTestCase {
    func testFormatsWithYearAndPadding() {
        let format = InvoiceNumberFormat()
        XCTAssertEqual(format.format(counter: 7, year: 2026), "INV-2026-0007")
        XCTAssertEqual(format.format(counter: 1234, year: 2026), "INV-2026-1234")
        XCTAssertEqual(format.format(counter: 99999, year: 2026), "INV-2026-99999")
    }

    func testFormatsWithoutYear() {
        let format = InvoiceNumberFormat(prefix: "R", includesYear: false, digits: 3)
        XCTAssertEqual(format.format(counter: 42, year: 2026), "R042")
    }

    /// The bug in the original app: numbering from a live row count reuses a number as
    /// soon as anything is deleted. The sequence must only ever move forward.
    func testDeletingDoesNotFreeANumber() {
        var sequence = InvoiceNumberSequence()
        XCTAssertEqual(sequence.issue(year: 2026), "INV-2026-0001")
        XCTAssertEqual(sequence.issue(year: 2026), "INV-2026-0002")
        XCTAssertEqual(sequence.issue(year: 2026), "INV-2026-0003")
        // The caller deletes invoice 2. The watermark is unaffected.
        XCTAssertEqual(sequence.issue(year: 2026), "INV-2026-0004")
    }

    func testPeekDoesNotConsume() {
        var sequence = InvoiceNumberSequence()
        XCTAssertEqual(sequence.peek(year: 2026), "INV-2026-0001")
        XCTAssertEqual(sequence.peek(year: 2026), "INV-2026-0001")
        XCTAssertEqual(sequence.issue(year: 2026), "INV-2026-0001")
        XCTAssertEqual(sequence.peek(year: 2026), "INV-2026-0002")
    }

    func testCounterResetsAnnuallyWhenConfigured() {
        var sequence = InvoiceNumberSequence()
        _ = sequence.issue(year: 2026)
        _ = sequence.issue(year: 2026)
        XCTAssertEqual(sequence.issue(year: 2027), "INV-2027-0001")
        // Going back to the old year continues that year's run, it does not restart it.
        XCTAssertEqual(sequence.issue(year: 2026), "INV-2026-0003")
    }

    func testCounterDoesNotResetWhenConfiguredNotTo() {
        var sequence = InvoiceNumberSequence(
            format: InvoiceNumberFormat(resetsAnnually: false))
        _ = sequence.issue(year: 2026)
        XCTAssertEqual(sequence.issue(year: 2027), "INV-2027-0002")
    }

    func testAbsorbRaisesTheWatermark() {
        var sequence = InvoiceNumberSequence()
        sequence.absorb(existingNumbers: ["INV-2026-0003", "INV-2026-0011", "INV-2026-0007"],
                        year: 2026)
        XCTAssertEqual(sequence.issue(year: 2026), "INV-2026-0012")
    }

    func testAbsorbNeverLowersTheWatermark() {
        var sequence = InvoiceNumberSequence()
        _ = sequence.issue(year: 2026)
        _ = sequence.issue(year: 2026)
        _ = sequence.issue(year: 2026)
        sequence.absorb(existingNumbers: ["INV-2026-0001"], year: 2026)
        XCTAssertEqual(sequence.issue(year: 2026), "INV-2026-0004")
    }

    /// A number from another scheme — hand-typed, or imported from an old tool — must
    /// be ignored rather than parsed into a wild counter.
    func testForeignNumbersAreIgnored() {
        let format = InvoiceNumberFormat()
        XCTAssertNil(format.counter(in: "2026/17", year: 2026))
        XCTAssertNil(format.counter(in: "INV-2025-0004", year: 2026))
        XCTAssertNil(format.counter(in: "INV-2026-ABCD", year: 2026))
        XCTAssertNil(format.counter(in: "INV-2026-", year: 2026))
        XCTAssertEqual(format.counter(in: "INV-2026-0004", year: 2026), 4)
    }

    func testAbsorbWithNoMatchingNumbersIsANoop() {
        var sequence = InvoiceNumberSequence()
        sequence.absorb(existingNumbers: ["2026/17", "weird"], year: 2026)
        XCTAssertEqual(sequence.issue(year: 2026), "INV-2026-0001")
    }

    func testSequenceRoundTripsThroughCodable() throws {
        var sequence = InvoiceNumberSequence()
        _ = sequence.issue(year: 2026)
        let data = try JSONEncoder().encode(sequence)
        var restored = try JSONDecoder().decode(InvoiceNumberSequence.self, from: data)
        XCTAssertEqual(restored.issue(year: 2026), "INV-2026-0002")
    }
}
