import XCTest
import SwiftData
import InvoiceCore
@testable import Invoices

/// Tests for the operations that change accounting state.
///
/// These need SwiftData and the app's own model types, so they cannot live in the
/// InvoiceCore package. The container is in-memory: each test gets a clean store and
/// nothing touches the user's real data.
@MainActor
final class InvoiceServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: InvoiceService!

    override func setUpWithError() throws {
        let schema = Schema([BusinessProfile.self, Client.self, Invoice.self, LineItem.self])
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        context = ModelContext(container)
        service = InvoiceService(context: context)
    }

    override func tearDown() {
        service = nil
        context = nil
        container = nil
    }

    /// A seller that passes validation, so `issue` is exercising its own logic rather
    /// than failing on an empty profile.
    private func configureProfile() -> BusinessProfile {
        let profile = service.profile()
        profile.name = "Ada Consulting GmbH"
        profile.countryCode = "DE"
        profile.vatID = "DE123456789"
        profile.bankIBAN = "DE89370400440532013000"
        profile.bankAccountName = "Ada Consulting GmbH"
        profile.defaultCurrencyCode = "EUR"
        profile.defaultVATRate = 19
        return profile
    }

    private func makeClient() -> Client {
        let client = Client(name: "Atelier Dupont SARL")
        client.countryCode = "FR"
        client.vatID = "FR40303265045"
        context.insert(client)
        return client
    }

    private func billable(_ invoice: Invoice, amount: Decimal = 100) {
        for item in invoice.items {
            item.details = "Consulting"
            item.unitPriceValue = amount
            item.quantity = 1
            item.vatRate = 19
        }
    }

    // MARK: Profile

    func testProfileIsCreatedOnceAndReused() {
        let first = service.profile()
        first.name = "Ada"
        let second = service.profile()
        XCTAssertEqual(second.name, "Ada")
        let all = try? context.fetch(FetchDescriptor<BusinessProfile>())
        XCTAssertEqual(all?.count, 1)
    }

    // MARK: Drafts

    func testCreateDraftSeedsOneLineAndStaysADraft() {
        _ = configureProfile()
        let draft = service.createDraft()
        XCTAssertEqual(draft.status, .draft)
        XCTAssertEqual(draft.items.count, 1)
        XCTAssertEqual(draft.currencyCode, "EUR")
        // The seeded line inherits the profile's defaults rather than hard-coded zeros.
        XCTAssertEqual(draft.items.first?.vatRate, 19)
    }

    /// A draft must not consume a number, and must not shift the sequence either.
    /// This is the flaw that writing these tests exposed: a placeholder that looked like
    /// a real number was absorbed when the next invoice was issued, so two open drafts
    /// pushed the first issued number from 0001 to 0003.
    func testOpenDraftsDoNotShiftTheIssuedSequence() throws {
        _ = configureProfile()
        let client = makeClient()
        let year = Calendar.current.component(.year, from: .now)

        // Two drafts sitting open, plus one that gets discarded.
        let openA = service.createDraft(for: client)
        let openB = service.createDraft(for: client)
        service.delete([service.createDraft(for: client)])

        XCTAssertNotEqual(openA.number, openB.number, "placeholders must be unique")
        XCTAssertTrue(openA.number.hasPrefix(InvoiceService.placeholderPrefix))
        XCTAssertEqual(service.nextIssuedNumber(), "INV-\(year)-0001")

        let real = service.createDraft(for: client)
        billable(real)
        try service.issue(real)
        XCTAssertEqual(real.number, "INV-\(year)-0001",
                       "open drafts must not have consumed 0001 or 0002")
        XCTAssertEqual(service.nextIssuedNumber(), "INV-\(year)-0002")
    }

    /// A number typed into a draft, or left over from an import, must not move the
    /// watermark either — only issued invoices count.
    func testAHandEditedDraftNumberDoesNotMoveTheWatermark() throws {
        _ = configureProfile()
        let client = makeClient()
        let year = Calendar.current.component(.year, from: .now)

        let draft = service.createDraft(for: client)
        draft.number = "INV-\(year)-0099"

        let real = service.createDraft(for: client)
        billable(real)
        try service.issue(real)
        XCTAssertEqual(real.number, "INV-\(year)-0001")
    }

    // MARK: Issuing

    func testIssueAssignsSequentialNumbersAndLocks() throws {
        _ = configureProfile()
        let client = makeClient()
        let year = Calendar.current.component(.year, from: .now)

        let first = service.createDraft(for: client)
        billable(first)
        try service.issue(first)
        XCTAssertEqual(first.number, "INV-\(year)-0001")
        XCTAssertEqual(first.status, .issued)
        XCTAssertFalse(first.status.isEditable)

        let second = service.createDraft(for: client)
        billable(second)
        try service.issue(second)
        XCTAssertEqual(second.number, "INV-\(year)-0002")
    }

    /// The original bug, at the service level: deleting an issued invoice's successor
    /// must not let the next one reuse a spent number.
    func testDeletingADraftDoesNotFreeAnIssuedNumber() throws {
        _ = configureProfile()
        let client = makeClient()
        let year = Calendar.current.component(.year, from: .now)

        let first = service.createDraft(for: client)
        billable(first)
        try service.issue(first)

        let discarded = service.createDraft(for: client)
        service.delete([discarded])

        let third = service.createDraft(for: client)
        billable(third)
        try service.issue(third)
        XCTAssertEqual(third.number, "INV-\(year)-0002")
        XCTAssertNotEqual(third.number, first.number)
    }

    func testIssuingTwiceIsRefused() throws {
        _ = configureProfile()
        let invoice = service.createDraft(for: makeClient())
        billable(invoice)
        try service.issue(invoice)

        XCTAssertThrowsError(try service.issue(invoice)) { error in
            guard case InvoiceService.IssueError.notADraft = error else {
                return XCTFail("expected notADraft, got \(error)")
            }
        }
    }

    func testIssuingIsBlockedByValidationErrors() {
        _ = configureProfile()
        // No client, so the buyer has no name and no country.
        let invoice = service.createDraft()
        billable(invoice)

        XCTAssertThrowsError(try service.issue(invoice)) { error in
            guard case InvoiceService.IssueError.blocked(let issues) = error else {
                return XCTFail("expected blocked, got \(error)")
            }
            XCTAssertTrue(issues.contains { $0.rule == "BR-07" })
        }
        // A refused issue must not have consumed a number or changed the status.
        XCTAssertEqual(invoice.status, .draft)
    }

    /// An invoice is a record of a transaction. If the client moves office afterwards,
    /// the issued invoice must still show the address it was actually sent to.
    func testIssuingFreezesTheParties() throws {
        let profile = configureProfile()
        let client = makeClient()
        client.addressLine1 = "24 Rue de la Roquette"
        client.city = "Paris"

        let invoice = service.createDraft(for: client)
        billable(invoice)
        try service.issue(invoice)

        client.name = "Atelier Dupont SAS"
        client.addressLine1 = "9 Avenue Daumesnil"
        profile.name = "Ada Consulting Ltd"

        let document = invoice.document(profile: profile)
        XCTAssertEqual(document.buyer.name, "Atelier Dupont SARL")
        XCTAssertEqual(document.buyer.address.line1, "24 Rue de la Roquette")
        XCTAssertEqual(document.seller.name, "Ada Consulting GmbH")
    }

    /// A draft has no snapshot yet, so it must read through to the live profile —
    /// otherwise the editor would show an empty seller until the invoice is issued.
    func testDraftReadsThroughToTheLiveProfile() {
        let profile = configureProfile()
        let invoice = service.createDraft(for: makeClient())
        XCTAssertEqual(invoice.document(profile: profile).seller.name, "Ada Consulting GmbH")
        XCTAssertEqual(invoice.document(profile: profile).buyer.name, "Atelier Dupont SARL")
    }

    // MARK: Status

    func testMarkPaidRecordsTheDateAndReopenClearsIt() throws {
        _ = configureProfile()
        let invoice = service.createDraft(for: makeClient())
        billable(invoice)
        try service.issue(invoice)

        service.markPaid(invoice)
        XCTAssertEqual(invoice.status, .paid)
        XCTAssertNotNil(invoice.paidDate)

        service.reopen(invoice)
        XCTAssertEqual(invoice.status, .issued)
        XCTAssertNil(invoice.paidDate)
    }

    func testIssuedInvoicesCannotBeDeletedButCanBeCancelled() throws {
        _ = configureProfile()
        let invoice = service.createDraft(for: makeClient())
        billable(invoice)
        XCTAssertTrue(service.canDelete(invoice))

        try service.issue(invoice)
        XCTAssertFalse(service.canDelete(invoice))

        service.cancel(invoice)
        XCTAssertEqual(invoice.status, .cancelled)
        // Cancelling keeps the record, so the number sequence keeps no holes.
        let remaining = try context.fetch(FetchDescriptor<Invoice>())
        XCTAssertEqual(remaining.count, 1)
    }

    // MARK: Copies

    func testDuplicateCopiesLinesIntoAFreshDraft() throws {
        _ = configureProfile()
        let original = service.createDraft(for: makeClient())
        billable(original, amount: 250)
        original.items.first?.details = "Interface design"
        original.buyerReference = "PO-44182"
        try service.issue(original)

        let copy = service.duplicate(original)
        XCTAssertEqual(copy.status, .draft)
        XCTAssertEqual(copy.items.count, 1, "the seeded blank line should have been replaced")
        XCTAssertEqual(copy.items.first?.details, "Interface design")
        XCTAssertEqual(copy.items.first?.unitPriceValue, 250)
        XCTAssertEqual(copy.buyerReference, "PO-44182")
        XCTAssertNotEqual(copy.number, original.number)
    }

    func testCreditNoteReferencesTheOriginal() throws {
        _ = configureProfile()
        let original = service.createDraft(for: makeClient())
        billable(original, amount: 400)
        try service.issue(original)

        let note = service.createCreditNote(for: original)
        XCTAssertEqual(note.kind, .creditNote)
        XCTAssertEqual(note.precedingInvoiceNumber, original.number)
        XCTAssertEqual(note.items.count, original.items.count)
        XCTAssertEqual(note.status, .draft)
        XCTAssertEqual(note.currencyCode, original.currencyCode)
    }

    // MARK: Lines

    /// The stale-index bug, at the service level. Deleting the first and third of three
    /// lines must remove exactly those two.
    func testDeletingSeveralLinesRemovesTheRightOnes() {
        _ = configureProfile()
        let invoice = service.createDraft()
        invoice.items.first?.details = "one"
        let second = service.addLine(to: invoice)
        second.details = "two"
        let third = service.addLine(to: invoice)
        third.details = "three"
        XCTAssertEqual(invoice.items.count, 3)

        let ordered = invoice.items.sorted { $0.position < $1.position }
        service.deleteLines([ordered[0], ordered[2]], from: invoice)

        XCTAssertEqual(invoice.items.count, 1)
        XCTAssertEqual(invoice.items.first?.details, "two")
        // Positions are compacted, so a later insert does not collide.
        XCTAssertEqual(invoice.items.first?.position, 0)
    }

    func testAddLineAppendsAtTheEnd() {
        _ = configureProfile()
        let invoice = service.createDraft()
        let added = service.addLine(to: invoice)
        XCTAssertEqual(added.position, 1)
        XCTAssertEqual(service.addLine(to: invoice).position, 2)
    }

    // MARK: Relationships

    /// Invoices are accounting records with a retention period. Deleting a client must
    /// never take them with it.
    func testDeletingAClientKeepsTheirInvoices() throws {
        _ = configureProfile()
        let client = makeClient()
        let invoice = service.createDraft(for: client)
        billable(invoice)
        try service.issue(invoice)
        let number = invoice.number

        service.delete([client])

        let remaining = try context.fetch(FetchDescriptor<Invoice>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.number, number)
        XCTAssertNil(remaining.first?.client)
        // The buyer survives on the snapshot, which is why the invoice is still valid.
        XCTAssertEqual(remaining.first?.document.buyer.name, "Atelier Dupont SARL")
    }

    /// Deleting an invoice must take its lines with it, or the store accumulates
    /// orphaned rows.
    func testDeletingAnInvoiceCascadesToItsLines() throws {
        _ = configureProfile()
        let invoice = service.createDraft()
        _ = service.addLine(to: invoice)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LineItem>()).count, 2)

        service.delete([invoice])
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<LineItem>()).count, 0)
    }

    // MARK: Model mapping

    func testLineItemClearsTheRateWhenTheCategoryChargesNoVAT() {
        let item = LineItem(unitPrice: 100, vatCategory: .standard, vatRate: 19)
        item.vatCategory = .reverseCharge
        XCTAssertEqual(item.vatRate, 0, "a stale rate would contradict the category")
    }

    func testInvoiceTotalsFlowThroughToTheDocument() {
        _ = configureProfile()
        let invoice = service.createDraft(for: makeClient())
        billable(invoice, amount: 1000)
        let totals = invoice.document.totals
        XCTAssertEqual(totals.lineTotal.xmlValue, "1000.00")
        XCTAssertEqual(totals.taxTotal.xmlValue, "190.00")
        XCTAssertEqual(totals.grandTotal.xmlValue, "1190.00")
    }

    func testOverdueOnlyAppliesToIssuedInvoices() throws {
        _ = configureProfile()
        let invoice = service.createDraft(for: makeClient())
        billable(invoice)
        invoice.dueDate = Calendar.current.date(byAdding: .day, value: -10, to: .now)

        // A draft is never overdue, however old its due date.
        XCTAssertFalse(invoice.isOverdue)

        try service.issue(invoice)
        XCTAssertTrue(invoice.isOverdue)
        XCTAssertGreaterThanOrEqual(invoice.daysOverdue, 9)

        service.markPaid(invoice)
        XCTAssertFalse(invoice.isOverdue)
    }
}
