# Install

A snapshot of the source. There is no built app and no installer — you compile it
yourself, and the first compile will need fixing (see *Expect errors*, below).

## Requirements

| | |
|---|---|
| macOS | 14.0 or later (SwiftData, `@Bindable`, `ContentUnavailableView`) |
| Xcode | 15 or later, with the Command Line Tools selected |
| Homebrew | only to install XcodeGen; see below if you'd rather not |

Check Xcode is selected:

```sh
xcode-select -p          # should print a path inside Xcode.app
xcodebuild -version
```

If it prints `/Library/Developer/CommandLineTools`, point it at the full Xcode:

```sh
sudo xcode-select --switch /Applications/Xcode.app
```

## 1. Quickest useful step: run the core tests

This needs no Xcode project, no signing and no XcodeGen. Do this first — it exercises the
money arithmetic, the EN 16931 totals, the numbering, the validation rules, the Factur-X
XML and the PDF attachment.

```sh
cd InvoiceApp
swift test
```

## 2. Generate and open the Xcode project

```sh
make bootstrap    # verifies Xcode, installs xcodegen via Homebrew
make project      # generates Invoices.xcodeproj from project.yml
make open
```

There is no `.xcodeproj` in this archive because it is a build artifact: `project.yml` is
the project definition. Regenerate it any time; never hand-edit the generated file,
because the next `make project` discards your changes.

**Without Homebrew:** download XcodeGen from
<https://github.com/yonaskolb/XcodeGen/releases>, put `xcodegen` on your `PATH`, then run
`make project`. Or `mint install yonaskolb/XcodeGen`.

In Xcode, pick the **Invoices-All** scheme. ⌘R runs the app, ⌘U runs all three test
targets.

Or stay on the command line:

```sh
make build
make test
make help     # everything available
```

## 3. Expect errors on the first compile

**This code has never been compiled.** It was written in a Linux container with no Swift
toolchain and no Xcode, so `swift build`, `xcodegen` and `xcodebuild` have never run
against it. Logic was verified by other means (see README), but nothing has type-checked.

Where the errors are most likely, in order:

1. `Money.formatted(locale:)` — the `Decimal.FormatStyle.Currency` modifier chain.
2. `Money.plainString` — the `NSDecimalString` pointer call.
3. `InvoiceService.issuedNumbers()` — SwiftData's `#Predicate` macro is fussy.
4. `@MainActor` boundaries in `ExportService` and `InvoicePDFRenderer`.
5. `AppTests` host wiring, if Xcode wants a signing team where `xcodebuild` does not.

`Config/Shared.xcconfig` pins Swift language mode 5 on purpose. Mode 6 turns
actor-isolation problems into hard errors, and fighting those at the same time as
first-compile errors is a bad trade. Raise it after this builds.

## 4. Signing

`Config/Shared.xcconfig` ships `PRODUCT_BUNDLE_IDENTIFIER_PREFIX = com.example` and no
`DEVELOPMENT_TEAM`, so the project opens and builds for local use without an Apple
account. Change both before you distribute anything.

Command-line builds skip signing entirely:

```sh
xcodebuild build -project Invoices.xcodeproj -scheme Invoices-All \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## 5. Optional: the sRGB ICC profile

Without it, exports carry a complete and readable Factur-X payload but do not declare
PDF/A-3, and `ExportService` says so in its warnings.

```sh
cp "/System/Library/ColorSync/Profiles/sRGB Profile.icc" \
   App/Resources/sRGB-IEC61966-2.1.icc
make project
```

See `App/Resources/README.md` for the licensing note and other sources.

## 6. Where your data lives

A single local SwiftData store under `~/Library/Containers/`, keyed by the bundle
identifier. No account, no sync, no server — the app has no network entitlement at all.
Back that directory up; nothing else does.

## Before trusting an invoice from this

Two checks the test suite cannot do for you:

- **EN 16931 Schematron.** The XML is structurally modelled against the spec, not
  certified against it. Validate with the artefacts from
  `ConnectingEurope/eInvoicing-EN16931`.
- **`verapdf --flavour 3b`** on an exported Factur-X PDF.

Details in README under *Before you ship*.
