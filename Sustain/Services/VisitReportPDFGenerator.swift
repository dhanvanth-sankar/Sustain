import UIKit

/// A comprehensive, downloadable "bring this to your appointment" PDF —
/// medication/dose history, weight trend, protein adherence, side effects,
/// and lab results in one document, rather than the side-effects-only export
/// `SideEffectReportPDFGenerator` has offered since 2026-08-03.
///
/// Added 2026-08-07, closing a real, named gap: `Sustain-Subscription-
/// Payer-Features-Report-2026-08.md` §5 found that multiple direct GLP-1
/// competitors (Easy GLP-1 Tracker, GLP-1 Tracker by Wiser Apps, Shotsy) now
/// all export a *combined* doctor-visit report, while Sustain's own export
/// covered only one data type — the narrowest version of this feature in the
/// category despite the app already holding every piece of data a combined
/// report needs.
///
/// Deliberately a **separate generator, not a rewrite of
/// `SideEffectReportPDFGenerator`**: that file is still used on its own by
/// `SideEffectSummaryCard` for a quick, single-topic share, and changing its
/// shape to accommodate five sections would have made that simpler,
/// more-frequently-used case more complex for no benefit to it. Both share
/// the same drawing conventions (the dark-mode-invisible-text fix via a
/// pinned light `UITraitCollection`, `UIGraphicsPDFRenderer`, no new
/// dependency) since both were built against the same real bug the older
/// file's header comment documents.
///
/// Unlike the single-page side-effect report, this one genuinely needs
/// pagination — full history across five data types can exceed one US
/// Letter page even for a moderately active user — so this file adds real
/// `context.beginPage()` pagination, which the older, shorter report never
/// needed.
enum VisitReportPDFGenerator {
    struct TextRow {
        let leading: String
        let trailing: String
    }

    struct SymptomRow {
        let displayName: String
        let count: Int
        let averageSeverity: Double
    }

    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 48
    private static let bottomThreshold: CGFloat = 792 - 48 - 40

    /// Mirrors `SideEffectReportPDFGenerator.generateTemporaryFile`'s exact
    /// contract: a unique-per-call temporary file URL (so a second share
    /// while the first is still resolving can't collide), `nil` only if the
    /// temporary directory somehow isn't writable.
    static func generateTemporaryFile(
        profileSummary: TextRow,
        dateRangeText: String?,
        doseRows: [TextRow],
        weightRows: [TextRow],
        proteinSummaryRows: [TextRow],
        symptomRows: [SymptomRow],
        labRows: [TextRow],
        disclaimer: String,
        generatedAt: Date = .now
    ) -> URL? {
        let data = renderPDF(
            profileSummary: profileSummary,
            dateRangeText: dateRangeText,
            doseRows: doseRows,
            weightRows: weightRows,
            proteinSummaryRows: proteinSummaryRows,
            symptomRows: symptomRows,
            labRows: labRows,
            disclaimer: disclaimer,
            generatedAt: generatedAt
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sustain-visit-report-\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func renderPDF(
        profileSummary: TextRow,
        dateRangeText: String?,
        doseRows: [TextRow],
        weightRows: [TextRow],
        proteinSummaryRows: [TextRow],
        symptomRows: [SymptomRow],
        labRows: [TextRow],
        disclaimer: String,
        generatedAt: Date
    ) -> Data {
        let pageRect = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        return renderer.pdfData { context in
            // Same fix, same reason, as `SideEffectReportPDFGenerator` —
            // `UIGraphicsPDFRenderer` draws outside any view's trait
            // environment, so every dynamic `.label`/`.secondaryLabel`/
            // `.separator` lookup below needs a pinned light trait
            // collection or it silently resolves to the device's *current*
            // appearance instead of this permanently-white page's.
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                context.beginPage()
                var y = margin

                y = draw("Visit report", at: y, font: .boldSystemFont(ofSize: 22))
                let subtitle = dateRangeText.map { "Period: \($0)" } ?? "All logged history"
                y = draw(subtitle, at: y, font: .systemFont(ofSize: 12))
                y = draw(
                    "Generated \(generatedAt.formatted(.dateTime.month(.wide).day().year().hour().minute())) by Sustain",
                    at: y, font: .systemFont(ofSize: 10)
                )
                y += 8
                y = draw(profileSummary.leading, at: y, font: .systemFont(ofSize: 12, weight: .medium))

                y = section(context, "Recent doses", rows: doseRows, y: y, emptyText: "No doses logged in this period.")
                y = section(context, "Weight", rows: weightRows, y: y, emptyText: "No weight entries in this period.")
                y = section(context, "Protein adherence", rows: proteinSummaryRows, y: y, emptyText: "No protein entries in this period.")
                y = symptomSection(context, symptomRows, y: y)
                y = section(context, "Lab results", rows: labRows, y: y, emptyText: "No lab results in this period.")

                y = ensureSpace(context, y, needed: 130)
                y += 10
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

    // MARK: - Section drawing

    /// Draws a titled section of two-column rows (e.g. "Aug 5" / "1.7 mg"),
    /// paginating automatically if the section's content would run off the
    /// bottom of the current page. Returns the y-position after the section.
    @discardableResult
    private static func section(
        _ context: UIGraphicsPDFRendererContext,
        _ title: String,
        rows: [TextRow],
        y: CGFloat,
        emptyText: String
    ) -> CGFloat {
        var y = ensureSpace(context, y, needed: 50)
        y += 14
        y = drawDivider(at: y)
        y += 10
        y = draw(title, at: y, font: .boldSystemFont(ofSize: 14))

        if rows.isEmpty {
            y = draw(emptyText, at: y, font: .italicSystemFont(ofSize: 11), color: .secondaryLabel)
            return y
        }

        for row in rows {
            y = ensureSpace(context, y, needed: 24)
            y = drawTwoColumnRow(row, at: y)
        }
        return y
    }

    /// Side effects get their own section shape (three columns, matching
    /// `SideEffectReportPDFGenerator`'s existing table) rather than the
    /// generic two-column layout every other section uses, so a symptom's
    /// count and average severity are both visible per row, not just one.
    @discardableResult
    private static func symptomSection(_ context: UIGraphicsPDFRendererContext, _ rows: [SymptomRow], y: CGFloat) -> CGFloat {
        var y = ensureSpace(context, y, needed: 60)
        y += 14
        y = drawDivider(at: y)
        y += 10
        y = draw("Side effects", at: y, font: .boldSystemFont(ofSize: 14))

        if rows.isEmpty {
            y = draw("No side effects logged in this period.", at: y, font: .italicSystemFont(ofSize: 11), color: .secondaryLabel)
            return y
        }

        let headerFont = UIFont.boldSystemFont(ofSize: 10)
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: UIColor.secondaryLabel]
        y = ensureSpace(context, y, needed: 24)
        ("Symptom" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: headerAttrs)
        ("Times logged" as NSString).draw(at: CGPoint(x: 340, y: y), withAttributes: headerAttrs)
        ("Avg. severity" as NSString).draw(at: CGPoint(x: 460, y: y), withAttributes: headerAttrs)
        y += headerFont.lineHeight + 6

        for row in rows {
            y = ensureSpace(context, y, needed: 22)
            let font = UIFont.systemFont(ofSize: 11)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
            (row.displayName as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
            ("\(row.count)" as NSString).draw(at: CGPoint(x: 340, y: y), withAttributes: attrs)
            (String(format: "%.1f / 5", row.averageSeverity) as NSString).draw(at: CGPoint(x: 460, y: y), withAttributes: attrs)
            y += font.lineHeight + 8
        }
        return y
    }

    /// Starts a fresh page (resetting `y` to the top margin) if `needed`
    /// points of vertical space aren't left on the current page. This is
    /// the one real difference from `SideEffectReportPDFGenerator`, whose
    /// single-page report never has enough content to need it — a combined
    /// five-section report over full history routinely does.
    private static func ensureSpace(_ context: UIGraphicsPDFRendererContext, _ y: CGFloat, needed: CGFloat) -> CGFloat {
        guard y + needed > bottomThreshold else { return y }
        context.beginPage()
        return margin
    }

    // MARK: - Primitive drawing helpers (mirrors `SideEffectReportPDFGenerator`)

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
    private static func drawTwoColumnRow(_ row: TextRow, at y: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 11)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
        (row.leading as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attributes)
        (row.trailing as NSString).draw(at: CGPoint(x: 340, y: y), withAttributes: attributes)
        return y + font.lineHeight + 8
    }
}
