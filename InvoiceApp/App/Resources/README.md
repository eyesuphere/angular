# App resources

## sRGB-IEC61966-2.1.icc — not committed

PDF/A requires an `OutputIntent`, and an `OutputIntent` requires an embedded ICC
profile. `FacturXPDFAttacher` looks for this file in the app bundle:

```
App/Resources/sRGB-IEC61966-2.1.icc
```

Without it, exports still carry a complete, readable Factur-X payload, but the file does
not declare PDF/A-3 and `ExportService.Outcome.warnings` says so.

It is not committed because the redistributable profiles have their own licence terms
worth reading rather than inheriting by accident. Get one from:

- the ICC's own site (`http://www.color.org/srgbprofiles.xalter`), or
- the `icc-profiles-free` package on most Linux distributions, or
- macOS itself: `/System/Library/ColorSync/Profiles/sRGB Profile.icc`

Drop it in this directory under the exact name above, then add it to the `Invoices`
target's resources — `project.yml` already includes everything under `App/`, so
regenerating the project picks it up.

Verify afterwards with `verapdf --flavour 3b` on an exported invoice.
