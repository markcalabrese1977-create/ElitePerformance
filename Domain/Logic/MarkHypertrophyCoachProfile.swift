import Foundation

/// Protocol for any "coach brain" in the app.
/// We can later add AngelaFatLossCoachProfile, SimpleLinearProfile, etc.
public protocol CoachProfile {
    /// Stable identifier for saving settings.
    var id: String { get }

    /// Human-readable name for UI.
    var displayName: String { get }

    /// Main decision function:
    /// Given the current set, some history, and daily readiness,
    /// return a recommendation for what to do.
    func recommendation(
        for context: SetContext,
        history: [SetContext],
        dayReadiness: DayReadiness
    ) -> SetRecommendation
}

/// Concrete implementation of your "Mark Hypertrophy" rules v1.
/// This is v0.1 of the logic — we can keep refining the internals
/// without changing the external interface.
public struct MarkHypertrophyCoachProfile: CoachProfile {

    public let id: String = "mark_hypertrophy_v1"
    public let displayName: String = "Mark – Hypertrophy v1"

    /// Week at or above this value is treated as "late meso" (1 RIR bias mode).
    private let lateMesoStartWeek: Int = 4

    /// Default constructor.
    public init() {}

    public func recommendation(
        for context: SetContext,
        history: [SetContext],
        dayReadiness: DayReadiness
    ) -> SetRecommendation {

        // Basic guardrails first: pain and extreme fatigue override everything.
        if let pain = context.painScore, pain >= 4 {
            return SetRecommendation(
                adjustment: .decreaseLoad(percentage: 5.0),
                rationale: "Pain \(pain)/10 on this set – drop ~5% load and focus on form or swap to a friendlier variation next time."
            )
        }

        // If the user is absolutely trashed, err conservative.
        if dayReadiness.fatigue >= 8 {
            return conservativeRecommendation(for: context)
        }

        // Determine if we're in late meso 1-RIR bias mode.
        let isLateMeso = context.weekInMeso >= lateMesoStartWeek

        // If RIR is missing, don't add extra chatter.
        // Let the plan-vs-actual coaching handle the message.
        guard let actualRIR = context.actualRIR else {
            return SetRecommendation(
                adjustment: .keepSame,
                rationale: ""
            )
        }

        let targetRIR = context.targetRIR ?? (isLateMeso ? 1.0 : 2.0)

        // Branch for late vs early meso.
        if isLateMeso {
            return lateMesoRecommendation(
                context: context,
                actualRIR: actualRIR,
                targetRIR: targetRIR,
                dayReadiness: dayReadiness
            )
        } else {
            return earlyMesoRecommendation(
                context: context,
                actualRIR: actualRIR,
                targetRIR: targetRIR,
                dayReadiness: dayReadiness
            )
        }
    }

    // MARK: - Early Meso (2–3 RIR bias)

    private func earlyMesoRecommendation(
        context: SetContext,
        actualRIR: Double,
        targetRIR: Double,
        dayReadiness: DayReadiness
    ) -> SetRecommendation {

        // Third working set (index 2) is where we decide on the "one to know" test set.
        let isThirdSet = (context.setIndex == 2)

        // If RIR is much higher (easier) than target, we likely under-shot.
        if actualRIR >= targetRIR + 1.5 {
            if isThirdSet {
                // You've got plenty in the tank; add the test set now.
                return SetRecommendation(
                    adjustment: .addTestSetNow,
                    rationale: "All working sets feel easier than target (\(actualRIR.rounded(to: 1)) RIR vs target \(targetRIR)) – add the 4th test set and push closer to 1–2 RIR."
                )
            } else {
                // Earlier sets: push for more reps before changing load.
                return SetRecommendation(
                    adjustment: .pushForMoreReps,
                    rationale: "This set felt easier than target RIR – keep the same load and aim for more reps next time before bumping weight."
                )
            }
        }

        // If RIR is much lower (harder) than target, we overshot.
        if actualRIR <= targetRIR - 1.5 {
            if isThirdSet {
                return SetRecommendation(
                    adjustment: .skipTestSetNow,
                    rationale: "You pushed harder than planned this set – skip the optional 4th set and recover instead of grinding."
                )
            } else {
                return SetRecommendation(
                    adjustment: .easeOffReps,
                    rationale: "You pushed closer to failure than the 2–3 RIR target – keep the load but cap reps slightly earlier next time."
                )
            }
        }

        // If we're roughly on target RIR:
        if isThirdSet {
            // Let fatigue + day readiness decide whether to add a test set.
            if dayReadiness.fatigue <= 6 {
                return SetRecommendation(
                    adjustment: .addTestSetNow,
                    rationale: "RIR on target and fatigue manageable – green light to run a 4th test set and push closer to 1–2 RIR."
                )
            } else {
                return SetRecommendation(
                    adjustment: .skipTestSetNow,
                    rationale: "RIR is on target but fatigue is elevated – skip the test set and keep it to 3 quality working sets."
                )
            }
        } else {
            // Normal case: on target, early sets – keep course.
            return SetRecommendation(
                adjustment: .keepSame,
                rationale: "RIR is on target for early meso – stay with this load and rep range, focus on clean execution."
            )
        }
    }

    // MARK: - Late Meso (1 RIR bias)

    private func lateMesoRecommendation(
        context: SetContext,
        actualRIR: Double,
        targetRIR: Double,
        dayReadiness: DayReadiness
    ) -> SetRecommendation {

        let isThirdSet = (context.setIndex == 2)

        // In late meso, we want ~1 RIR on compounds.
        // If you're still very far from failure, we can push harder.
        if actualRIR >= targetRIR + 1.5 {
            if isThirdSet {
                return SetRecommendation(
                    adjustment: .addTestSetNow,
                    rationale: "Late meso and this still felt easy – add a 4th test set and push closer to 0–1 RIR."
                )
            } else {
                return SetRecommendation(
                    adjustment: .pushForMoreReps,
                    rationale: "Late meso with extra room – keep the load and push for more reps next time to approach 1 RIR."
                )
            }
        }

        // If you accidentally took it to or past failure.
        if actualRIR <= 0 {
            if isThirdSet {
                return SetRecommendation(
                    adjustment: .skipTestSetNow,
                    rationale: "You essentially hit failure on this set – skip the test set and let this be the top work for today."
                )
            } else {
                return SetRecommendation(
                    adjustment: .easeOffReps,
                    rationale: "You went to or past failure earlier than planned – keep the load but stop 1 rep sooner next time."
                )
            }
        }

        // If you're slightly harder than target (e.g. target 1, you hit 0.5), it's acceptable but we don't add more volume.
        if actualRIR < targetRIR {
            if isThirdSet {
                return SetRecommendation(
                    adjustment: .skipTestSetNow,
                    rationale: "You pushed slightly harder than target in late meso – skip the test set and avoid junk fatigue."
                )
            } else {
                return SetRecommendation(
                    adjustment: .keepSame,
                    rationale: "Slightly below target RIR in late meso is fine – keep the load and repeat this effort next time."
                )
            }
        }

        // On-target RIR in late meso: test set only if readiness is decent.
        if isThirdSet {
            if dayReadiness.fatigue <= 6 && dayReadiness.sleepQuality >= 3 {
                return SetRecommendation(
                    adjustment: .addTestSetNow,
                    rationale: "On-target RIR in late meso with decent readiness – add the 4th test set and push close to failure."
                )
            } else {
                return SetRecommendation(
                    adjustment: .skipTestSetNow,
                    rationale: "RIR is on target but readiness is mediocre – keep it to 3 high-quality sets today."
                )
            }
        } else {
            return SetRecommendation(
                adjustment: .keepSame,
                rationale: "RIR is on target for late meso – keep the load and aim to match or slightly beat today’s performance."
            )
        }
    }

    // MARK: - Conservative fallback when very fatigued

    private func conservativeRecommendation(for context: SetContext) -> SetRecommendation {
        let isThirdSet = (context.setIndex == 2)
        if isThirdSet {
            return SetRecommendation(
                adjustment: .skipTestSetNow,
                rationale: "Global fatigue is high – cap at 3 sets and skip the test set to avoid digging a recovery hole."
            )
        } else {
            return SetRecommendation(
                adjustment: .easeOffReps,
                rationale: "Global fatigue is high – keep load but stop 1–2 reps sooner on each set."
            )
        }
    }
}

// MARK: - Small helper

private extension Double {
    func rounded(to places: Int) -> Double {
        guard places >= 0 else { return self }
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
