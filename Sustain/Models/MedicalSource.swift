import Foundation

/// Citations for every piece of medical/health information the app derives a number
/// or a recommendation from.
///
/// This exists because of an App Store rejection under **Guideline 1.4.1 (Safety —
/// Physical Harm)**: "The app includes medical information but does not include
/// citations for the medical information... the app provides health or medical
/// calculations in the Daily protein target without citations." Apple requires the
/// sources to be *in the app* and *easy for the user to find*, not just implied in
/// code comments (which is where this app's protein-target rationale previously
/// lived — see `MedicationProfile.dailyProteinGoalGrams`).
///
/// Every URL here is a stable, primary source: PubMed records for peer-reviewed
/// literature, and manufacturer FDA-approved prescribing information (PI) for dose
/// ladders. Deliberately no blogs, no secondary summaries, no marketing pages —
/// a reviewer following any link should land on the actual evidence.
///
/// If you add a health calculation anywhere in the app, add its source here and
/// surface a `MedicalSourcesLink` next to it. That pairing is the whole point:
/// a citation the user can't find from the number it supports doesn't satisfy 1.4.1.
struct MedicalSource: Identifiable, Hashable {
    let id: String
    /// Full citation, formatted so it's recognizable as a real reference
    /// (authors, title, journal, year) rather than a vague "studies show".
    let citation: String
    /// One line on what this source actually supports in the app, so the
    /// connection between evidence and on-screen number is explicit.
    let supports: String
    let url: URL

    init(id: String, citation: String, supports: String, urlString: String) {
        self.id = id
        self.citation = citation
        self.supports = supports
        // These are compile-time constant literals below; a malformed one is a
        // programmer error, not a runtime condition, but a crash on a legal/safety
        // screen would be far worse than a link that quietly points at the app's
        // own site, so this degrades instead of force-unwrapping.
        self.url = URL(string: urlString) ?? URL(string: "https://hearthlyapps.com/sustain")!
    }
}

/// Topic groupings, so the sources screen can be filtered to just the
/// calculation the user tapped through from rather than always showing
/// everything at once.
enum MedicalSourceTopic: String, CaseIterable, Identifiable {
    case proteinTarget = "Daily protein target"
    case muscleLoss = "Muscle loss on GLP-1s"
    case dosing = "Dose schedules"
    case maintenance = "Weight maintenance"
    case medicationLevel = "Medication level chart"
    /// Added 2026-08-03 alongside the lab-result import feature. Unlike every
    /// other topic here, this one deliberately cites NO studies and derives
    /// NO number — see its `explainer` below. It exists precisely because the
    /// feature could easily be *mistaken* for medical interpretation, and
    /// Guideline 1.4.1's requirement is that health information in the app be
    /// explained and sourced; the honest explanation here is "we transcribe,
    /// we do not interpret, and here is who does."
    case labResults = "Lab results"
    /// Added 2026-08-07, the first topic that isn't strictly medical/pharmacology —
    /// see `Behavior-Change-Layer-Scoping-2026-08.md` for the full reasoning behind
    /// this feature. Reuses this same citations screen rather than a separate one,
    /// since the underlying requirement (make the evidence behind a claim reachable
    /// from the claim itself) applies just as much to a behavioral-science claim as
    /// a pharmacology one, and a second, parallel "Sources" surface would just be
    /// two places to keep in sync instead of one.
    case consistency = "Consistency & setbacks"
    /// Added 2026-08-08 alongside the AI photo body-fat estimate feature — the
    /// buildable slice of the still-unbuilt full camera body scan (see
    /// `Sustain-Remaining-Priorities-Scoping-2026-08.md`). Unlike
    /// `.labResults`, this topic DOES derive a number (an estimated body-fat
    /// percentage) from a photo, so it needs a real citation under Guideline
    /// 1.4.1 — but the honest citation here also has to disclose a real gap:
    /// the cited validation study measured a purpose-built, separately
    /// trained computer-vision model under a controlled two-photo protocol,
    /// not a general-purpose vision-language model asked to eyeball a photo,
    /// which is what `BodyScanEstimator` actually calls. See that file's
    /// header comment for the full reasoning.
    case bodyScanEstimate = "AI body-fat photo estimate"
    /// Added 2026-09-27 alongside the "Life After GLP-1" feature — see
    /// `Sustain-GLP1-Market-PESTLE-FeatureGap-Report-2026-09.md`'s highest-priority
    /// finding for why this exists: most GLP-1 patients eventually stop the
    /// medication, usually for cost/coverage reasons, and weight regain afterward is
    /// real and documented, not a scare tactic. This topic cites that documentation
    /// directly rather than letting the app's own copy make an uncited claim about
    /// what happens after stopping.
    case discontinuation = "Stopping a GLP-1"

    var id: String { rawValue }

    var explainer: String {
        switch self {
        case .proteinTarget:
            return """
            Sustain sets your daily protein target at about 0.8g per pound of your \
            goal body weight (roughly 1.8g per kilogram). That figure sits inside the \
            1.2–2.0g/kg range the Academy of Nutrition and Dietetics, Dietitians of \
            Canada, and the American College of Sports Medicine jointly recommend, and \
            toward the higher end of it because protein needs are greater during an \
            energy deficit, which is exactly what a GLP-1 creates.
            """
        case .muscleLoss:
            return """
            Weight lost on GLP-1 medications includes both fat and lean mass, and the \
            trials below reported body-composition results alongside total weight lost. \
            Preserving lean mass during that loss is the specific problem Sustain is \
            built around, and it is why the app emphasizes protein intake and weight \
            trends together rather than weight alone. How much lean mass any individual \
            loses varies, and it is a question for your prescriber, not for this app.
            """
        case .dosing:
            return """
            The dose ladders Sustain uses to *suggest* a next titration step come from \
            each medication's FDA-approved prescribing information. Sustain never \
            changes a dose on its own and never tells you to: it pre-fills a suggestion \
            you can edit, and your prescriber's actual plan always takes precedence, \
            including slower titration for side-effect management, which is common.
            """
        case .maintenance:
            return """
            After reaching a goal weight, Sustain shows a maintenance range rather than \
            a single number. Weight regain after weight loss is well documented, and \
            maintenance is recognized as a distinct phase with its own requirements \
            rather than simply the end of the losing phase.
            """
        case .medicationLevel:
            return """
            The medication-level chart estimates how much of your GLP-1 is still active \
            in your body between doses, using your logged dose history and the \
            elimination half-life published in your medication's own prescribing \
            information. This is a simplified estimate, not a blood measurement: it \
            doesn't account for your individual absorption or clearance, and it isn't a \
            substitute for anything your prescriber tells you about your treatment. It \
            exists to make one thing visible: appetite suppression, and the protein dip \
            that can follow it, tends to track how much medication is still active, not \
            just the calendar date of your last dose. Sustain never uses this estimate to \
            calculate, suggest, or change a dose or a dose timing in any way, and it should \
            never be used to decide when to take your next dose. That decision is your \
            prescriber's schedule, not this chart.
            """
        case .labResults:
            return """
            Sustain can read the values off a photo of a lab report so you can see them \
            over time in one place. It only transcribes what is printed on your report: \
            the test name, the number, and the unit. It does not evaluate, flag, \
            classify, or interpret any value, it does not show reference ranges even \
            when your report prints them, and it never tells you whether a result is \
            normal, high, or low. Every value is shown to you to confirm or correct \
            before it is saved, because an automated reading of a photo can be wrong. \
            Your lab report itself, and your prescriber or the ordering clinician, \
            remain the authority on what any result means. If a value concerns you, \
            that is a conversation for them, not for this app.
            """
        case .consistency:
            return """
            When Sustain talks about a missed day or a broken streak, it deliberately \
            avoids treating it as a failure. That's not just a tone choice: research on \
            habit formation shows a single missed day barely dents an established \
            routine, and it recovers quickly. Separately, research on how people \
            respond to a lapse in a health behavior (a skipped dose, an off-plan meal) \
            found that responding with self-blame doesn't predict whether someone gets \
            back on track, but responding with self-compassion does, people who go \
            easier on themselves after a lapse report more confidence and stronger \
            intentions to continue than people who don't. Sustain's streaks and \
            reminders are built around that distinction: a lapse is a normal, expected \
            part of any long-term routine, not evidence that the routine, or the \
            person, has failed.
            """
        case .bodyScanEstimate:
            return """
            Sustain can estimate your body fat percentage from two photos (front and \
            side) using AI, as a rough, free alternative to a smart scale for people \
            who don't own one. Read the cited study carefully: it validated a \
            purpose-built computer-vision model, trained specifically for this task, \
            under a controlled two-photo protocol, against DEXA scans. Sustain's \
            feature asks a general-purpose AI vision model to estimate body fat from \
            your photos, which is a related but different, less proven approach. \
            Sustain always shows the estimate as a wide range, not a precise number, \
            and it is not equivalent to the accuracy shown in the study below. Lighting, \
            clothing, pose, and camera angle all affect it. If you own or can borrow a \
            smart scale, that HealthKit-based reading is more reliable than this \
            estimate, and a real DEXA scan or clinical measurement is more reliable \
            than either. Use this estimate to get a rough sense of where you stand and \
            to see a trend direction over time, not as a precise or diagnostic number, \
            and talk to your prescriber about anything it raises for you.
            """
        case .discontinuation:
            return """
            Most people who start a GLP-1 medication eventually stop, often for reasons \
            that have nothing to do with whether it was working — insurance coverage \
            changing, cost, or a prescriber's own plan. In the extension of the trial \
            cited below, people who stopped semaglutide (and the structured lifestyle \
            support that went with it) regained roughly two-thirds of their prior weight \
            loss during the following year. That is not a reason to feel like you did \
            something wrong, and it is not a prediction about what will happen to you \
            specifically. It is why Sustain keeps tracking protein and weight useful \
            after stopping, not just during active treatment, and why "Life After \
            GLP-1" exists as its own mode rather than treating stopping as the end of \
            what this app has to offer. Whether or how to restart, taper, or manage \
            without medication is a conversation for your prescriber, not this app.
            """
        }
    }
}

enum MedicalSources {
    /// Keyed by topic so a specific screen can cite only what's relevant to it.
    static let byTopic: [MedicalSourceTopic: [MedicalSource]] = [
        .proteinTarget: [
            MedicalSource(
                id: "acsm-2016",
                citation: "Thomas DT, Erdman KA, Burke LM. Position of the Academy of Nutrition and Dietetics, Dietitians of Canada, and the American College of Sports Medicine: Nutrition and Athletic Performance. J Acad Nutr Diet. 2016;116(3):501-528.",
                supports: "The 1.2–2.0g/kg/day protein range Sustain's target sits inside.",
                urlString: "https://pubmed.ncbi.nlm.nih.gov/26920240/"
            ),
            MedicalSource(
                id: "leidy-2015",
                citation: "Leidy HJ, Clifton PM, Astrup A, et al. The role of protein in weight loss and maintenance. Am J Clin Nutr. 2015;101(6):1320S-1329S.",
                supports: "Higher protein intake during weight loss helps preserve lean mass and supports maintenance.",
                urlString: "https://pubmed.ncbi.nlm.nih.gov/25926512/"
            ),
            MedicalSource(
                id: "phillips-2016",
                citation: "Phillips SM, Chevalier S, Leidy HJ. Protein \"requirements\" beyond the RDA: implications for optimizing health. Appl Physiol Nutr Metab. 2016;41(5):565-572.",
                supports: "Why protein needs during an energy deficit exceed the standard RDA.",
                urlString: "https://pubmed.ncbi.nlm.nih.gov/26960445/"
            ),
            MedicalSource(
                id: "longland-2016",
                citation: "Longland TM, Oikawa SY, Mitchell CJ, Devries MC, Phillips SM. Higher compared with lower dietary protein during an energy deficit combined with intense exercise promotes greater lean mass gain and fat mass loss: a randomized trial. Am J Clin Nutr. 2016;103(3):738-746.",
                supports: "Randomized evidence that higher protein in a deficit shifts loss toward fat and away from lean mass.",
                urlString: "https://pubmed.ncbi.nlm.nih.gov/26817506/"
            ),
        ],
        .muscleLoss: [
            MedicalSource(
                id: "step1-2021",
                citation: "Wilding JPH, Batterham RL, Calanna S, et al. Once-Weekly Semaglutide in Adults with Overweight or Obesity (STEP 1). N Engl J Med. 2021;384(11):989-1002.",
                supports: "The primary semaglutide weight-loss trial, including its body-composition sub-study.",
                urlString: "https://pubmed.ncbi.nlm.nih.gov/33567185/"
            ),
            MedicalSource(
                id: "surmount1-2022",
                citation: "Jastreboff AM, Aronne LJ, Ahmad NN, et al. Tirzepatide Once Weekly for the Treatment of Obesity (SURMOUNT-1). N Engl J Med. 2022;387(3):205-216.",
                supports: "The primary tirzepatide weight-loss trial, including its body-composition sub-study.",
                urlString: "https://pubmed.ncbi.nlm.nih.gov/35658024/"
            ),
            MedicalSource(
                id: "ard-2021",
                citation: "Ard J, Fitch A, Fruh S, Herman L. Weight Loss and Maintenance Related to the Mechanism of Action of Glucagon-Like Peptide 1 Receptor Agonists. Adv Ther. 2021;38(6):2821-2839.",
                supports: "How GLP-1 receptor agonists produce weight loss, and what that means for maintenance.",
                urlString: "https://pubmed.ncbi.nlm.nih.gov/33977495/"
            ),
        ],
        .dosing: [
            MedicalSource(
                id: "pi-wegovy",
                citation: "Wegovy (semaglutide) injection and tablets. US Prescribing Information, revised 02/2026. Novo Nordisk.",
                supports: "Wegovy's injection schedule (0.25 → 0.5 → 1.0 → 1.7 → 2.4mg) and its oral tablet schedule (1.5 → 4 → 9 → 25mg, titrated every 30 days), added to the label alongside the injection in 2026.",
                urlString: "https://www.novo-pi.com/wegovy.pdf"
            ),
            MedicalSource(
                id: "pi-ozempic",
                citation: "Ozempic (semaglutide) injection. US Prescribing Information. Novo Nordisk.",
                supports: "Ozempic's 0.25 → 0.5 → 1.0 → 2.0mg escalation schedule.",
                urlString: "https://www.novo-pi.com/ozempic.pdf"
            ),
            MedicalSource(
                id: "pi-rybelsus",
                citation: "Rybelsus (semaglutide) tablets. US Prescribing Information. Novo Nordisk.",
                supports: "Rybelsus' 3 → 7 → 14mg oral escalation schedule and its 30-day cadence.",
                urlString: "https://www.novo-pi.com/rybelsus.pdf"
            ),
            MedicalSource(
                id: "pi-saxenda",
                citation: "Saxenda (liraglutide) injection. US Prescribing Information. Novo Nordisk.",
                supports: "Saxenda's weekly 0.6 → 1.2 → 1.8 → 2.4 → 3.0mg escalation schedule.",
                urlString: "https://www.novo-pi.com/saxenda.pdf"
            ),
            MedicalSource(
                id: "pi-mounjaro",
                citation: "Mounjaro (tirzepatide) injection. US Prescribing Information. Eli Lilly and Company.",
                supports: "Mounjaro's 2.5 → 5 → 7.5 → 10 → 12.5 → 15mg escalation schedule.",
                urlString: "https://pi.lilly.com/us/mounjaro-uspi.pdf"
            ),
            MedicalSource(
                id: "pi-zepbound",
                citation: "Zepbound (tirzepatide) injection. US Prescribing Information. Eli Lilly and Company.",
                supports: "Zepbound's 2.5 → 5 → 7.5 → 10 → 12.5 → 15mg escalation schedule.",
                urlString: "https://pi.lilly.com/us/zepbound-uspi.pdf"
            ),
            MedicalSource(
                id: "dailymed",
                citation: "DailyMed, US National Library of Medicine. Official FDA drug labeling database.",
                supports: "Independent government source for the labeling of any medication Sustain tracks.",
                urlString: "https://dailymed.nlm.nih.gov/dailymed/"
            ),
        ],
        .medicationLevel: [
            MedicalSource(
                id: "pi-wegovy-halflife",
                citation: "Wegovy (semaglutide) injection and tablets. US Prescribing Information, Clinical Pharmacology §12.3. Novo Nordisk.",
                supports: "Semaglutide's approximately 7-day (168-hour) elimination half-life, used to draw Wegovy's relative medication-level chart.",
                urlString: "https://www.novo-pi.com/wegovy.pdf"
            ),
            MedicalSource(
                id: "pi-ozempic-halflife",
                citation: "Ozempic (semaglutide) injection. US Prescribing Information, Clinical Pharmacology §12.3. Novo Nordisk.",
                supports: "Semaglutide's approximately 7-day (168-hour) elimination half-life, used to draw Ozempic's relative medication-level chart.",
                urlString: "https://www.novo-pi.com/ozempic.pdf"
            ),
            MedicalSource(
                id: "pi-rybelsus-halflife",
                citation: "Rybelsus (semaglutide) tablets. US Prescribing Information, Clinical Pharmacology §12.3. Novo Nordisk.",
                supports: "Semaglutide's approximately 7-day (168-hour) elimination half-life, used to draw Rybelsus' relative medication-level chart.",
                urlString: "https://www.novo-pi.com/rybelsus.pdf"
            ),
            MedicalSource(
                id: "pi-tirzepatide-halflife",
                citation: "Zepbound / Mounjaro (tirzepatide) injection. US Prescribing Information, Clinical Pharmacology §12.3. Eli Lilly and Company.",
                supports: "Tirzepatide's approximately 5-day (120-hour) elimination half-life, used to draw Zepbound's and Mounjaro's relative medication-level chart.",
                urlString: "https://pi.lilly.com/us/zepbound-uspi.pdf"
            ),
            MedicalSource(
                id: "pi-saxenda-halflife",
                citation: "Saxenda (liraglutide) injection. US Prescribing Information, Clinical Pharmacology §12.3. Novo Nordisk.",
                supports: "Liraglutide's approximately 13-hour elimination half-life, used to draw Saxenda's relative medication-level chart.",
                urlString: "https://www.novo-pi.com/saxenda.pdf"
            ),
        ],
        // Deliberately empty, and that is the correct content for this topic,
        // not an oversight: Sustain derives no number and makes no claim from
        // a lab value, so there is nothing here to cite. The topic exists so
        // its `explainer` (which states exactly that, and points the user
        // back at their own report and clinician) is reachable from the
        // feature via `MedicalSourcesLink`, satisfying 1.4.1's "explain the
        // health information in the app" requirement honestly rather than
        // padding this list with studies the app doesn't actually rely on.
        .labResults: [],
        // Added 2026-08-07 for the behavior-change/setback-reframing feature — see
        // `Behavior-Change-Layer-Scoping-2026-08.md`. Deliberately behavioral-science
        // citations, not medical ones: this topic supports how the app talks about a
        // missed day or a broken streak, not a clinical claim about the medication or
        // the body. All three are peer-reviewed and PubMed/DOI-linked, the same
        // sourcing bar as every other topic here.
        .consistency: [
            MedicalSource(
                id: "lally-2010",
                citation: "Lally P, van Jaarsveld CHM, Potts HWW, Wardle J. How are habits formed: Modelling habit formation in the real world. Eur J Soc Psychol. 2010;40(6):998-1009.",
                supports: "Missing a single day of a routine barely affects habit strength, and it recovers quickly rather than resetting progress.",
                urlString: "https://onlinelibrary.wiley.com/doi/10.1002/ejsp.674"
            ),
            MedicalSource(
                id: "larimer-1999",
                citation: "Larimer ME, Palmer RS, Marlatt GA. Relapse Prevention: An Overview of Marlatt's Cognitive-Behavioral Model. Alcohol Res Health. 1999;23(2):151-160.",
                supports: "The distinction between a single lapse and a full relapse (the \"abstinence violation effect\"), and how treating a lapse as catastrophic makes a return to the routine less likely, not more.",
                urlString: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6760427/"
            ),
            MedicalSource(
                id: "thogersen-ntoumani-2021",
                citation: "Thøgersen-Ntoumani C, Dodos L, Chatzisarantis NLD, Ntoumanis N. Does self-compassion help to deal with dietary lapses among overweight and obese adults who pursue weight-loss goals? Br J Health Psychol. 2021;26(4):1237-1255.",
                supports: "Responding to a dietary/health-behavior lapse with self-compassion, rather than self-criticism, predicts higher self-efficacy and stronger intentions to continue, not a weaker resolve.",
                urlString: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8451927/"
            ),
        ],
        // Added 2026-08-08 alongside the AI photo body-fat estimate feature. One
        // citation, deliberately: it's the best available real validation of
        // photo-based body-fat estimation against DEXA, and the `explainer` above
        // is explicit that it validated a different (purpose-built, controlled-
        // protocol) system than the general-purpose AI vision call Sustain
        // actually makes — padding this with more sources wouldn't change that
        // honest gap.
        .bodyScanEstimate: [
            MedicalSource(
                id: "majmudar-2022",
                citation: "Majmudar MD, Chandra S, Yakkala K, et al. Smartphone camera based assessment of adiposity: a validation study. NPJ Digit Med. 2022;5(1):79.",
                supports: "Photo-based body-fat estimation can approach DEXA accuracy (mean absolute error 2.16% ± 1.54%) under a controlled two-photo protocol with a purpose-built model — the best-case evidence for this category of feature, not a claim about Sustain's own general-purpose AI estimate's accuracy.",
                urlString: "https://pubmed.ncbi.nlm.nih.gov/35768575/"
            ),
        ],
        .maintenance: [
            MedicalSource(
                id: "hall-2018",
                citation: "Hall KD, Kahan S. Maintenance of Lost Weight and Long-Term Management of Obesity. Med Clin North Am. 2018;102(1):183-197.",
                supports: "Why maintenance is treated as its own phase with a range rather than a single falling target.",
                urlString: "https://pubmed.ncbi.nlm.nih.gov/29156185/"
            ),
            MedicalSource(
                id: "step4-2021",
                citation: "Rubino D, Abrahamsson N, Davies M, et al. Effect of Continued Weekly Subcutaneous Semaglutide vs Placebo on Weight Loss Maintenance in Adults With Overweight or Obesity (STEP 4). JAMA. 2021;325(14):1414-1425.",
                supports: "What happens to weight when GLP-1 treatment is continued versus withdrawn after the losing phase.",
                urlString: "https://pubmed.ncbi.nlm.nih.gov/33755728/"
            ),
        ],
        // Added 2026-09-27 alongside the "Life After GLP-1" feature. One citation,
        // deliberately: it's the direct extension of the same STEP 1 trial already
        // cited under `.maintenance` above, specifically measuring what happens after
        // stopping rather than continuing — the exact question this topic exists to
        // answer honestly.
        .discontinuation: [
            MedicalSource(
                id: "step1-extension-2022",
                citation: "Wilding JPH, Batterham RL, Davies M, et al. Weight regain and cardiometabolic effects after withdrawal of semaglutide: The STEP 1 trial extension. Diabetes Obes Metab. 2022;24(8):1553-1564.",
                supports: "People who stopped semaglutide (and structured lifestyle support) regained roughly two-thirds of their prior weight loss over the following year.",
                urlString: "https://pubmed.ncbi.nlm.nih.gov/35441470/"
            ),
        ],
    ]

    static func sources(for topic: MedicalSourceTopic) -> [MedicalSource] {
        byTopic[topic] ?? []
    }

    static var all: [MedicalSource] {
        MedicalSourceTopic.allCases.flatMap { sources(for: $0) }
    }

    /// The single disclaimer string used everywhere, so the app never drifts into
    /// several slightly different versions of the same promise.
    static let disclaimer = """
    Sustain is a tracking tool, not a medical device, and it does not provide medical \
    advice, diagnosis, or treatment. The targets and schedules it shows are general \
    reference information from the sources listed here. Always follow your own \
    prescriber's instructions, and talk to them before changing a dose, your diet, or \
    anything else about your treatment.
    """
}
