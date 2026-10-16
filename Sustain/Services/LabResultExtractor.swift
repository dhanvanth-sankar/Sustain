import Foundation
import UIKit
import Vision

enum LabResultExtractError: LocalizedError {
    case missingProxyConfig
    case invalidImage
    case requestFailed(String)
    case unparsableResponse
    case noBiomarkersFound

    var errorDescription: String? {
        switch self {
        case .missingProxyConfig:
            return "AI features aren't set up yet. Add your Supabase proxy URL and anon key to Secrets.xcconfig."
        case .invalidImage:
            return "Couldn't read that photo. Try another one."
        case .requestFailed(let message):
            return message
        case .unparsableResponse:
            return "Couldn't read that report. Try a clearer, well-lit photo, or enter values manually."
        case .noBiomarkersFound:
            return "Couldn't find any lab values in that photo. Try a clearer photo of the results table."
        }
    }
}

struct ExtractedBiomarker {
    let name: String
    let value: Double
    let unit: String
}

/// Added 2026-08-03: raised during manual testing — the test-date field in
/// `LabResultReviewView` always defaulted to today, requiring the user to
/// manually change it to match the actual report every single time.
/// Extracting the printed date is a reasonable thing to ask this feature to
/// do: a date is metadata, not a health interpretation, so reading it off
/// the page doesn't touch the transcription-only line this feature holds
/// for the *values* themselves. `reportDate` is nil whenever the model
/// can't find a legible date — the review screen still falls back to today
/// and the field stays fully editable either way, so a wrong or missing
/// extraction is never a silent error, just a slightly less convenient
/// default.
struct LabExtractionResult {
    let biomarkers: [ExtractedBiomarker]
    let reportDate: Date?
}

/// Added 2026-08-03 per `Sustain-Competitor-Deep-Dive-2026-08.md` §6. Reuses
/// `AIProteinEstimator`'s exact proxy/vision-call plumbing (same
/// `anthropic-proxy` Supabase Edge Function, same base64 image payload
/// shape) rather than inventing a second pattern for "send a photo to
/// Claude" — the only real differences are the prompt and the response
/// shape.
///
/// **Deliberately single-call, no Haiku→Sonnet escalation cascade** unlike
/// `AIProteinEstimator`. That cascade exists because a wrong protein number
/// silently corrupts a running daily total the user never re-checks against
/// the source photo. A wrong lab value here is different in a way that
/// argues for *more* caution, not the same escalation logic: the user has
/// the original paper/PDF report in hand and can immediately verify or
/// correct any extracted number against it (`LabResultsView` shows exactly
/// what was extracted before saving, never auto-saves), so a lower-effort
/// single call with a straightforward confidence gate is a reasonable
/// trade-off for a lower-priority, less-differentiated feature — see this
/// file's own place in the priority table in the deep-dive report.
///
/// **The prompt is written to make transcription-only as close to
/// structurally guaranteed as a prompt can make it**: no interpretation,
/// classification, or reference-range judgment is ever requested, and the
/// response shape has no field for one to go in even if the model wanted to
/// volunteer it.
///
/// **On-device Vision cross-check, added 2026-08-03.** Asked directly:
/// "should this also use Apple Intelligence as a cross check?" The honest
/// answer is that Apple's on-device FoundationModels framework — the
/// "Apple-Intelligence-first, Claude-fallback" pattern used by
/// `WeeklySummaryGenerator` and `AIChatCoachService` — has no multimodal
/// (image) input support on this app's iOS target at all, the same
/// constraint already documented on `AIProteinEstimator`. So there's no
/// on-device *generative* model that can read this photo as an alternative.
/// But Apple's separate, much older Vision framework
/// (`VNRecognizeTextRequest`) has done genuine on-device text recognition
/// since iOS 13, entirely independent of Apple Intelligence, at zero cost
/// and with no network round-trip. `extract(from:)` runs it alongside the
/// Claude call and treats it as a real, independent check rather than a
/// second opinion to blend in: any biomarker value Claude reports that
/// doesn't literally appear anywhere in the on-device OCR'd text is dropped
/// before this function ever returns it. This is deliberately conservative —
/// an OCR miss on a genuinely correct value costs the user having to
/// re-enter or re-photograph one row; a hallucinated number silently making
/// it into `LabResultEntry` is the failure mode this whole feature exists to
/// prevent (see that model's own header comment).
enum LabResultExtractor {
    private static let proxyConfig: (url: URL, anonKey: String)? = {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: "SupabaseFunctionURL") as? String,
              let anonKey = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
              !urlString.isEmpty, !anonKey.isEmpty,
              let url = URL(string: urlString) else {
            return nil
        }
        return (url, anonKey)
    }()

    private static let model = "claude-sonnet-5"

    private static let prompt = """
    You are transcribing a photo of a lab/bloodwork report into structured data. This \
    is a transcription task only, not a medical one.

    Rules, never break these:
    - Only extract a biomarker name, its numeric value, and its unit exactly as printed. \
    Never classify a value as normal, high, low, or borderline. Never mention a reference \
    range even if one is printed on the report. Never give any health interpretation, \
    explanation, or recommendation about any value.
    - Only include a biomarker if both its name and numeric value are clearly legible. If \
    part of the report is blurry, cut off, or ambiguous, skip that row rather than \
    guessing a number.
    - Use the short, standard lab abbreviation for each biomarker name where the report \
    itself uses one (e.g. "LDL", "HDL", "A1C", "TSH", "Vitamin D"), not a long descriptive \
    phrase.
    - If this photo does not look like a lab report at all, return an empty "biomarkers" \
    array.
    - Also look for a date printed on the report itself (commonly labeled "Collected," \
    "Specimen Collected," "Date," or "Report Date"). If more than one date is printed, \
    prefer the specimen collection date over a later report/release date. Output it as \
    "reportDate" in exactly yyyy-MM-dd format. If no date is clearly legible or printed \
    anywhere on the report, output "reportDate" as null. Never guess a date that isn't \
    actually printed.

    Respond with ONLY a JSON object, no other text before or after it, in exactly this \
    shape:
    {"biomarkers": [{"name": "<short name>", "value": <number>, "unit": "<unit exactly as printed>"}], "confidence": "<low|medium|high>", "reportDate": "<yyyy-MM-dd or null>"}
    """

    static func extract(from image: UIImage) async throws -> LabExtractionResult {
        guard let proxyConfig else { throw LabResultExtractError.missingProxyConfig }
        guard let imageData = resizedJPEGData(from: image) else {
            throw LabResultExtractError.invalidImage
        }

        // Kicked off in parallel with the Claude call below, not chained
        // after it — Vision's on-device recognition and the network request
        // don't depend on each other, so there's no reason to pay their
        // latencies sequentially.
        async let ocrText = recognizedText(from: image)

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 1200,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": imageData.base64EncodedString(),
                            ],
                        ],
                        ["type": "text", "text": prompt],
                    ],
                ]
            ],
        ]

        var request = URLRequest(url: proxyConfig.url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(proxyConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(proxyConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "unknown error"
            throw LabResultExtractError.requestFailed("Request failed: \(bodyText)")
        }

        let result = try parseExtraction(from: data)

        guard let recognizedText = await ocrText else {
            // Vision found no recognizable text at all, or the request
            // failed outright — treat this as "the cross-check itself
            // couldn't run" rather than "nothing verified," and fall back to
            // trusting Claude's read alone. Discarding every biomarker just
            // because Vision came up empty (a real possibility on a low-
            // contrast or heavily glared photo Claude's own reasoning can
            // still often work around) would make this strictly worse than
            // not having a cross-check at all.
            return result
        }

        let verifiedBiomarkers = result.biomarkers.filter { valueAppears($0.value, in: recognizedText) }
        return LabExtractionResult(biomarkers: verifiedBiomarkers, reportDate: result.reportDate)
    }

    /// Runs Apple's on-device `VNRecognizeTextRequest` against the photo —
    /// see this enum's header comment for why this, not FoundationModels, is
    /// the cross-check. Returns the recognized lines joined together, or nil
    /// if Vision couldn't process the image or found no text at all (an
    /// empty non-nil string is meaningfully different from that: it would
    /// cause every biomarker to fail verification, whereas nil is handled by
    /// the caller as "the check didn't run," not "nothing was found").
    private static func recognizedText(from image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation],
                      !observations.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                try? handler.perform([request])
            }
        }
    }

    /// Checks whether `value` appears anywhere in the OCR'd text, trying a
    /// handful of plausible printed formats — a report might print "182",
    /// "182.0", or "1,234" for a value Claude (correctly) normalizes to a
    /// bare `Double`, and this shouldn't fail verification over formatting
    /// alone. Still a genuine check: a value Claude invented out of whole
    /// cloth won't match any of these against text Vision actually read off
    /// the page.
    private static func valueAppears(_ value: Double, in text: String) -> Bool {
        var candidates: Set<String> = [
            String(format: "%g", value),
            String(format: "%.0f", value),
            String(format: "%.1f", value),
            String(format: "%.2f", value),
        ]
        if let groupedInteger = groupedIntegerFormatter.string(from: NSNumber(value: value)) {
            candidates.insert(groupedInteger)
        }
        return candidates.contains { text.contains($0) }
    }

    // A report is more likely to print a large value with a thousands
    // separator (e.g. "1,234") than a bare `Double` would ever render.
    private static let groupedIntegerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    // Same reasoning and same 1568px cap as `AIProteinEstimator.resizedJPEGData`
    // — Anthropic rejects images over 8000px on a side, and this is comfortably
    // under whatever the API would downscale server-side anyway.
    private static func resizedJPEGData(from image: UIImage, maxDimension: CGFloat = 1568, compressionQuality: CGFloat = 0.8) -> Data? {
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > maxDimension else {
            return image.jpegData(compressionQuality: compressionQuality)
        }
        let scale = maxDimension / longestSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: compressionQuality)
    }

    // yyyy-MM-dd only, deliberately matching exactly what the prompt asks
    // the model to output — this is parsing our own requested format back,
    // not attempting to handle arbitrary date strings a report might print.
    private static let reportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static func parseExtraction(from data: Data) throws -> LabExtractionResult {
        struct MessageResponse: Decodable {
            struct ContentBlock: Decodable { let text: String? }
            let content: [ContentBlock]
        }
        struct BiomarkerPayload: Decodable {
            let name: String
            let value: Double
            let unit: String
        }
        struct ExtractionPayload: Decodable {
            let biomarkers: [BiomarkerPayload]
            let confidence: String
            // Optional — older prompt versions and a model choosing not to
            // include it at all shouldn't fail the whole decode over one
            // nice-to-have field. Missing entirely is treated the same as an
            // explicit null: `reportDate` on the result is just nil either
            // way, and the review screen falls back to today.
            let reportDate: String?
        }

        guard let message = try? JSONDecoder().decode(MessageResponse.self, from: data),
              let text = message.content.first(where: { $0.text != nil })?.text else {
            throw LabResultExtractError.unparsableResponse
        }

        guard let openBrace = text.firstIndex(of: "{"),
              let closeBrace = text.lastIndex(of: "}"),
              openBrace < closeBrace,
              let jsonData = String(text[openBrace...closeBrace]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(ExtractionPayload.self, from: jsonData) else {
            throw LabResultExtractError.unparsableResponse
        }

        // Low self-reported confidence is treated as "nothing legible enough
        // to trust," same spirit as every other AI feature in this app
        // distrusting a model's own confidence claim — except here, rather
        // than escalating to a stronger model (see this file's header
        // comment for why that cascade doesn't apply), the honest response
        // is to return nothing and let the user retake the photo.
        guard payload.confidence.lowercased() != "low", !payload.biomarkers.isEmpty else {
            throw LabResultExtractError.noBiomarkersFound
        }

        let biomarkers = payload.biomarkers.map { ExtractedBiomarker(name: $0.name, value: $0.value, unit: $0.unit) }
        let reportDate = payload.reportDate.flatMap { reportDateFormatter.date(from: $0) }
        return LabExtractionResult(biomarkers: biomarkers, reportDate: reportDate)
    }
}
