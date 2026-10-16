import Foundation
import FoundationModels

/// Everything needed to write one week's recap, pre-aggregated client-side so
/// the API call is text-only (cheap) and Claude never has to reason about raw
/// logs — see `ProgressCalculator.weeklySummaryInput(...)` for how this is built.
struct WeeklySummaryInput {
    let medicationName: String
    let currentDoseMg: Double
    let dosesLogged: Int
    let dosesSkipped: Int
    let dosesExpected: Int
    let averageDailyProteinGrams: Double
    let proteinGoalGrams: Double
    let weightChangeLbs: Double?
    let topSideEffects: [(symptom: String, count: Int)]

    // Added so the AI recap can reason about trajectory, not just one week in
    // isolation — a single week's snapshot ("120g protein, -1lb") has no way to
    // tell "this is new" from "this has been true for a month," which was the
    // main reason the old one-liner read as generic. Nil for the prior-week
    // fields just means not enough history yet (e.g. first week of use), same
    // convention as `weightChangeLbs` being nil.
    let previousWeekAverageDailyProteinGrams: Double?
    let previousWeekWeightChangeLbs: Double?
    /// From `ProgressCalculator.proteinGoalStreak` — already computed and shown
    /// elsewhere on Dashboard, now also given to the model so it can reference
    /// the *behavior* streak (which people actually control) rather than only
    /// outcome numbers (weight, which is noisier and less directly controllable).
    let proteinGoalStreakDays: Int
    /// From `ProgressCalculator.plateauMessage` — the app already has a whole
    /// deterministic, reassuring explanation for plateaus shown elsewhere; this
    /// flag just lets the AI recap avoid the opposite mistake of treating a
    /// normal plateau as a bad sign worth flagging.
    let isPlateaued: Bool
    /// Triage item 3 (`Sustain-User-Feedback-Triage-2026-08.md`) —
    /// `MaintenanceGuideView`'s "Maintenance mode" toggle. Defaults to `false`
    /// via the explicit `init` below (NOT an inline `= false` on the
    /// property itself — a real Swift gotcha hit while building this: a
    /// `let` property with an inline default value is excluded entirely
    /// from the compiler's synthesized memberwise initializer, not just
    /// made optional the way a `var` with a default would be, which broke
    /// every call site passing this argument with "Extra argument
    /// 'isInMaintenanceMode' in call." An explicit `init` below keeps this
    /// `let` while still giving it a real, overridable default) so every
    /// existing call site (both production and `ProgressCalculatorTests`)
    /// that doesn't know about this yet keeps building and behaving exactly
    /// as before; only `TrendsView` and `ChatCoachView` currently pass a
    /// real value. See `buildPrompt(_:)`'s use of this flag for what it
    /// actually changes about the recap.
    let isInMaintenanceMode: Bool

    init(
        medicationName: String,
        currentDoseMg: Double,
        dosesLogged: Int,
        dosesSkipped: Int,
        dosesExpected: Int,
        averageDailyProteinGrams: Double,
        proteinGoalGrams: Double,
        weightChangeLbs: Double?,
        topSideEffects: [(symptom: String, count: Int)],
        previousWeekAverageDailyProteinGrams: Double?,
        previousWeekWeightChangeLbs: Double?,
        proteinGoalStreakDays: Int,
        isPlateaued: Bool,
        isInMaintenanceMode: Bool = false
    ) {
        self.medicationName = medicationName
        self.currentDoseMg = currentDoseMg
        self.dosesLogged = dosesLogged
        self.dosesSkipped = dosesSkipped
        self.dosesExpected = dosesExpected
        self.averageDailyProteinGrams = averageDailyProteinGrams
        self.proteinGoalGrams = proteinGoalGrams
        self.weightChangeLbs = weightChangeLbs
        self.topSideEffects = topSideEffects
        self.previousWeekAverageDailyProteinGrams = previousWeekAverageDailyProteinGrams
        self.previousWeekWeightChangeLbs = previousWeekWeightChangeLbs
        self.proteinGoalStreakDays = proteinGoalStreakDays
        self.isPlateaued = isPlateaued
        self.isInMaintenanceMode = isInMaintenanceMode
    }
}

/// One labeled finding in the AI recap. Replaces the old single two-sentence
/// blob — see `buildPrompt`'s header comment for why: a hard word cap made the
/// feature feel thin relative to what a paying subscriber should get, but the
/// fix isn't "no limit," it's "more structure." Three short, titled findings
/// read as a mini analysis (worth paying for) where one cap'd sentence read as
/// a caption. Codable so it round-trips through `@AppStorage` as JSON between
/// generation and display.
struct WeeklyInsight: Codable, Identifiable {
    var id: String { title }
    let title: String
    let detail: String
}

/// Guided-generation shape for the on-device attempt in
/// `WeeklySummaryGenerator.tryOnDeviceSummary`. Deliberately mirrors
/// `WeeklyInsight`'s own two fields exactly, plus one addition
/// (`confidence`) that Claude's prompt never asks for — see that function's
/// doc comment for why a self-reported confidence field is asked for at all
/// despite the lesson (already learned once, in `AIProteinEstimator`) that it
/// can't be trusted alone.
@available(iOS 26.0, *)
@Generable
private struct OnDeviceFinding {
    @Guide(description: "A 2-4 word label for this finding, not a full sentence")
    let title: String
    @Guide(description: "1-2 sentences, roughly 20-40 words, specific, using only the numbers given in the prompt")
    let detail: String
}

@available(iOS 26.0, *)
@Generable
private struct OnDeviceSummary {
    @Guide(description: "Exactly three findings, in order: the most analytically interesting cross-signal finding, a second distinct behavioral observation, then what's worth watching next week", .count(3))
    let findings: [OnDeviceFinding]
    @Guide(description: "Your honest confidence that this analysis is specific and correctly grounded in the numbers given, not generic or invented: low, medium, or high")
    let confidence: String
}

enum WeeklySummaryError: LocalizedError {
    case missingProxyConfig
    case requestFailed(String)
    case unparsableResponse

    var errorDescription: String? {
        switch self {
        case .missingProxyConfig:
            return "AI summaries aren't set up yet. Add your Supabase proxy URL and anon key to Secrets.xcconfig."
        case .requestFailed(let message):
            return message
        case .unparsableResponse:
            return "Couldn't generate your summary. Try again in a moment."
        }
    }
}

/// The report's named "your week on 5mg" recap — the second half of the
/// weeks 7-8 "AI magic moment" milestone (the first half, photo-to-protein,
/// shipped earlier; this was the part that never got built).
///
/// Deliberately reuses `AIProteinEstimator`'s exact pattern rather than
/// introducing a new one: an enum namespace (stateless), the same
/// `anthropic-proxy` Supabase Edge Function, the same anon-key auth. Both
/// call sites moved behind the proxy together — see
/// `supabase/functions/anthropic-proxy/index.ts` and
/// `AIProteinEstimator.swift`'s header comment for the full explanation of
/// why the direct-from-device Anthropic key was replaced.
///
/// Unlike the photo estimate, this call is text-only (no image payload), so
/// it's meaningfully cheaper per call — but it's still a real Anthropic
/// request, so the UI layer (`WeeklySummaryCard`) caches the result locally
/// and only regenerates on explicit user action, never automatically on
/// every tab appearance.
enum WeeklySummaryGenerator {
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

    /// Tries Apple's on-device Foundation Models framework before ever
    /// touching the Claude proxy — added 2026-08-01 specifically to cut
    /// Anthropic spend on this call. This is the cheaper of the app's two AI
    /// features already (text-only, no image payload), but it's still a real
    /// per-user, per-week Anthropic request at scale, and this call in
    /// particular is a good first candidate for the swap: the prompt and
    /// response both comfortably fit the on-device model's small context
    /// window, unlike the photo estimate (see the note below on why that
    /// feature is NOT getting this treatment yet).
    ///
    /// On a device where this succeeds, the request never leaves the phone at
    /// all — no network call, no Anthropic cost, and (per how Apple's on-
    /// device model works) none of this week's health numbers leave local
    /// memory either, which is a genuine privacy improvement on top of the
    /// cost one for whoever's eligible.
    ///
    /// **Deliberately reuses `buildPrompt(input)` unchanged** rather than
    /// writing a separate on-device prompt. That prompt's compliance rules
    /// (never diagnose, never suggest a dose/gram target, never invent a
    /// number) are exactly as load-bearing here as they are for Claude, and
    /// forking the prompt into two copies is exactly how those rules would
    /// eventually drift out of sync between the two paths without anyone
    /// noticing. The "respond with ONLY a raw JSON array..." formatting
    /// instructions in that prompt are Claude-specific and unnecessary here
    /// (guided generation enforces the shape directly via `OnDeviceSummary`
    /// regardless of what the prompt text says), but harmless to leave in —
    /// worth knowing if you're looking for where to trim the prompt for this
    /// path specifically.
    ///
    /// Only attempted on iOS 26+ with Apple Intelligence actually enabled on
    /// an eligible device (`SystemLanguageModel.default.availability`) —
    /// everywhere else this returns `nil` immediately and `generateSummary`
    /// falls through to the existing Claude call completely unchanged, so no
    /// one outside that device population is affected by this at all, for
    /// better or worse.
    ///
    /// Deliberately does NOT trust the model's self-reported `confidence`
    /// field alone, same lesson already learned in
    /// `AIProteinEstimator.Reliability`'s doc comment: a small model can be
    /// miscalibrated and report "high" confidence on a generic or wrong
    /// answer just as easily as a large one can. `looksReliable` below also
    /// checks things the model can't talk its way around (the right finding
    /// count, titles/details in a plausible length range) before ever
    /// looking at what it claims about itself.
    ///
    /// **Not yet build-verified against a real device.** Foundation Models'
    /// guided-generation API is new to this codebase, and the on-device
    /// model's much smaller context window (4,096 tokens per session, per
    /// Apple's own docs, versus effectively no practical limit for a Claude
    /// prompt this size) means it may produce noticeably shallower analysis
    /// even when it succeeds structurally and reports high confidence. Test
    /// this against real weekly data on a real Apple Intelligence-eligible
    /// device before trusting it in production — if the findings read as
    /// generic or repetitive next to what Claude produces for the same week,
    /// that's a reason to tighten `looksReliable` or drop this path, not a
    /// bug to silently work around.
    @available(iOS 26.0, *)
    private static func tryOnDeviceSummary(_ input: WeeklySummaryInput, labResults: [LabResultEntry]) async -> [WeeklyInsight]? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        let session = LanguageModelSession(
            instructions: "You write concise, specific weekly analyses for a GLP-1 tracking app."
        )
        guard let response = try? await session.respond(to: buildPrompt(input, labResults: labResults), generating: OnDeviceSummary.self) else {
            return nil
        }

        let summary = response.content
        guard looksReliable(summary) else { return nil }

        return summary.findings.map { WeeklyInsight(title: $0.title, detail: $0.detail) }
    }

    @available(iOS 26.0, *)
    private static func looksReliable(_ summary: OnDeviceSummary) -> Bool {
        guard summary.confidence.lowercased() != "low" else { return false }
        guard summary.findings.count == 3 else { return false }
        guard summary.findings.allSatisfy({ finding in
            let titleWords = finding.title.split(separator: " ").count
            let detailWords = finding.detail.split(separator: " ").count
            return (1...6).contains(titleWords) && (8...70).contains(detailWords)
        }) else { return false }
        // Added 2026-08-03 alongside wiring lab results into this feature's
        // prompt for the first time — see `buildPrompt`'s lab-section doc
        // comment for the full reasoning. Unlike the Claude path (which has
        // nowhere further to fall back to, so it sanitizes instead — see
        // `sanitizeForLabInterpretation` below), the on-device path can
        // simply reject and let `generateSummary` fall through to Claude,
        // matching how every other reliability check in this function
        // already behaves.
        return !summary.findings.contains { finding in
            LabResultEntry.containsInterpretationLanguage(finding.title)
                || LabResultEntry.containsInterpretationLanguage(finding.detail)
        }
    }

    static func generateSummary(for input: WeeklySummaryInput, labResults: [LabResultEntry] = []) async throws -> [WeeklyInsight] {
        if #available(iOS 26.0, *), let onDevice = await tryOnDeviceSummary(input, labResults: labResults) {
            return onDevice
        }

        guard let proxyConfig else { throw WeeklySummaryError.missingProxyConfig }

        let requestBody: [String: Any] = [
            "model": model,
            // History: 220 (one paragraph, restated the stats table, felt like
            // filler) -> 100 (one bare sentence, too thin) -> 160 then 110 (two
            // sentences under a hard word cap — technically "glanceable" but
            // user feedback was that it felt too thin to be worth paying for).
            // Now generating 3 structured, titled findings instead of capping
            // total words — 420 gives headroom for three ~40-word details plus
            // titles and JSON overhead without inviting the model to pad.
            "max_tokens": 420,
            "messages": [
                ["role": "user", "content": buildPrompt(input, labResults: labResults)]
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
            throw WeeklySummaryError.requestFailed("Request failed: \(bodyText)")
        }

        struct MessageResponse: Decodable {
            struct ContentBlock: Decodable { let text: String? }
            let content: [ContentBlock]
        }
        guard let text = try? JSONDecoder().decode(MessageResponse.self, from: data)
            .content.first(where: { $0.text != nil })?.text else {
            throw WeeklySummaryError.unparsableResponse
        }

        // Defensive: the prompt asks for raw JSON only, but models occasionally
        // wrap it in a ```json fence anyway. Strip that if present before
        // decoding rather than failing the whole request over formatting.
        var jsonText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonText.hasPrefix("```") {
            jsonText = jsonText
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let jsonData = jsonText.data(using: .utf8),
              let insights = try? JSONDecoder().decode([WeeklyInsight].self, from: jsonData),
              !insights.isEmpty else {
            throw WeeklySummaryError.unparsableResponse
        }
        return sanitizeForLabInterpretation(insights)
    }

    /// Unlike the on-device path (which can simply reject and fall through
    /// to this Claude call — see `looksReliable`), this call IS the final
    /// fallback, so there's nowhere left to hand off to if a finding trips
    /// the lab-interpretation check. Swaps just that finding's text for a
    /// safe, generic one rather than failing the whole request over a
    /// single flagged sentence, or silently shipping language this feature
    /// exists specifically to never produce.
    private static func sanitizeForLabInterpretation(_ insights: [WeeklyInsight]) -> [WeeklyInsight] {
        insights.map { insight in
            guard LabResultEntry.containsInterpretationLanguage(insight.title)
                || LabResultEntry.containsInterpretationLanguage(insight.detail) else {
                return insight
            }
            return WeeklyInsight(
                title: insight.title,
                detail: "This touched on a lab value Sustain can't evaluate, that's a conversation for your prescriber or the lab itself."
            )
        }
    }

    /// Everything Claude sees is a pre-computed data summary, never raw logs —
    /// keeps the prompt small (cheap) and keeps the model from having to do
    /// arithmetic it might get wrong. Explicitly instructed never to diagnose
    /// or suggest dose changes, matching the app's hard "log and discuss with
    /// your prescriber" compliance stance everywhere else.
    ///
    /// Third version of this prompt. V1 asked for one bare sentence picking
    /// whichever single stat looked most notable — it could only ever restate
    /// one isolated number, which a glance at the stats table already tells
    /// you, so it read as filler. V2 fixed the shallowness (fed week-over-week
    /// deltas, asked for compound reasoning) but capped the output at two
    /// sentences under a hard combined word limit — real user feedback on V2
    /// was that even with better content, a couple of capped sentences still
    /// didn't feel like something worth paying a subscription for. This
    /// version keeps V2's reasoning priorities but drops the word cap in favor
    /// of *structure*: three short, titled findings instead of one blob of
    /// prose. A titled list reads as an actual analysis; the fix for "feels
    /// thin" was never going to be "let it ramble," it's "give it a shape."
    /// Real bug, caught from a live device screenshot immediately after this
    /// feature shipped: `AIChatCoachService`'s system prompt originally
    /// embedded the *entire* `buildPrompt(_:)` output — including this
    /// function's own "Respond with ONLY a raw JSON array..." instruction
    /// block below — as its data context. Claude followed that literal
    /// instruction inside the chat coach's system prompt too, so a user
    /// asking a plain question like "how much protein do I average per week"
    /// got back a raw JSON findings array instead of a conversational answer.
    /// Splitting the data rendering (this function) from the instructions
    /// (`buildPrompt`, below) means the chat coach can reuse the numbers
    /// without also inheriting a different feature's output-format contract.
    static func dataSummary(_ input: WeeklySummaryInput) -> String {
        var lines: [String] = []
        lines.append("This week:")
        lines.append("- Doses: \(input.dosesLogged) taken, \(input.dosesSkipped) skipped, \(input.dosesExpected) expected")
        lines.append("- Average daily protein: \(Int(input.averageDailyProteinGrams.rounded()))g (goal: \(Int(input.proteinGoalGrams.rounded()))g)")
        if let change = input.weightChangeLbs {
            let sign = change > 0 ? "+" : ""
            lines.append("- Weight change: \(sign)\(change.formatted(.number.precision(.fractionLength(0...1)))) lb")
        } else {
            lines.append("- Weight change: not enough weigh-ins logged this week to tell")
        }
        if input.topSideEffects.isEmpty {
            lines.append("- Side effects logged: none")
        } else {
            let list = input.topSideEffects.map { "\($0.symptom) (\($0.count)x)" }.joined(separator: ", ")
            lines.append("- Side effects logged: \(list)")
        }
        lines.append("- Current protein-goal streak: \(input.proteinGoalStreakDays) day\(input.proteinGoalStreakDays == 1 ? "" : "s") in a row hitting goal")

        lines.append("")
        lines.append("Previous week, for comparison:")
        if let prevProtein = input.previousWeekAverageDailyProteinGrams {
            lines.append("- Average daily protein: \(Int(prevProtein.rounded()))g")
        } else {
            lines.append("- Average daily protein: no data logged that week")
        }
        if let prevChange = input.previousWeekWeightChangeLbs {
            let sign = prevChange > 0 ? "+" : ""
            lines.append("- Weight change: \(sign)\(prevChange.formatted(.number.precision(.fractionLength(0...1)))) lb")
        } else {
            lines.append("- Weight change: not enough weigh-ins logged that week to tell")
        }

        lines.append("")
        lines.append("Plateau flag: \(input.isPlateaued ? "yes, weight has been essentially flat for multiple weeks (already explained to the user elsewhere as normal)" : "no")")

        // Triage item 3 — see `buildPrompt(_:)`'s conditional paragraph below
        // for what this actually changes about how the recap is written;
        // this line just makes the fact visible to the model at all.
        if input.isInMaintenanceMode {
            lines.append("")
            lines.append("Maintenance mode: yes, this person has reached their goal weight and turned on Maintenance mode. Continued weight loss is not their goal right now.")
        }

        return lines.joined(separator: "\n")
    }

    /// `labResults` added 2026-08-03: this recap previously had no access to
    /// lab data at all — same gap as `AIChatCoachService` had (see that
    /// file's doc comment for the fuller context and why `LabResultEntry`
    /// holds a stricter transcription-only line than anything else in the
    /// app). Deliberately NOT folded into `dataSummary(_:)` above — that
    /// function is shared with the chat coach specifically so the two
    /// features can't drift out of sync on the *core* weekly numbers, but
    /// this recap's output-format rules (raw JSON, exactly 3 findings) are
    /// this feature's own contract, not the chat coach's, and this file's
    /// own header comment already documents the bug that happens when one
    /// feature's rules leak into the other's prompt. The lab section lives
    /// only here, in `buildPrompt`.
    static func buildPrompt(_ input: WeeklySummaryInput, labResults: [LabResultEntry] = []) -> String {
        var lines: [String] = []
        lines.append("""
        You are the analyst behind a "your week" recap in Sustain, a companion app for people on \
        GLP-1 medications whose whole premise is that losing weight and losing muscle are not the \
        same thing. Below is one user's data: this week's numbers, last week's numbers for \
        comparison, and two pre-computed behavioral signals. The raw numbers are already shown to \
        the user verbatim in a table elsewhere in the app, so your job is not to restate them, it's \
        to do the analysis a busy person wouldn't do in their head: connect the numbers to each \
        other and say what actually follows from that. This is a paid feature, so it needs to feel \
        like a real, specific analysis of this person's week, not a generic caption.

        Respond with ONLY a raw JSON array (no markdown fence, no prose before or after) of exactly \
        3 objects, each shaped like {"title": string, "detail": string}. "title" is a 2-4 word label \
        for the finding (e.g. "Protein vs. pace", "Adherence trend", "Worth watching"), not a full \
        sentence. "detail" is 1-2 sentences, specific, using the actual numbers involved, roughly \
        20-40 words — long enough to say something real, short enough to stay glanceable. Do not pad \
        a detail to hit a length; a precise 15-word finding beats a vague 40-word one.

        The 3 findings, in this order:
        1. The single most analytically interesting thing in the data. Prioritize, in this order: \
        (a) a genuine interaction between two signals, most importantly protein intake relative to \
        weight-loss speed, since fast loss on too little protein is a real muscle-preservation risk \
        this app exists to catch; (b) a meaningful week-over-week change in adherence or protein \
        trend; (c) a single-week finding worth flagging on its own (a real shortfall, a skipped-dose \
        pattern, a side effect worth noting) if no cross-signal story is present; (d) if the week is \
        genuinely uneventful and steady, say that plainly instead of manufacturing a finding.
        2. A second, different observation about behavior this week (adherence, the protein streak, \
        or a pattern in when/how goals were hit or missed) — something the person actually controls, \
        distinct from finding 1.
        3. What's worth watching for next week, or the honest one-line "why" behind finding 1. If \
        the person is in a plateau (flagged below), don't treat flat weight as bad news on its own, \
        that's already explained to them elsewhere as a normal, temporary part of treatment; instead \
        comment on whether their protein/adherence habits during the plateau are the kind that carry \
        someone through it.

        Rules: never diagnose, never suggest a dose change or a specific gram/calorie target, never \
        invent a number that isn't given to you below. Frame any real concern only as worth \
        mentioning to their prescriber, in passing, not as a detail's whole point. No markdown, no \
        quotation marks nested inside the JSON string values beyond what JSON escaping allows, no \
        bullet points, no em dash character (—) anywhere inside title or detail, use a comma, \
        period, colon, or parentheses instead.

        If lab results are included below: they are logged, transcribed values only, never \
        evaluated anywhere else in this app. You may mention that a lab result was logged as a \
        factual note if genuinely relevant (e.g. "You also logged a new panel this week"), but \
        never say or imply that a value is high, low, normal, abnormal, elevated, or borderline, \
        and never compare it to any reference range, even if the reasoning behind a finding seems \
        to call for it. A lab value is never the analytical focus of a finding; the medication, \
        protein, weight, and adherence signals above remain the priority, since those are the \
        things a person actually controls week to week.
        """)

        // Triage item 3 (`Sustain-User-Feedback-Triage-2026-08.md`): the
        // original findings-priority rules above are written for someone in
        // active weight loss (rule 1 explicitly prioritizes "fast loss on too
        // little protein" as the top finding). For a Maintenance-mode user
        // that framing is actively wrong, continued loss isn't the goal, so
        // this reorients the same three-finding structure around staying in
        // range instead, rather than trying to retrofit the rules above to
        // cover both cases inline.
        if input.isInMaintenanceMode {
            lines.append("")
            lines.append("""
            Override for this user: they've reached their goal weight and are in Maintenance mode \
            (see the data below). Continued weight loss is not their goal, so do not frame findings \
            around losing more weight, and do not treat flat or slightly fluctuating weight as a \
            plateau to explain away, staying in range IS the goal, so name that as a good outcome \
            when it's true. Finding 1 should focus on whether their weight stayed within a \
            reasonable range of where they started the week, not on the size or speed of any \
            change. Findings 2 and 3 should still cover adherence/protein habits and what's worth \
            watching, since those still matter for staying in range long-term, just never reframed \
            around losing more.
            """)
        }

        lines.append("")
        lines.append(dataSummary(input))

        if !labResults.isEmpty {
            lines.append("")
            lines.append("This user's logged lab results, transcribed from their own reports (most recent first):")
            lines.append(LabResultEntry.promptSummary(for: labResults))
        }

        return lines.joined(separator: "\n")
    }
}
