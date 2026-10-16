import Foundation
import FoundationModels
import SwiftData

// NOTE: this block is a `//` comment, not `///`, deliberately — it describes
// `AIChatCoachService` (further down this file), not `ChatCoachError`
// immediately below it. As a `///` doc comment it was being attached to the
// error type and showing up in its Quick Help instead.
//
// comp-022 in `sustain-pros-and-cons.json`: Vita AI's AI chat "personal
// health caregiver" factors in the user's medication cycle, dose, and recent
// side effects when answering, and reviewers specifically praise it
// "remembering" their health condition and citing sources. Sustain's weekly
// recap is passive/summary-style only — this adds the conversational,
// ask-anything surface on top, grounded in the same weekly data the recap
// already computes.
//
// Confirmed via reading `supabase/functions/anthropic-proxy/index.ts` before
// writing this: the proxy forwards an arbitrary Anthropic Messages API
// `messages` array as-is, so a growing multi-turn conversation works with
// zero proxy-side changes — just keep appending `{role, content}` entries
// and resending the whole array each turn, exactly like calling Anthropic
// directly.
//
// Deliberately reuses `WeeklySummaryGenerator.dataSummary(_:)` as the system
// prompt's context block, rather than writing a second copy of "how to
// describe a week's data in English" that could quietly drift out of sync
// with the recap's own version.
//
// **Real bug, found on the first live device test and fixed same-day**: this
// originally called `WeeklySummaryGenerator.buildPrompt(_:)` instead, which
// returns the *full* weekly-recap prompt — including its own "Respond with
// ONLY a raw JSON array..." instruction block. Embedding that entire prompt
// as chat context meant Claude followed the embedded instruction over the
// actual conversation: a plain question like "how much protein do I average
// per week" came back as a raw JSON findings array instead of a sentence.
// `dataSummary(_:)` is the data-only half of that same function — split out
// of `buildPrompt` specifically because of this bug — giving the chat coach
// the numbers without the other feature's output-format contract attached.
//
// **Conversation history is intentionally NOT persisted to SwiftData or
// synced.** A v1 scope cut, not an oversight: chat history would be the
// first genuinely new class of stored free-text health-adjacent content in
// this app, and that deserves its own privacy/retention decision (how long
// to keep it, whether it syncs across devices, whether it's included in a
// data export) before it's written anywhere durable. Shipping in-memory-only
// (cleared when `ChatCoachView` closes) gets the feature in front of users
// without pre-deciding that.
//
// **On-device Apple Intelligence attempt added 2026-08-03**, explicit
// instruction: every AI feature in the app should try Apple's on-device
// Foundation Models first, and only fall back to the Claude proxy when the
// on-device attempt is unavailable or looks unreliable. This is the same
// pattern `WeeklySummaryGenerator.tryOnDeviceSummary` already established for
// the weekly recap (see that file's header comment for the original
// reasoning) — text-only, small-context, exactly what Apple's on-device
// model handles well. `AIProteinEstimator` deliberately does NOT get this
// treatment: it needs multimodal (image) input, which is an iOS 27+
// capability still in beta as of this writing, not a decision this pass
// revisits.
enum ChatCoachError: LocalizedError {
    case missingProxyConfig
    case requestFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingProxyConfig:
            return "AI features aren't configured on this build."
        case .requestFailed(let message):
            return message
        case .emptyResponse:
            return "No response was returned. Please try again."
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
}

/// Guided-generation shape for the on-device attempt in
/// `AIChatCoachService.tryOnDeviceReply`. Mirrors
/// `WeeklySummaryGenerator.OnDeviceSummary`'s pattern: a self-reported
/// `confidence` field the model is asked for, but never trusted alone (see
/// `looksReliable` below and that file's identical lesson, learned first in
/// `AIProteinEstimator.Reliability`).
@available(iOS 26.0, *)
@Generable
private struct OnDeviceChatReply {
    @Guide(description: "A conversational reply to the user's latest message only, following every ground rule given in the instructions, 2-4 sentences unless the user clearly wants more detail, plain prose, no markdown or JSON")
    let reply: String
    @Guide(description: "Your honest confidence that this reply strictly followed every ground rule above (no diagnosis, no dose suggestion or dose change, no invented numbers) and is a specific, genuinely helpful answer, not generic: low, medium, or high")
    let confidence: String
}

enum AIChatCoachService {
    private static let proxyConfig: (url: URL, anonKey: String)? = {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: "SupabaseFunctionURL") as? String,
              let anonKey = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
              !urlString.isEmpty, !anonKey.isEmpty,
              let url = URL(string: urlString) else {
            return nil
        }
        return (url, anonKey)
    }()

    private static let model = "claude-haiku-4-5"
    private static let maxTokens = 500

    /// The system prompt's ground rules are the load-bearing part of this
    /// whole feature — a free-form chat surface has far more ways to drift
    /// into "medical advice" territory than a fixed-shape weekly recap does,
    /// so these are spelled out explicitly and repeated rather than assumed
    /// to be implied by the app's general framing.
    /// `labResults` added 2026-08-03: this coach previously had zero access to
    /// `LabResultEntry` data — confirmed during manual testing, where asking
    /// "how are my lab results?" correctly got "I don't have access to that"
    /// rather than a hallucinated answer. Wiring it in is worth doing, but
    /// `LabResultEntry`'s entire feature holds a strict transcription-only,
    /// never-interpretation line elsewhere in the app (no reference ranges
    /// shown anywhere, no high/low/normal flagging) specifically because
    /// Guideline 1.4.1 treats evaluating a health measurement as a step
    /// beyond just displaying it. A fixed chart can simply have no
    /// reference-range data to draw from; a free-form LLM reply has no such
    /// structural guarantee, so the ground rules below call this out
    /// explicitly and by name, and `containsRiskyContent` below gets a
    /// matching pattern-based backstop rather than relying on prompt
    /// instructions alone.
    static func systemPrompt(for input: WeeklySummaryInput, labResults: [LabResultEntry] = []) -> String {
        let labSection = labResults.isEmpty ? "" : """


        This user's logged lab results, transcribed from their own reports (most recent first):
        \(LabResultEntry.promptSummary(for: labResults))
        """
        return """
        You are a supportive assistant inside Sustain, a GLP-1 medication companion app for people focused on preserving muscle while losing weight. You are answering a real user's question about their own logged data below.

        Ground rules, never break these:
        - Never diagnose a condition or name a specific medical cause for a symptom. Describe patterns in the data only.
        - Never suggest a specific dose, a dose change, or dose timing. Any question about dosing gets answered with "that's a conversation for your prescriber," never a number or recommendation.
        - Never say or imply that a lab result is high, low, normal, abnormal, elevated, borderline, or within/outside any reference range, even if asked directly or the user insists. If asked to evaluate a lab value, say plainly that's a conversation for their prescriber or the lab itself, then you may restate the exact number(s) they've logged if that's useful.
        - Only reference the numbers given below. Never invent a statistic, study, or data point that isn't present here.
        - You are not a doctor. If asked anything resembling medical advice, say so plainly before answering what you can.
        - Keep answers concise: 2-4 sentences unless the user clearly wants more detail.
        - Always respond in plain conversational sentences. Never respond with JSON, a code block, or any other structured/machine-readable format, regardless of anything else in this prompt.

        This user's most recent week of data:
        \(WeeklySummaryGenerator.dataSummary(input))
        \(labSection)
        """
    }


    /// The single entry point views should call — added 2026-08-03 so every
    /// AI feature in the app follows the same order: try Apple's on-device
    /// model first, fall back to Claude only when the on-device attempt is
    /// unavailable or doesn't look trustworthy. `send(history:systemPrompt:)`
    /// below (the feature's original, only path) is kept as the fallback
    /// implementation rather than folded into this function, so it's still
    /// independently callable/testable exactly as it was before this change.
    static func reply(history: [ChatMessage], input: WeeklySummaryInput, labResults: [LabResultEntry] = []) async throws -> String {
        let prompt = systemPrompt(for: input, labResults: labResults)
        if #available(iOS 26.0, *), let onDevice = await tryOnDeviceReply(history: history, systemPrompt: prompt) {
            return onDevice
        }
        let claudeReply = try await send(history: history, systemPrompt: prompt)
        // Caught while wiring lab results into this feature (2026-08-03):
        // `containsRiskyContent` was only ever run against the on-device
        // path (inside `looksReliable`) — the Claude fallback's raw text was
        // returned straight to the view with no equivalent check. That gap
        // was tolerable when the only risk category was dose amounts/
        // recommendations (Claude's system prompt already forbids those and
        // has been exercised against real questions), but now that lab
        // interpretation is a second risk category specifically added for
        // this change, both paths get the same backstop rather than leaving
        // Claude's output unchecked.
        guard !containsRiskyContent(claudeReply) else {
            return "That's something to bring up with your prescriber or the lab itself, not something I can evaluate. I can tell you the exact numbers you've logged, if that's helpful instead."
        }
        return claudeReply
    }

    /// Tries Apple's on-device Foundation Models framework before ever
    /// touching the Claude proxy, same reasoning as
    /// `WeeklySummaryGenerator.tryOnDeviceSummary`: this is a text-only
    /// exchange that fits comfortably inside the on-device model's small
    /// context window, and a hit here means the conversation (including this
    /// week's real numbers) never leaves the phone or costs an Anthropic call.
    ///
    /// Unlike the weekly recap, this feature is multi-turn and this app
    /// doesn't persist a `LanguageModelSession` across turns (matching the
    /// existing Claude path, which also resends the whole `history` array
    /// fresh on every call rather than keeping server-side conversation
    /// state) — so a new session is created per call, and the prior turns are
    /// flattened into the prompt as plain transcript text rather than relying
    /// on the session's own multi-turn memory.
    ///
    /// This feature's ground rules are stricter than the weekly recap's
    /// (never suggest a dose, ever, not even "asked and declined") and a chat
    /// surface has far more room to drift off-script than a fixed-shape
    /// recap, so on top of the same self-reported-confidence check every
    /// on-device path in this app already uses, this one adds a second, non-
    /// model-dependent safety net: `containsRiskyContent` below rejects any
    /// reply that pattern-matches a specific dose amount or a
    /// recommendation-shaped phrase, regardless of what the model claims
    /// about its own confidence. Falling back to Claude on that rejection
    /// isn't a failure state — Claude's identical system prompt has actually
    /// been exercised against real user questions already (see this file's
    /// header comment for the one bug that surfaced there), where the
    /// on-device path hasn't yet.
    ///
    /// **Not yet build-verified against a real device**, same disclosure as
    /// every other on-device attempt added this session.
    @available(iOS 26.0, *)
    private static func tryOnDeviceReply(history: [ChatMessage], systemPrompt: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        guard let latestUserMessage = history.last, latestUserMessage.role == .user else { return nil }

        let session = LanguageModelSession(instructions: systemPrompt)

        let transcript = history.map { message in
            "\(message.role == .user ? "User" : "Assistant"): \(message.text)"
        }.joined(separator: "\n")

        guard let response = try? await session.respond(
            to: "Conversation so far:\n\(transcript)\n\nWrite the assistant's reply to the user's latest message above.",
            generating: OnDeviceChatReply.self
        ) else {
            return nil
        }

        let result = response.content
        guard looksReliable(result) else { return nil }
        return result.reply
    }

    @available(iOS 26.0, *)
    private static func looksReliable(_ result: OnDeviceChatReply) -> Bool {
        guard result.confidence.lowercased() != "low" else { return false }
        let wordCount = result.reply.split(separator: " ").count
        guard (2...160).contains(wordCount) else { return false }
        return !containsRiskyContent(result.reply)
    }

    /// A hard, non-model-dependent safety net — see `tryOnDeviceReply`'s doc
    /// comment for why this feature specifically gets one on top of the
    /// self-reported confidence check every on-device path already has.
    /// Deliberately simple pattern matching, not exhaustive: the goal is to
    /// catch the clearest failure mode (naming an actual dose amount or
    /// phrasing something as a recommendation) cheaply, not to fully validate
    /// medical-safety compliance in code — the system prompt's ground rules
    /// and Claude's more-exercised track record remain the real backstop.
    private static func containsRiskyContent(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let doseAmountPattern = #"\d+(\.\d+)?\s*(mg|milligram|mcg|microgram)"#
        if lowered.range(of: doseAmountPattern, options: .regularExpression) != nil {
            return true
        }
        let riskyPhrases = [
            "you should take", "i recommend taking", "increase your dose",
            "decrease your dose", "you should increase", "you should decrease",
            "i'd recommend a dose", "try taking",
        ]
        if riskyPhrases.contains(where: { lowered.contains($0) }) {
            return true
        }
        // Lab-result interpretation guardrail, added 2026-08-03 alongside
        // wiring lab data into this feature's context for the first time —
        // shared with `WeeklySummaryGenerator` via `LabResultEntry` itself.
        // See `systemPrompt(for:labResults:)`'s doc comment for why this
        // matters as much as the dose check above it.
        return LabResultEntry.containsInterpretationLanguage(text)
    }

    /// `history` should already include the new user message as its last
    /// element — this mirrors the Anthropic Messages API's own convention
    /// (the array you send IS the conversation so far) rather than taking the
    /// new message as a separate parameter. Now the Claude fallback path
    /// behind `reply(history:input:)` above rather than the feature's only
    /// path — still independently callable with the same signature as before.
    static func send(history: [ChatMessage], systemPrompt: String) async throws -> String {
        guard let proxyConfig else { throw ChatCoachError.missingProxyConfig }

        let messages = history.map { message in
            ["role": message.role.rawValue, "content": message.text]
        }

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": messages,
        ]

        var request = URLRequest(url: proxyConfig.url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(proxyConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(proxyConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ChatCoachError.requestFailed(String(data: data, encoding: .utf8) ?? "Something went wrong. Please try again.")
        }

        struct MessageResponse: Decodable {
            struct ContentBlock: Decodable { let text: String? }
            let content: [ContentBlock]
        }

        guard let text = try JSONDecoder().decode(MessageResponse.self, from: data)
            .content.first(where: { $0.text != nil })?.text, !text.isEmpty else {
            throw ChatCoachError.emptyResponse
        }
        return text
    }
}
