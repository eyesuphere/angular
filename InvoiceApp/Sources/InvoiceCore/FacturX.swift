import Foundation

/// A Factur-X / ZUGFeRD profile.
///
/// Factur-X (France) and ZUGFeRD (Germany) are the same Franco-German hybrid standard
/// under two names: a human-readable PDF with CII XML embedded inside it. The profile
/// decides how much structured data the XML carries. BASIC and above are EN 16931
/// compliant, which is what the national mandates require; MINIMUM and BASIC WL are
/// not, and exist only for accounting hand-off.
public enum FacturXProfile: String, Sendable, CaseIterable {
    case minimum
    case basicWL
    case basic
    case en16931
    case extended

    /// The guideline identifier that goes in GuidelineSpecifiedDocumentContextParameter.
    /// A validator keys its entire rule set off this string.
    public var guidelineID: String {
        switch self {
        case .minimum: return "urn:factur-x.eu:1p0:minimum"
        case .basicWL: return "urn:factur-x.eu:1p0:basicwl"
        case .basic: return "urn:cen.eu:en16931:2017#compliant#urn:factur-x.eu:1p0:basic"
        case .en16931: return "urn:cen.eu:en16931:2017"
        case .extended: return "urn:cen.eu:en16931:2017#conformant#urn:factur-x.eu:1p0:extended"
        }
    }

    /// The value written into the XMP metadata's fx:ConformanceLevel.
    public var conformanceLevel: String {
        switch self {
        case .minimum: return "MINIMUM"
        case .basicWL: return "BASIC WL"
        case .basic: return "BASIC"
        case .en16931: return "EN 16931"
        case .extended: return "EXTENDED"
        }
    }

    /// Whether this profile satisfies the EU mandates.
    public var isEN16931Compliant: Bool {
        switch self {
        case .minimum, .basicWL: return false
        case .basic, .en16931, .extended: return true
        }
    }

    public var label: String {
        switch self {
        case .minimum: return "Minimum (not mandate-compliant)"
        case .basicWL: return "Basic without lines (not mandate-compliant)"
        case .basic: return "Basic"
        case .en16931: return "EN 16931 (recommended)"
        case .extended: return "Extended"
        }
    }
}

/// Builds the CII XML payload of a Factur-X / ZUGFeRD invoice.
///
/// Scope and honesty: this emits the EN 16931 semantic model mapped onto CII D16B
/// syntax, in schema order. It has NOT been run against the official XSD or the
/// EN 16931 Schematron rule set — see README for how to do that before shipping.
/// Treat the output as structurally modelled rather than certified.
public struct FacturXBuilder {
    public let profile: FacturXProfile
    public let calendar: Calendar

    public init(profile: FacturXProfile = .en16931, timeZone: TimeZone = TimeZone(identifier: "UTC") ?? .current) {
        self.profile = profile
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    /// The filename the standard reserves for the embedded payload. A reader looks for
    /// this exact name, so it is not configurable.
    public static let attachmentFilename = "factur-x.xml"

    public func xml(for invoice: InvoiceDocument) -> String {
        let totals = invoice.totals
        let w = XMLWriter()

        w.element("rsm:CrossIndustryInvoice", [
            ("xmlns:rsm", "urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"),
            ("xmlns:ram", "urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"),
            ("xmlns:udt", "urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100"),
            ("xmlns:qdt", "urn:un:unece:uncefact:data:standard:QualifiedDataType:100"),
        ]) {
            documentContext(w)
            exchangedDocument(w, invoice)
            w.element("rsm:SupplyChainTradeTransaction") {
                if profile != .minimum && profile != .basicWL {
                    for (index, line) in invoice.lines.enumerated() {
                        lineItem(w, line, position: index + 1)
                    }
                }
                headerAgreement(w, invoice)
                headerDelivery(w, invoice)
                headerSettlement(w, invoice, totals)
            }
        }
        return w.result
    }

    public func xmlData(for invoice: InvoiceDocument) -> Data {
        Data(xml(for: invoice).utf8)
    }

    // MARK: - Sections

    private func documentContext(_ w: XMLWriter) {
        w.element("rsm:ExchangedDocumentContext") {
            w.element("ram:GuidelineSpecifiedDocumentContextParameter") {
                w.leaf("ram:ID", profile.guidelineID)
            }
        }
    }

    private func exchangedDocument(_ w: XMLWriter, _ invoice: InvoiceDocument) {
        w.element("rsm:ExchangedDocument") {
            w.leaf("ram:ID", invoice.number)
            w.leaf("ram:TypeCode", invoice.kind.rawValue)
            w.element("ram:IssueDateTime") {
                w.leaf("udt:DateTimeString", dateString(invoice.issueDate), [("format", "102")])
            }
            // Each VAT group that charges no tax needs its legal reason stated on the
            // document itself, not only in the tax breakdown.
            for row in invoice.totals.breakdown {
                if let reason = row.exemptionReason {
                    w.element("ram:IncludedNote") {
                        w.leaf("ram:Content", reason)
                        w.leaf("ram:SubjectCode", "TXD")   // tax declaration
                    }
                }
            }
            if !invoice.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                w.element("ram:IncludedNote") {
                    w.leaf("ram:Content", invoice.notes)
                }
            }
        }
    }

    private func lineItem(_ w: XMLWriter, _ line: InvoiceLine, position: Int) {
        w.element("ram:IncludedSupplyChainTradeLineItem") {
            w.element("ram:AssociatedDocumentLineDocument") {
                w.leaf("ram:LineID", String(position))
                if !line.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    w.element("ram:IncludedNote") {
                        w.leaf("ram:Content", line.note)
                    }
                }
            }
            w.element("ram:SpecifiedTradeProduct") {
                w.leaf("ram:Name", line.name.isEmpty ? "Item" : line.name)
            }
            w.element("ram:SpecifiedLineTradeAgreement") {
                w.element("ram:NetPriceProductTradePrice") {
                    w.leaf("ram:ChargeAmount", line.unitPrice.xmlValue)
                }
            }
            w.element("ram:SpecifiedLineTradeDelivery") {
                w.leaf("ram:BilledQuantity", line.quantity.rateString, [("unitCode", line.unitCode)])
            }
            w.element("ram:SpecifiedLineTradeSettlement") {
                w.element("ram:ApplicableTradeTax") {
                    w.leaf("ram:TypeCode", "VAT")
                    w.leaf("ram:CategoryCode", line.vatCategory.rawValue)
                    let rate = line.vatCategory.requiresExemptionReason ? Decimal.zero : line.vatRate
                    w.leaf("ram:RateApplicablePercent", rate.rateString)
                }
                // A line discount is an allowance, with ChargeIndicator false.
                if let discount = line.discount, !discount.isZero {
                    w.element("ram:SpecifiedTradeAllowanceCharge") {
                        w.element("ram:ChargeIndicator") {
                            w.leaf("udt:Indicator", "false")
                        }
                        w.leaf("ram:ActualAmount", discount.rounded.xmlValue)
                    }
                }
                w.element("ram:SpecifiedTradeSettlementLineMonetarySummation") {
                    w.leaf("ram:LineTotalAmount", line.netAmount.xmlValue)
                }
            }
        }
    }

    private func headerAgreement(_ w: XMLWriter, _ invoice: InvoiceDocument) {
        w.element("ram:ApplicableHeaderTradeAgreement") {
            w.optionalLeaf("ram:BuyerReference", invoice.buyerReference)
            tradeParty(w, invoice.seller, element: "ram:SellerTradeParty")
            tradeParty(w, invoice.buyer, element: "ram:BuyerTradeParty")
        }
    }

    private func tradeParty(_ w: XMLWriter, _ party: TradeParty, element: String) {
        w.element(element) {
            w.leaf("ram:Name", party.name)
            if !party.legalRegistrationID.isEmpty {
                w.element("ram:SpecifiedLegalOrganization") {
                    w.leaf("ram:ID", party.legalRegistrationID)
                }
            }
            if profile == .en16931 || profile == .extended,
               !party.contactName.isEmpty || !party.email.isEmpty || !party.phone.isEmpty {
                w.element("ram:DefinedTradeContact") {
                    w.optionalLeaf("ram:PersonName", party.contactName)
                    if !party.phone.isEmpty {
                        w.element("ram:TelephoneUniversalCommunication") {
                            w.leaf("ram:CompleteNumber", party.phone)
                        }
                    }
                    if !party.email.isEmpty {
                        w.element("ram:EmailURIUniversalCommunication") {
                            w.leaf("ram:URIID", party.email)
                        }
                    }
                }
            }
            w.element("ram:PostalTradeAddress") {
                w.optionalLeaf("ram:PostcodeCode", party.address.postcode)
                w.optionalLeaf("ram:LineOne", party.address.line1)
                w.optionalLeaf("ram:LineTwo", party.address.line2)
                w.optionalLeaf("ram:CityName", party.address.city)
                w.leaf("ram:CountryID", party.address.countryCode)
                w.optionalLeaf("ram:CountrySubDivisionName", party.address.subdivision)
            }
            if !party.email.isEmpty {
                w.element("ram:URIUniversalCommunication") {
                    w.leaf("ram:URIID", party.email, [("schemeID", "EM")])
                }
            }
            if !party.vatID.isEmpty {
                w.element("ram:SpecifiedTaxRegistration") {
                    w.leaf("ram:ID", party.vatID, [("schemeID", "VA")])
                }
            }
            if !party.taxRegistrationID.isEmpty {
                w.element("ram:SpecifiedTaxRegistration") {
                    w.leaf("ram:ID", party.taxRegistrationID, [("schemeID", "FC")])
                }
            }
        }
    }

    private func headerDelivery(_ w: XMLWriter, _ invoice: InvoiceDocument) {
        w.element("ram:ApplicableHeaderTradeDelivery") {
            if let delivery = invoice.deliveryDate {
                w.element("ram:ActualDeliverySupplyChainEvent") {
                    w.element("ram:OccurrenceDateTime") {
                        w.leaf("udt:DateTimeString", dateString(delivery), [("format", "102")])
                    }
                }
            }
        }
    }

    private func headerSettlement(_ w: XMLWriter, _ invoice: InvoiceDocument, _ totals: InvoiceTotals) {
        w.element("ram:ApplicableHeaderTradeSettlement") {
            w.leaf("ram:InvoiceCurrencyCode", invoice.currency.code)

            w.element("ram:SpecifiedTradeSettlementPaymentMeans") {
                w.leaf("ram:TypeCode", invoice.paymentMeans.rawValue)
                if !invoice.bank.iban.isEmpty {
                    w.element("ram:PayeePartyCreditorFinancialAccount") {
                        w.leaf("ram:IBANID", invoice.bank.iban)
                        w.optionalLeaf("ram:AccountName", invoice.bank.accountName)
                    }
                    if !invoice.bank.bic.isEmpty {
                        w.element("ram:PayeeSpecifiedCreditorFinancialInstitution") {
                            w.leaf("ram:BICID", invoice.bank.bic)
                        }
                    }
                }
            }

            for row in totals.breakdown {
                w.element("ram:ApplicableTradeTax") {
                    w.leaf("ram:CalculatedAmount", row.taxAmount.xmlValue)
                    w.leaf("ram:TypeCode", "VAT")
                    w.optionalLeaf("ram:ExemptionReason", row.exemptionReason)
                    w.leaf("ram:BasisAmount", row.taxableBase.xmlValue)
                    w.leaf("ram:CategoryCode", row.category.rawValue)
                    w.leaf("ram:RateApplicablePercent", row.rate.rateString)
                }
            }

            if invoice.dueDate != nil || !invoice.paymentTerms.isEmpty {
                w.element("ram:SpecifiedTradePaymentTerms") {
                    w.optionalLeaf("ram:Description", invoice.paymentTerms)
                    if let due = invoice.dueDate {
                        w.element("ram:DueDateDateTime") {
                            w.leaf("udt:DateTimeString", dateString(due), [("format", "102")])
                        }
                    }
                }
            }

            w.element("ram:SpecifiedTradeSettlementHeaderMonetarySummation") {
                w.leaf("ram:LineTotalAmount", totals.lineTotal.xmlValue)
                w.leaf("ram:TaxBasisTotalAmount", totals.taxBasisTotal.xmlValue)
                w.leaf("ram:TaxTotalAmount", totals.taxTotal.xmlValue,
                       [("currencyID", invoice.currency.code)])
                w.leaf("ram:GrandTotalAmount", totals.grandTotal.xmlValue)
                if !totals.prepaid.isZero {
                    w.leaf("ram:TotalPrepaidAmount", totals.prepaid.xmlValue)
                }
                w.leaf("ram:DuePayableAmount", totals.duePayable.xmlValue)
            }

            if let preceding = invoice.precedingInvoiceNumber, !preceding.isEmpty {
                w.element("ram:InvoiceReferencedDocument") {
                    w.leaf("ram:IssuerAssignedID", preceding)
                }
            }
        }
    }

    // MARK: - Helpers

    /// CCYYMMDD, the "102" date format qualifier.
    private func dateString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
