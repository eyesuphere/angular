# InvoiceApp

A local-first macOS invoicing app for freelancers and small studios, built around
**Factur-X / ZUGFeRD e-invoicing** rather than around producing a pretty PDF.

## Why this shape

Market research (Oct 2026) put the native-Mac invoicing field in two camps: a handful
of established native apps (GrandTotal, at €59–149/yr; Cakedesk, €69 once) and a crowd
of recent SwiftUI + iCloud apps on the Mac App Store competing on price and polish.
Almost all of them produce a plain PDF.

Meanwhile the EU mandates are live:

| Jurisdiction | Must *receive* | Must *send* |
|---|---|---|
| France | 1 Sep 2026 (all businesses) | 1 Sep 2026 large/mid, Sep 2027 small |
| Germany | since Jan 2025 | Jan 2027 (>€800k), Jan 2028 all |

Both accept **Factur-X / ZUGFeRD** — the same Franco-German hybrid standard under two
names: a human-readable PDF with EN 16931 CII XML embedded *inside* it. A plain PDF is
already a legacy artifact for cross-border B2B work.

So this app competes on compliance plus local data plus buy-once, not on templates.

## Getting it open

```sh
make bootstrap      # checks Xcode, installs xcodegen
make project        # generates Invoices.xcodeproj from project.yml
make open           # opens it
```

Or without Xcode at all, for the core library:

```sh
swift test          # runs the InvoiceCore suite
```

**The `.xcodeproj` is generated, not committed.** `project.yml` is the project; a
pbxproj is a thousand lines of opaque UUIDs that conflicts on every branch and cannot be
reviewed. Build settings live in `Config/*.xcconfig` for the same reason, so they survive
regeneration and show up in a diff.

Three targets: the `Invoices` app, `InvoiceCoreTests` (also runnable via SwiftPM), and
`InvoicesAppTests` for the SwiftData and service layer. The `Invoices-All` scheme runs
all of it.

## Layout

```
project.yml                  The project. Run `make project` to generate the .xcodeproj
Config/*.xcconfig            Build settings, reviewable
Makefile, scripts/           bootstrap, ci
Package.swift                SwiftPM manifest for the core library

Sources/InvoiceCore/         Platform-independent: no SwiftUI, SwiftData or AppKit
  Money.swift                Decimal money, currency minor units, EN 16931 formatting
  InvoiceDocument.swift      Value types: parties, lines, VAT categories, unit codes
  InvoiceTotals.swift        The EN 16931 calculation model and VAT breakdown
  InvoiceNumbering.swift     Gap-free sequential numbering
  Validation.swift           Pre-flight business rules + IBAN checksum
  XMLWriter.swift            Order-preserving XML emitter
  FacturX.swift              CII XML generation, all five profiles
  FacturXPDFAttacher.swift   PDF/A-3 embedding via incremental update
  PDFStructure.swift         Just enough PDF parsing to do that safely

App/                         The macOS app
  App.swift, Models.swift, InvoiceService.swift, Views/, Export/
  Info.plist, Invoices.entitlements, Resources/

Tests/InvoiceCoreTests/      Core suite + the reference XML fixture
AppTests/                    SwiftData models and InvoiceService, in-memory store
```

InvoiceCore is consumed as a local Swift *package*, not as loose files compiled into the
app. That keeps `import InvoiceCore` meaningful and the module boundary real — the app
physically cannot reach into the core's internals.

## Build status — read this first

**Nothing here has been compiled.** It was written in a Linux container with no Swift
toolchain (`download.swift.org` is blocked by the environment's network policy), and no
Xcode. So:

- `swift build`, `swift test`, `xcodegen generate` and `xcodebuild` have **never run**.
  Expect to fix compile errors on the first pass.
- The test suites are written but **unrun**. Treat them as a specification first and a
  passing suite second.
- `Config/Shared.xcconfig` pins Swift language mode 5 deliberately. Mode 6 turns
  actor-isolation problems into errors, and fighting strict concurrency and
  first-compile errors simultaneously is a bad trade. Raise it once this builds, and
  expect real work around the `@MainActor` boundaries in `ExportService` and
  `InvoicePDFRenderer`.

What *was* verified, and how:

| Claim | How it was checked | Result |
|---|---|---|
| The PDF incremental-update layout is valid | Byte layout and xref maths ported to Python, run against **pypdf 6.17** | Catalogue keeps `/Pages`, gains `/AF`, `/Names/EmbeddedFiles`, `/Metadata`; payload round-trips byte-identical; page tree intact |
| The reference CII XML is well-formed | `xmllint --noout` | Passes, 117 elements |
| The reference totals satisfy EN 16931 cross-field rules | Independent `lxml` + `Decimal` check | `1899.95 + 360.99 = 2260.94`, `− 500.00 = 1760.94`; basis matches breakdown |
| `Info.plist`, entitlements, asset catalogs are well-formed | `plistlib` and `json` parse | All valid |
| `project.yml` is valid YAML with the expected targets | `yaml.safe_load` | 3 targets, 1 scheme, 1 local package |
| `Makefile` and shell scripts parse | `make help`, `bash -n` | Clean |

That is structure and syntax, not semantics: nothing confirms XcodeGen accepts the spec
or that the Swift compiles.

## Before you ship

1. **Validate against the real rule set.** Structural modelling is not certification.
   Run the output through the official EN 16931 artefacts:
   ```sh
   # Schematron + XSD from ConnectingEurope/eInvoicing-EN16931
   java -jar saxon.jar -s:factur-x.xml -xsl:EN16931-CII-validation.xsl
   # and a PDF/A-3 check
   verapdf --flavour 3b invoice.pdf
   ```
   Also try the Factur-X community validator and, for France, a PDP sandbox.
2. **Ship an sRGB ICC profile** as `sRGB-IEC61966-2.1.icc` in the app bundle. Without
   it `FacturXPDFAttacher` omits the output intent and says so in `Result.warnings`;
   the Factur-X payload is still readable but the file does not declare PDF/A-3.
3. **Know what PDF/A-3 means here.** `declaresPDFA3Conformance` means the envelope is
   complete — XMP `pdfaid` plus an output intent. It does *not* mean the rendered page
   satisfies PDF/A (fonts fully embedded, no transparency), which a Core Graphics
   rendering does not guarantee. Verify with veraPDF.
4. **Sandbox entitlements** are already set: the app is sandboxed with
   `files.user-selected.read-write` for the save panel, and deliberately *without* any
   network entitlement. Local-first is a product claim, and the entitlements file is
   where it is enforced rather than merely asserted. Adding French PDP transmission will
   need `network.client`, which is the point at which the claim changes.
5. **Set a real bundle identifier and team.** `Config/Shared.xcconfig` ships
   `com.example` and no `DEVELOPMENT_TEAM`, so the project opens and builds locally
   without credentials.
6. **Cross-reference streams.** The attacher handles classic xref tables, which is what
   Core Graphics emits, and refuses anything else rather than corrupting it. If you
   swap the renderer, revisit `PDFStructure`.

## Design decisions worth knowing

**`Decimal`, never `Double`.** A binary float cannot represent 0.10, so totals built
from floats drift. On an invoice that drift is a legal defect. `Money` keeps an exact
`Decimal` and rounds only where EN 16931 says a value is rounded.

**Rounding order is specified, not incidental.** Line nets round first, group by VAT
category and rate, then VAT is computed on the *rounded group base*. Computing VAT
per line and summing gives off-by-a-cent totals that validators reject — there is a
test for exactly this.

**Numbering only moves forward.** `count + 1` reuses a number as soon as anything is
deleted, which most EU jurisdictions prohibit. The sequence keeps a persisted
watermark; deleting a draft does not free its number.

**Issued invoices are locked.** Issuing consumes a number, snapshots both parties onto
the record, and locks the document. If the client later moves office, the issued
invoice still shows the address it was sent to. Corrections go through a credit note.

**Deleting a client never deletes their invoices.** `.nullify`, not `.cascade`: those
are accounting records with a retention period.

**Deletes resolve objects before mutating.** `offsets.forEach { delete(array[$0]) }`
re-reads a live query after the first delete has already shifted it, so the second
index points at the wrong row.

**Bad numeric input stays visible.** `TextField(value:format:)` turns a typo into zero
with no feedback — a silent change to what the customer owes. `MoneyField` keeps the
text, flags it, and only writes through when it parses.

**VAT category is a required choice, not an inferred one.** Reverse charge vs. exempt
vs. zero-rated is the most common compliance failure for a freelancer billing across a
border, and each needs different wording on the page.

## Known gaps

- No recurring invoices, time tracking, expenses or multi-currency conversion.
- No payment-provider integration (Stripe/SEPA direct debit).
- No French PDP transmission — the mandate requires routing through an accredited
  platform, which is an API integration per provider, not a file format.
- Credit notes copy the original's lines; they do not yet support partial credits.
- `InvoiceDocument` is `Codable` but there is no import path (no CII or CSV reader).
- Pagination uses fixed row counts rather than measuring rendered height, so a line
  with a very long description can still overflow. Measure with `ImageRenderer` if it
  matters.
