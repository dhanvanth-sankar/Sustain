import Foundation
import UIKit

enum ProteinEstimateError: LocalizedError {
    case missingProxyConfig
    case invalidImage
    case requestFailed(String)
    case unparsableResponse
    case responseTruncated

    var errorDescription: String? {
        switch self {
        case .missingProxyConfig:
            return "AI estimates aren't set up yet. Add your Supabase proxy URL and anon key to Secrets.xcconfig."
        case .invalidImage:
            return "Couldn't read that photo. Try another one."
        case .requestFailed(let message):
            return message
        case .unparsableResponse:
            return "Couldn't understand the estimate. Try again, or enter the amount manually."
        case .responseTruncated:
            return "That photo had a lot of separate items, so the estimate got cut off partway through. Try again, or enter the amount manually."
        }
    }
}

struct ProteinEstimate {
    let grams: Double
    let foodDescription: String
    let confidence: String
}

/// Calls the `anthropic-proxy` Supabase Edge Function instead of Anthropic
/// directly — see `supabase/functions/anthropic-proxy/index.ts`. The real
/// Anthropic API key now lives only as a server-side secret on that project;
/// this file only ever holds the Supabase project's public anon key, which
/// (like a Firebase config) is meant to be embedded client-side and is not a
/// secret on its own. That's the fix for the security tradeoff this file used
/// to document: previously it called api.anthropic.com directly with the real
/// key read from Info.plist, which meant any shipped binary — including a
/// TestFlight build — could have that key extracted by anyone inspecting the
/// bundle.
enum AIProteinEstimator {
    private static let proxyConfig: (url: URL, anonKey: String)? = {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: "SupabaseFunctionURL") as? String,
              let anonKey = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
              !urlString.isEmpty, !anonKey.isEmpty,
              let url = URL(string: urlString) else {
            return nil
        }
        return (url, anonKey)
    }()

    // Cheap-first cascade instead of a single fixed model: most real photos are a
    // plain plate (a chicken breast, a protein shake, a couple eggs) that a cheap
    // model handles fine, and it's wasteful to spend Sonnet-tier tokens on every
    // single estimate just because a minority of photos (cluttered multi-item
    // plates, unusual dishes) genuinely need it. `estimateProtein` below tries
    // `fastModel` first and only pays for `strongModel` on the subset of photos
    // where the cheap model itself signals trouble (a parse/truncation failure, or
    // a self-reported "low" confidence) — see that function for the exact
    // escalation rule. Both strings must stay in `ALLOWED_MODELS` in
    // supabase/functions/anthropic-proxy/index.ts, or the proxy rejects the
    // request with a 400 before it ever reaches Anthropic.
    private static let fastModel = "claude-haiku-4-5"
    private static let strongModel = "claude-sonnet-5"

    // Originally just said "estimate protein using typical portion sizes," which
    // anchored the model toward a generic meal-sized protein number regardless of
    // what was actually in frame. Verified against a real test photo of a spice
    // grinder (garlic cloves, whole cumin seed, whole black peppercorns — raw
    // seasoning prep, not a plated meal): the old prompt returned 15g, but USDA
    // protein-density figures for the actual visible quantities (garlic ~6.4g/100g,
    // cumin seed ~17.8g/100g, black pepper ~10.4g/100g) put the real total closer to
    // 4-5g — roughly 3x too high, because whole spices/aromatics look like a
    // substantial pile while contributing almost no protein per gram. The fix is to
    // make the model decompose the photo into distinct items and reason about each
    // one's actual protein density rather than pattern-matching "this looks like a
    // dish, dishes have ~15g protein."
    //
    // Second accuracy pass: the model was still guessing food identity and portion
    // mass wrong often enough to be a real complaint, even after the fix above. Two
    // changes address that: (1) the JSON schema now forces the model to write out
    // its per-item breakdown (name, estimated weight, protein) as actual output
    // tokens before the final total, rather than silently reasoning it internally
    // and only emitting the answer — making the model "show its work" in the token
    // stream measurably improves arithmetic and identification accuracy versus
    // jumping straight to a final number. (2) explicit portion-mass anchors (plate/
    // hand/palm/fist references) replace vague "judge volume" language, since size
    // misjudgment (not just misidentifying the food) was the other main error mode.
    private static let prompt = """
    You are estimating protein content from a photo of food for someone tracking \
    protein intake during GLP-1 medication treatment, where getting enough protein \
    matters for preserving muscle. Getting both the food identification and the \
    portion size right matters: this number is the only thing the person sees, so \
    a wrong guess here directly misleads their tracking.

    Work through this in order:

    1. Identify every distinct food item visible. Look carefully before naming; \
    don't default to the most common dish that vaguely resembles what's in frame. \
    A plate with several separate components (for example a ceviche-style dish \
    with shrimp, avocado, egg, and a starchy side all in one bowl) should be broken \
    into that many separate items rather than described as one dish. Keep each \
    item's "name" to a few words; save any nuance about cooking method or \
    uncertainty for the overall "food" description instead of a long per-item name. \
    If a food appears more than once (three shrimp, two egg halves, several \
    dumplings), combine every piece of it into ONE item entry with their combined \
    estimated weight rather than one entry per piece. Never list the same physical \
    object as two separate items under two different names (for example a single \
    quail egg should appear once, as "quail egg," not once as "egg" and again as \
    "quail egg"); double-listing one object double-counts its protein in the final \
    total.

    2. For each item, estimate its mass in grams using concrete visual reference \
    anchors rather than a vague sense of volume: a standard dinner plate is ~25-28cm \
    across, a deck-of-cards-sized piece of meat is ~85g, a clenched fist of rice or \
    pasta is ~150-180g cooked, a cupped palm of nuts/cheese is ~30g, a large chicken \
    breast is 150-220g, a large egg is ~50g. Compare the item against the plate, \
    utensils, hands, or container actually in the photo rather than assuming a \
    "typical serving."

    3. Multiply each item's estimated mass by its real protein density (grams of \
    protein per 100g of that specific food, from standard USDA figures) to get that \
    item's protein grams. Whole spices, herbs, and aromatics (garlic, ginger, cumin, \
    pepper, chilies, and similar) contribute only a small fraction of their weight \
    in protein even when there's a visible pile of them. Don't let their volume \
    inflate the total. Sauces, oils, and garnishes usually contribute negligible \
    protein unless they're clearly dairy- or legume-based.

    4. Sum every item's protein grams for the total.

    If the photo shows raw cooking ingredients or spices rather than a plated, \
    ready-to-eat meal, or if lighting/angle/occlusion makes identification genuinely \
    uncertain, reflect that by returning "low" confidence rather than guessing \
    confidently.

    Respond with ONLY a JSON object, no other text before or after it, in exactly \
    this shape (the "items" array is your per-item work; fill it in before the \
    final "grams" total, which must equal the sum of each item's "protein_g"). Never \
    use an em dash character (—) anywhere in the "food" description; use a comma or \
    period instead.
    {"items": [{"name": "<item>", "estimated_weight_g": <number>, "protein_g": <number>}], "grams": <total protein across all items>, "food": "<short overall description, e.g. \\"grilled chicken breast with rice\\">", "confidence": "<low|medium|high>"}
    """

    /// Tries `fastModel` first and only escalates to `strongModel` when there's a
    /// concrete sign the cheap model got it wrong. Deliberately does NOT rely
    /// solely on the model's own self-reported "confidence" label — a weaker model
    /// can be miscalibrated and hand back "high" confidence on an answer that's
    /// actually wrong, which would defeat the whole point of gating on it. Instead
    /// `Reliability` (below) checks things the cheap model can't talk its
    /// way around: the arithmetic in its own response actually being consistent,
    /// and whether the photo has the kind of complexity (several distinct items)
    /// already known from real testing to be where a cheap model under-reasons,
    /// regardless of how confident it claims to be. Escalation triggers on any of:
    /// - a thrown `.unparsableResponse` or `.responseTruncated` (garbled or cut off)
    /// - self-reported "low" confidence (still checked, just not solely relied on)
    /// - 3+ distinct items in its own per-item breakdown (the known weak spot)
    /// - its per-item breakdown not summing to its own stated total (internally
    ///   inconsistent math is a strong tell regardless of the confidence label)
    /// - any single item claiming more protein grams than its own estimated weight
    ///   (physically impossible; a food item can't be more protein than it weighs)
    /// One more check on top of those, added specifically for the case where
    /// Haiku is confidently wrong on both the label and the structural checks: a
    /// task that's past a model's competence tends to produce noisier, less
    /// repeatable answers across independent tries, even when any single try
    /// looks clean on its own. There's no exposed "confidence"/logprob signal
    /// from Claude's API to read that directly, so `tryFastConsensus` (below)
    /// approximates it the standard way (self-consistency sampling): it calls
    /// `fastModel` twice, independently, on the same photo, and only accepts the
    /// result if both calls pass their own `Reliability` checks AND agree with
    /// each other's gram total within 20%. Disagreement between two identically-
    /// prompted calls is itself evidence the photo is past what Haiku can do
    /// reliably, regardless of what either individual response claims about
    /// itself, so that also escalates to `strongModel`.
    ///
    /// Any other error (`.missingProxyConfig`, `.invalidImage`, `.requestFailed`)
    /// is an infrastructure or input problem that `strongModel` can't fix either,
    /// so it's rethrown immediately rather than wasting more calls retrying it.
    static func estimateProtein(from image: UIImage) async throws -> ProteinEstimate {
        guard let proxyConfig else { throw ProteinEstimateError.missingProxyConfig }
        guard let imageData = resizedJPEGData(from: image) else {
            throw ProteinEstimateError.invalidImage
        }

        if let consensus = try await tryFastConsensus(imageData: imageData, proxyConfig: proxyConfig) {
            return consensus
        }

        return try await requestEstimate(imageData: imageData, proxyConfig: proxyConfig, model: strongModel).estimate
    }

    /// Returns a consensus estimate from two independent `fastModel` calls, or
    /// `nil` if either call failed to parse/was truncated, either one looks
    /// unreliable on its own, or the two disagree with each other closely enough
    /// to distrust both — in every `nil` case the caller escalates to
    /// `strongModel`. On agreement, averages the two gram totals rather than
    /// picking one arbitrarily: averaging two independent samples cancels out
    /// some of each call's individual noise, the same reason self-consistency
    /// sampling improves accuracy generally, not just a tie-breaking convenience.
    private static func tryFastConsensus(
        imageData: Data,
        proxyConfig: (url: URL, anonKey: String)
    ) async throws -> ProteinEstimate? {
        async let firstCall = requestEstimate(imageData: imageData, proxyConfig: proxyConfig, model: fastModel)
        async let secondCall = requestEstimate(imageData: imageData, proxyConfig: proxyConfig, model: fastModel)

        let first: (estimate: ProteinEstimate, reliability: Reliability)
        let second: (estimate: ProteinEstimate, reliability: Reliability)
        do {
            (first, second) = try await (firstCall, secondCall)
        } catch ProteinEstimateError.unparsableResponse, ProteinEstimateError.responseTruncated {
            return nil
        }

        guard !first.reliability.shouldEscalate, !second.reliability.shouldEscalate else {
            return nil
        }

        let higherGrams = max(first.estimate.grams, second.estimate.grams)
        let lowerGrams = min(first.estimate.grams, second.estimate.grams)
        let agree = higherGrams == 0 || (higherGrams - lowerGrams) / higherGrams <= 0.2
        guard agree else { return nil }

        return ProteinEstimate(
            grams: (first.estimate.grams + second.estimate.grams) / 2,
            foodDescription: first.estimate.foodDescription,
            confidence: first.estimate.confidence
        )
    }

    /// The objective, non-self-reported signals used to decide whether a cheap
    /// model's answer is trustworthy enough to hand back as-is. See the doc
    /// comment on `estimateProtein` for why self-reported confidence alone isn't
    /// enough to gate on.
    private struct Reliability {
        let itemCount: Int
        let selfReportedConfidence: String
        let sumMatchesTotal: Bool
        let anyItemExceedsOwnWeight: Bool

        var shouldEscalate: Bool {
            selfReportedConfidence.lowercased() == "low"
                || itemCount >= 3
                || !sumMatchesTotal
                || anyItemExceedsOwnWeight
        }
    }

    private static func requestEstimate(
        imageData: Data,
        proxyConfig: (url: URL, anonKey: String),
        model: String
    ) async throws -> (estimate: ProteinEstimate, reliability: Reliability) {
        let requestBody: [String: Any] = [
            "model": model,
            // Raised from 300, then again from 700: the prompt makes the model
            // write out a per-item breakdown (name/weight/protein for each food
            // item) before the final total, and a real complex plate (e.g. a
            // ceviche-style dish with shrimp, avocado, egg, and several other
            // components each needing their own entry) needs meaningfully more
            // output tokens than a simple two-item plate does. 700 was cutting
            // off mid-JSON on exactly that kind of cluttered photo, which
            // `parseEstimate`'s `stopReason == "max_tokens"` check now detects
            // and reports as a distinct, specific error rather than a generic
            // "couldn't understand" one.
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
                        [
                            "type": "text",
                            "text": prompt,
                        ],
                    ],
                ]
            ],
        ]

        var request = URLRequest(url: proxyConfig.url)
        request.httpMethod = "POST"
        // The anon key authenticates the call to *our* Supabase project, not to
        // Anthropic — Anthropic's real key never leaves the proxy.
        request.setValue("Bearer \(proxyConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(proxyConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "unknown error"
            throw ProteinEstimateError.requestFailed("Request failed: \(bodyText)")
        }

        return try parseEstimate(from: data)
    }

    /// Anthropic rejects any image over 8000px on either dimension, which a raw
    /// `UIImage` from the Photos library can exceed (panoramas, screenshots synced
    /// from a Mac, and newer iPhones' full-resolution 48MP captures all commonly do,
    /// even though a normal in-app camera capture usually wouldn't) — this surfaced
    /// as a real "Couldn't estimate protein" failure during device testing, not just
    /// a theoretical edge case. Downsampling to a ~1568px long edge before encoding
    /// avoids that rejection entirely; it's also not a quality tradeoff, since
    /// Anthropic's own vision guidance is that images larger than roughly that get
    /// downscaled server-side anyway, and it shrinks the base64 payload (and cost).
    private static func resizedJPEGData(from image: UIImage, maxDimension: CGFloat = 1568, compressionQuality: CGFloat = 0.7) -> Data? {
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > maxDimension else {
            return image.jpegData(compressionQuality: compressionQuality)
        }

        let scale = maxDimension / longestSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: compressionQuality)
    }

    private static func parseEstimate(from data: Data) throws -> (estimate: ProteinEstimate, reliability: Reliability) {
        struct MessageResponse: Decodable {
            struct ContentBlock: Decodable { let text: String? }
            let content: [ContentBlock]
            // Anthropic sets this to "max_tokens" when the response was cut off
            // before the model finished, rather than ending naturally. This is the
            // one signal that distinguishes "the JSON is incomplete because we ran
            // out of budget" from "the model returned something genuinely
            // malformed" — a real distinction surfaced by a cluttered, many-item
            // photo (e.g. a ceviche-style plate with shrimp, avocado, egg, and
            // several other components each needing their own line in the
            // per-item breakdown the prompt requires): more distinct items means
            // more JSON output before the closing brace, and 700 tokens that was
            // comfortable for a simple two-item plate can run out before a
            // six-or-seven-item one finishes.
            let stopReason: String?

            enum CodingKeys: String, CodingKey {
                case content
                case stopReason = "stop_reason"
            }
        }
        struct ItemBreakdown: Decodable {
            let estimatedWeightG: Double
            let proteinG: Double

            enum CodingKeys: String, CodingKey {
                case estimatedWeightG = "estimated_weight_g"
                case proteinG = "protein_g"
            }
        }
        struct EstimatePayload: Decodable {
            let items: [ItemBreakdown]
            let grams: Double
            let food: String
            let confidence: String
        }

        guard let message = try? JSONDecoder().decode(MessageResponse.self, from: data) else {
            throw ProteinEstimateError.unparsableResponse
        }
        guard let text = message.content.first(where: { $0.text != nil })?.text else {
            throw ProteinEstimateError.unparsableResponse
        }

        // Claude is asked to return only JSON, but defensively extract the {...}
        // block in case any stray text surrounds it.
        guard let openBrace = text.firstIndex(of: "{"),
              let closeBrace = text.lastIndex(of: "}"),
              openBrace < closeBrace,
              let jsonData = String(text[openBrace...closeBrace]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(EstimatePayload.self, from: jsonData) else {
            // A truncated response almost always fails to parse as valid JSON
            // (the closing brace `lastIndex(of: "}")` finds is from the last
            // *complete* nested item, not the outer object, so required
            // top-level fields like "grams" are simply missing) — checking
            // `stopReason` here, rather than only above, is what lets this report
            // specifically as "cut off" instead of the generic fallback.
            if message.stopReason == "max_tokens" {
                throw ProteinEstimateError.responseTruncated
            }
            throw ProteinEstimateError.unparsableResponse
        }

        let estimate = ProteinEstimate(grams: payload.grams, foodDescription: payload.food, confidence: payload.confidence)

        let itemProteinSum = payload.items.reduce(0.0) { $0 + $1.proteinG }
        // Small tolerance for rounding, not exact equality: the model does this
        // addition itself in the token stream, so a fraction of a gram of
        // rounding drift is normal and not a sign of a real inconsistency.
        let sumMatchesTotal = payload.items.isEmpty || abs(itemProteinSum - payload.grams) <= max(1.0, payload.grams * 0.1)
        let anyItemExceedsOwnWeight = payload.items.contains { $0.proteinG > $0.estimatedWeightG }

        let reliability = Reliability(
            itemCount: payload.items.count,
            selfReportedConfidence: payload.confidence,
            sumMatchesTotal: sumMatchesTotal,
            anyItemExceedsOwnWeight: anyItemExceedsOwnWeight
        )

        return (estimate, reliability)
    }
}
