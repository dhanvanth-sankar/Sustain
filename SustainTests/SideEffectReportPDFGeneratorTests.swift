import XCTest
@testable import Sustain

final class SideEffectReportPDFGeneratorTests: XCTestCase {

    func testGenerateTemporaryFile_writesANonEmptyPDFFile() {
        let rows = [
            SideEffectReportPDFGenerator.SymptomRow(displayName: "Nausea", count: 3, averageSeverity: 2.3),
            SideEffectReportPDFGenerator.SymptomRow(displayName: "Fatigue", count: 1, averageSeverity: 4.0),
        ]
        let url = SideEffectReportPDFGenerator.generateTemporaryFile(
            rows: rows, dateRangeText: "Jul 1 – Jul 30, 2026", disclaimer: MedicalSources.disclaimer
        )

        XCTAssertNotNil(url)
        guard let url else { return }
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try? Data(contentsOf: url)
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data?.count ?? 0, 0)
        // The first bytes of any valid PDF are the literal "%PDF-" file-format
        // signature — a cheap, real check that this wrote an actual PDF and not
        // just arbitrary bytes with a .pdf extension.
        let header = data?.prefix(5)
        XCTAssertEqual(header.map { String(decoding: $0, as: UTF8.self) }, "%PDF-")
    }

    func testGenerateTemporaryFile_handlesEmptyRowsWithoutCrashing() {
        let url = SideEffectReportPDFGenerator.generateTemporaryFile(
            rows: [], dateRangeText: nil, disclaimer: MedicalSources.disclaimer
        )
        XCTAssertNotNil(url)
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    func testGenerateTemporaryFile_eachCallProducesAUniqueFile() {
        let rows = [SideEffectReportPDFGenerator.SymptomRow(displayName: "Nausea", count: 1, averageSeverity: 1.0)]
        let first = SideEffectReportPDFGenerator.generateTemporaryFile(rows: rows, dateRangeText: nil, disclaimer: "")
        let second = SideEffectReportPDFGenerator.generateTemporaryFile(rows: rows, dateRangeText: nil, disclaimer: "")
        XCTAssertNotEqual(first, second)
        for url in [first, second].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
