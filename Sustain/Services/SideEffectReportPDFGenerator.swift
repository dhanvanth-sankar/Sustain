import UIKit

/// A real, downloadable PDF export of the side-effect pattern summary — the
/// "bring this to your next appointment" promise `SideEffectSummaryCard` has
/// always made in its copy. It previously only offered a plain-text `ShareLink`,
/// which works but isn't the tangible artifact two independent competitor
/// teardowns specifically called out as a praised feature: Pokii's customizable
/// PDF reports and Vita AI's date-range PDF export (`Documentation/
/// sustain-pros-and-cons.json` comp-015 and comp-024). This adds the PDF as a
/// second share option alongside the existing text share, rather than replacing
/// it — plain text is still the faster path for pasting into a Messages thread
/// or a portal's free-text field, and there was no reason to remove a working
/// option to add a better one.
///
/// Built with `UIGraphicsPDFRenderer` (first-party UIKit, already a dependency
/// via `ImagePicker.swift`) — no new package, matching this project's
/// zero-third-party-SPM-dependency posture (`PROJECT_HANDOFF.md` Decision 2).
enum SideEffectReportPDFGenerator {
    struct SymptomRow {
        let displayName: String
        let count: Int
        let averageSeverity: Double
    }

    /// US Letter at 72pt/inch, matching what `UIGraphicsPDFRenderer` and every
    /// standard printing/viewing pipeline expects by default.
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 48

    /// Renders the report and writes it to a fresh temporary file, since sharing
    /// a PDF via `ShareLink` is simplest as a file `URL` (`URL` conforms to
    /// `Transferable` out of the box; raw `Data` would need its own UTType
    /// wrapper for no real benefit here). Each call gets a unique filename so a
    /// second share while the first is still resolving can't collide with or
    /// overwrite it. Returns `nil` only if the temporary directory somehow isn't
    /// writable — the caller falls back to hiding the PDF share option rather
    /// than presenting a broken one.
    static func generateTemporaryFile(
        rows: [SymptomRow],
        dateRangeText: String?,
        disclaimer: String,
        generatedAt: Date = .now
    ) -> URL? {
        let data = renderPDF(rows: rows, dateRangeText: dateRangeText, disclaimer: disclaimer, generatedAt: generatedAt)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sustain-side-effect-summary-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func renderPDF(rows: [SymptomRow], dateRangeText: String?, disclaimer: String, generatedAt: Date) -> Data {
        let pageRect = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        return renderer.pdfData { context in
            // Real bug, reported directly via a generated PDF where every line of
            // text (title, table header, and especially the data rows) rendered
            // as near-invisible light gray on the white page. Root cause: every
            // color below (`.label`, `.secondaryLabel`, `.tertiaryLabel`,
            // `.separator`) is a *dynamic* system color, and `UIGraphicsPDFRenderer`
            // draws outside any view's trait environment — it doesn't inherit the
            // app's current light/dark appearance the way a screen-drawn view
            // would. Dynamic colors resolved with no explicit trait collection
            // fall back to whatever `UITraitCollection.current` happens to be at
            // that moment, which follows the *device's* current system
            // appearance, not this PDF's. A PDF page is always a plain white
            // page, though — it never adapts to Dark Mode the way a screen does
            // — so generating this report while the device is in Dark Mode
            // produced near-white "dark mode" text colors on a page that stayed
            // white regardless, which is exactly the near-invisible result seen.
            //
            // Fixed by pinning a fixed light `UITraitCollection` as current for
            // the entire drawing pass via `performAsCurrent`, so every `.label`/
            // `.secondaryLabel`/`.tertiaryLabel`/`.separator` lookup below always
            // resolves to its light-appearance (dark-on-white) variant, regardless
            // of whatever appearance the device happens to be in at share time.
            // This is a one-line fix precisely because it doesn't require
            // replacing any of the semantic colors below with hardcoded RGB
            // values — the light/dark *hierarchy* between title/body/tertiary
            // text is still worth keeping, it just needs to always resolve to
            // the same (light) side of that hierarchy for a document that's
            // permanently on a white background.
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                context.beginPage()
                var y = margin

                y = draw("Side-effect summary", at: y, font: .boldSystemFont(ofSize: 22))

                // Changed from `.secondaryLabel`/`.tertiaryLabel` to `.label`
                // (2026-08-03, requested directly: "make all text pop out
                // more, all black maybe"). The lighter grays were a
                // deliberate visual hierarchy — de-emphasizing metadata
                // relative to the title and table data — but for a document
                // whose whole purpose is being handed to (or read by) a
                // prescriber, maximum legibility on a printed or
                // small-screen page wins over that subtlety. Hierarchy is
                // still conveyed through size and weight (this is 10-12pt
                // regular vs. the 22pt bold title), just no longer through
                // reduced contrast.
                let subtitle = dateRangeText.map { "Period: \($0)" } ?? "All logged history"
                y = draw(subtitle, at: y, font: .systemFont(ofSize: 12), color: .label)
                y = draw(
                    "Generated \(generatedAt.formatted(.dateTime.month(.wide).day().year().hour().minute())) by Sustain",
                    at: y, font: .systemFont(ofSize: 10), color: .label
                )

                y += 20
                y = drawDivider(at: y)
                y += 12

                y = drawTableHeader(at: y)
                y += 6
                y = drawDivider(at: y)
                y += 10

                if rows.isEmpty {
                    y = draw("No side effects logged in this period.", at: y, font: .italicSystemFont(ofSize: 12), color: .label)
                } else {
                    for row in rows {
                        y = drawTableRow(row, at: y)
                        // Simple, single-page report — this app's data volume (a
                        // personal tracker's realistic symptom-type count) never gets
                        // close to needing real multi-page pagination, so this isn't
                        // built. If it ever does, `y` crossing `pageSize.height -
                        // margin` here is the signal a real `context.beginPage()`
                        // pagination pass would need to key off.
                        if y > pageSize.height - margin - 60 { break }
                    }
                }

                y += 24
                y = drawDivider(at: y)
                y += 14

                let disclaimerRect = CGRect(x: margin, y: y, width: pageSize.width - margin * 2, height: 120)
                (disclaimer as NSString).draw(
                    in: disclaimerRect,
                    withAttributes: [.font: UIFont.italicSystemFont(ofSize: 10), .foregroundColor: UIColor.label]
                )
            }
        }
    }

    // MARK: - Drawing helpers

    private static let symptomColumnX = margin
    private static let countColumnX: CGFloat = 340
    private static let severityColumnX: CGFloat = 420

    @discardableResult
    private static func draw(_ text: String, at y: CGFloat, font: UIFont, color: UIColor = .label) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (text as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attributes)
        return y + font.lineHeight + 6
    }

    @discardableResult
    private static func drawDivider(at y: CGFloat) -> CGFloat {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
        UIColor.separator.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        return y
    }

    @discardableResult
    private static func drawTableHeader(at y: CGFloat) -> CGFloat {
        let font = UIFont.boldSystemFont(ofSize: 11)
        // Changed from `.secondaryLabel` to `.label`, same reasoning as
        // above — bold weight already distinguishes this from the data rows
        // below it, so it doesn't also need reduced contrast to read as a
        // header.
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
        ("Symptom" as NSString).draw(at: CGPoint(x: symptomColumnX, y: y), withAttributes: attributes)
        ("Times logged" as NSString).draw(at: CGPoint(x: countColumnX, y: y), withAttributes: attributes)
        ("Avg. severity" as NSString).draw(at: CGPoint(x: severityColumnX, y: y), withAttributes: attributes)
        return y + font.lineHeight
    }

    @discardableResult
    private static func drawTableRow(_ row: SymptomRow, at y: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 12)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
        (row.displayName as NSString).draw(at: CGPoint(x: symptomColumnX, y: y), withAttributes: attributes)
        ("\(row.count)" as NSString).draw(at: CGPoint(x: countColumnX, y: y), withAttributes: attributes)
        (String(format: "%.1f / 5", row.averageSeverity) as NSString).draw(at: CGPoint(x: severityColumnX, y: y), withAttributes: attributes)
        return y + font.lineHeight + 10
    }
}
