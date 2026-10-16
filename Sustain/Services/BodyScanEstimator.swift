import Foundation
import UIKit

/// The buildable slice of the still-unbuilt full camera body scan flagged in
/// `Sustain-Remaining-Priorities-Scoping-2026-08.md` and reconfirmed in
/// `Sustain-Subscription-Payer-Features-Report-2026-08.md` §7 item 6 as
/// "still the highest engineering lift of anything in either report." A real
/// photogrammetry/3D body scan needs a vendor SDK decision this codebase has
/// explicitly never made — that assessment is unchanged, and this file does
/// NOT attempt it. What it does instead: reuse `AIProteinEstimator`'s and
/// `LabResultExtractor`'s exact "photo → Claude via the `anthropic-proxy`
/// Supabase Edge Function" plumbing to ask a general-purpose vision model for
/// a rough body-fat percentage *range* from two photos, the same way those
/// two features already ask it to estimate protein grams or transcribe a lab
/// value. See `MedicalSourceTopic.bodyScanEstimate`'s explainer for the
/// accuracy caveat this deliberately foregrounds to the user: the one real
/// validation study of photo-based body-fat estimation
/// (Majmudar et al. 2022, NPJ Digit Med) measured a purpose-built,
/// separately-trained computer-vision model under a controlled protocol, not
/// a general-purpose vision-language model asked to eyeball a photo. This
/// feature is a reasonable, honestly-caveated middle ground between "no
/// camera-based estimate at all" and "a real photogrammetry scan," not a
/// claim of matching that study's accuracy.
///
/// **Deliberate departures from the cited study's own protocol, for safety
/// and privacy, not just convenience**: the validated method asks for
/// "minimal clothing" photos in a fixed "A" pose. This app never asks for
/// that. The prompt and the on-screen instructions both specify form-fitting
/// athletic clothing (leggings/shorts and a fitted top, or swimwear that
/// isn't minimal) — accepting a real accuracy cost in exchange for a camera
/// feature that doesn't ask anyone to photograph themselves undressed and
/// send it to a cloud model. The prompt also instructs the model to decline
/// rather than estimate if a photo doesn't show that, if a full body isn't
/// visible, or if anyone in the photo could plausibly be a minor — see
/// `DeclineReason` below. **No photo is ever stored.** Both images exist only
/// in memory for the duration of one request/response and are discarded the
/// moment `estimate(front:side:)` returns, success or failure — unlike
/// `ProgressPhotoEntry` (which explicitly persists photos with the user's
/// consent for before/after comparison), this feature has no reason to keep
/// the image at all once a number comes back, so it doesn't.
enum BodyScanEstimator {
    enum BodyScanError: LocalizedError {
        case missingProxyConfig
        case invalidImage
        case requestFailed(String)
        case unparsableResponse
        case declined(String)

        var errorDescription: String? {
            switch self {
            case .missingProxyConfig:
                return "AI estimates aren't set up yet. Add your Supabase proxy URL and anon key to Secrets.xcconfig."
            case .invalidImage:
                return "Couldn't read one of those photos. Try again."
            case .requestFailed(let message):
                return message
            case .unparsableResponse:
                return "Couldn't produce an estimate from those photos. Try retaking them in good, even lighting."
            case .declined(let reason):
                return reason
            }
        }
    }

    struct BodyScanResult {
        /// A range, not a point estimate — deliberately never collapsed to a
        /// single number anywhere this result is used, since a general-
        /// purpose vision model's confidence in a specific percentage would
        /// overstate what this feature can actually support. See this file's
        /// header comment.
        let lowPercent: Double
        let highPercent: Double
        let confidence: String

        var midpoint: Double { (lowPercent + highPercent) / 2 }
    }

    private static let proxyConfig: (url: URL, anonKey: String)? = {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: "SupabaseFunctionURL") as? String,
              let anonKey = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
              !urlString.isEmpty, !anonKey.isEmpty,
              let url = URL(string: urlString) else {
            return nil
        }
        return (url, anonKey)
    }()

    // Single call, no Haiku→Sonnet cascade — same reasoning as
    // `LabResultExtractor`, not `AIProteinEstimator`: this isn't a running
    // total a person never double-checks, it's a single number shown once,
    // clearly labeled as a rough range, with the review screen never
    // silently auto-saving it. A stronger single call for the harder task
    // (reasoning about two photos of a whole body vs. a plate of food) is a
    // more defensible trade-off here than optimizing for the cheapest
    // possible call.
    private static let model = "claude-sonnet-5"

    private static let prompt = """
    You are looking at two photos of the same person: one facing the camera, one \
    from the side, both meant to be wearing form-fitting athletic clothing (not \
    minimal clothing or swimwear that exposes significantly more skin). This is for \
    a rough, non-diagnostic body-fat percentage estimate inside a fitness-tracking \
    app, not a medical or diagnostic assessment.

    Before estimating anything, check these conditions. If ANY of them are true, do \
    NOT produce an estimate: decline instead.
    - Either photo does not clearly show a full body (head to at least mid-thigh) \
    facing the camera in the front photo, or in profile in the side photo.
    - Either photo shows clothing that exposes substantially more skin than \
    form-fitting athletic wear (e.g. underwear, swimwear cut for minimal coverage, \
    or no clothing).
    - The person in either photo could plausibly be under 18.
    - The two photos don't appear to show the same person.
    - Lighting, blur, distance, or occlusion make the body shape genuinely too hard \
    to judge.
    - Either image does not appear to be a photo of a real person at all (for \
    example, a drawing, a photo of a screen, or an unrelated object).

    If you decline, respond with ONLY this JSON shape, filling in a short, plain, \
    non-judgmental reason a person would understand (never comment on anyone's \
    appearance, weight, or attractiveness in the reason):
    {"declined": true, "reason": "<short reason>"}

    If none of those conditions apply, estimate a body-fat percentage RANGE (not a \
    single number) from visual cues in both photos: general silhouette, waist-to-hip \
    proportions, visible muscle definition, and limb/torso shape. Be honest that a \
    photo-based estimate from a general-purpose vision model, not a specialized \
    body-composition tool, has real uncertainty, uncertainty which should be reflected \
    in how wide the range is, not hidden. Respond with ONLY this JSON shape:
    {"declined": false, "low_percent": <number>, "high_percent": <number>, "confidence": "<low|medium|high>"}
    """

    static func estimate(front: UIImage, side: UIImage) async throws -> BodyScanResult {
        guard let proxyConfig else { throw BodyScanError.missingProxyConfig }
        guard let frontData = resizedJPEGData(from: front),
              let sideData = resizedJPEGData(from: side) else {
            throw BodyScanError.invalidImage
        }

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 500,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": frontData.base64EncodedString(),
                            ],
                        ],
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": sideData.base64EncodedString(),
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
            throw BodyScanError.requestFailed("Request failed: \(bodyText)")
        }

        return try parseResult(from: data)
    }

    // Same reasoning and 1568px cap as `AIProteinEstimator`/`LabResultExtractor`.
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

    private static func parseResult(from data: Data) throws -> BodyScanResult {
        struct MessageResponse: Decodable {
            struct ContentBlock: Decodable { let text: String? }
            let content: [ContentBlock]
        }
        struct ResultPayload: Decodable {
            let declined: Bool
            let reason: String?
            let lowPercent: Double?
            let highPercent: Double?
            let confidence: String?

            enum CodingKeys: String, CodingKey {
                case declined, reason, confidence
                case lowPercent = "low_percent"
                case highPercent = "high_percent"
            }
        }

        guard let message = try? JSONDecoder().decode(MessageResponse.self, from: data),
              let text = message.content.first(where: { $0.text != nil })?.text else {
            throw BodyScanError.unparsableResponse
        }

        guard let openBrace = text.firstIndex(of: "{"),
              let closeBrace = text.lastIndex(of: "}"),
              openBrace < closeBrace,
              let jsonData = String(text[openBrace...closeBrace]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(ResultPayload.self, from: jsonData) else {
            throw BodyScanError.unparsableResponse
        }

        if payload.declined {
            throw BodyScanError.declined(payload.reason ?? "Couldn't produce an estimate from those photos.")
        }

        guard let low = payload.lowPercent, let high = payload.highPercent, low > 0, high >= low else {
            throw BodyScanError.unparsableResponse
        }

        return BodyScanResult(lowPercent: low, highPercent: high, confidence: payload.confidence ?? "low")
    }
}
