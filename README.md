This project was completed jointly by me and Codex. If you are interested in my project, please contact me at [ dsong25@gmu.edu ]. Thank you for your attention.

HealthPlanner

HealthPlanner is a local-only iPhone health and training planner built with SwiftUI and HealthKit. It combines Apple Health data, personal baselines, workout history, recovery modeling, and a user profile to generate adaptive daily recommendations without a backend, cloud sync, or login.

Core Product Idea

The app acts as a lightweight personal recovery and training coach. Instead of only showing raw Apple Health data, it interprets your current body state and recent training context to answer questions like:

• How ready am I today?
• Should I rest, walk, run, do mobility, or strength work?
• Which muscle groups are fresh, recovering, or fatigued?
• How much training is appropriate for me personally?
• When should I wind down and sleep tonight?

Everything runs locally on device.

⸻

Smartest Features

1. HealthKit-Driven Daily Body State
HealthPlanner reads real HealthKit data and uses it as the foundation of daily decision-making.

Currently supported inputs include:
• Sleep
• Heart rate
• Resting heart rate
• HRV (SDNN)
• Step count
• Workouts

The app does not just display these metrics. It interprets them relative to your own rolling baseline and uses them to drive recommendations.

Highlights:
• Sleep is aggregated from HealthKit sleep stages into a more realistic daily sleep estimate
• Resting HR and HRV are compared against your personal baseline rather than generic thresholds
• Step count is used both for daily movement progress and passive workout completion logic
• Workout data is imported from HealthKit and fed into recovery and recommendation systems

⸻

2. Personal Baseline Engine
The app maintains rolling personal baselines instead of treating all users the same.

It computes multi-timescale summaries such as:
• 7-day recent state
• 28-day rolling baseline
• 84-day longer-term trend

Tracked baseline domains include:
• Sleep
• Resting heart rate
• HRV
• Daily steps
• Workout balance
• Muscle coverage balance

Why this matters:
• A resting HR of 60 may be good for one person and elevated for another
• An HRV of 45 may be normal for one user and poor for another
• The app evaluates changes relative to your own baseline, not a generic population average

⸻

3. Dynamic Daily Status Score
The app computes a live “Today’s Status” score rather than using a static morning score.

The score is designed as a dynamic state, not just a one-time readiness label. It considers:
• Morning recovery signals
• Personal baseline deviation
• Passive recovery response
• Systemic fatigue
• Time awake during the day
• Activity accumulated so far
• Workout completion and recent training cost

Important behavior:
• Status naturally declines as the day progresses
• Finishing a workout lowers the remaining available state for the rest of the day
• The app avoids blindly resetting the status at midnight if new recovery data is not yet available

This makes the score behave more like real daily energy availability instead of a fixed “morning readiness” badge.

⸻

4. Adaptive Recommendation Engine
The recommendation engine is rule-based, interpretable, and increasingly personalized.

It outputs:
• Recommendation type
• Specific target focus
• Exercise selection
• Duration
• Intensity
• Volume tier
• Confidence level
• Explanation

Supported recommendation types:
• Rest
• Walk
• Easy Run
• Mobility
• Strength

The engine blends several internal signals:
• Recovery score
• Activation need score
• Training balance score
• Muscle readiness score
• Passive recovery response score
• Confidence score

It also logs recommendation drivers for debugging and transparency.

⸻

5. Personal Capability Profile from User Profile Data
The app now converts profile data into a reusable capability layer instead of only storing it.

Inputs used include:
• Height
• Weight
• Age
• Training goal
• Training experience
• Estimated 5k time
• Max push-ups
• Max pull-ups
• Estimated bench press
• Estimated lat pulldown
• Estimated squat

These are transformed into capability dimensions such as:
• Aerobic capacity
• Upper push strength
• Upper pull strength
• Lower body strength
• Recovery capacity
• Consistency capacity
• Load tolerance

These capability scores influence:
• Training type selection
• Session duration
• Strength volume
• Intensity tier
• Load guidance
• Training conservatism vs progression

This means two users with the same HRV and sleep can still receive different training plans if their actual ability and training background differ.

⸻

6. Strength Prescription That Uses Real Context
Strength recommendations are not generic placeholders.

When the app recommends strength work, it generates:
• Target muscle focus
• Exercise list from enabled exercises only
• Sets
• Reps
• Rest time
• Load guidance

Prescription logic accounts for:
• Current recovery state
• Muscle freshness
• Goal
• Experience
• Capability profile
• Available enabled exercises
• Estimated strength values where available

Examples:
• Beginners are biased toward lighter volume tiers
• More experienced users can move into higher volume when recovery supports it
• Bench / pulldown / squat estimates influence load guidance
• If no load estimate exists, the app falls back to RPE / reps-in-reserve guidance

⸻

7. Muscle Recovery Model
The app tracks recovery by muscle group rather than only giving a whole-body suggestion.

Modeled regions include:
• Chest
• Back
• Biceps
• Forearms
• Quads
• Hamstrings
• Glutes
• Adductors
• Calves
• Cardio/Systemic fatigue

Recovery is updated from completed sessions using:
• Session type
• Workout duration
• Intensity
• Volume estimate
• Target muscles
• Decay over time
• Passive recovery response
• Training experience

This enables smarter behavior such as:
• Avoiding repeated training on a not-yet-recovered muscle group
• Separating local muscle fatigue from systemic fatigue
• Making recommendations that reflect actual recent training stress

⸻

8. Passive Workout Detection and Completion
The app is designed to reduce user effort.

It does not rely only on tapping “Start Session.” It can infer completion from real data:

• Walking and running recommendations can be passively marked complete using step progression and activity changes
• HealthKit workouts are imported and translated into local training sessions
• Generic strength workouts can be interpreted using the day’s recommended plan context
• Completed sessions update history, recovery state, and future recommendations automatically

This makes the app behave more like a real assistant and less like a manual logging tool.

⸻

9. Smarter Workout Interpretation from HealthKit
HealthKit workout data is not just displayed as a list item.

The app tries to infer what the workout means for the body:
• Walks and runs affect lower-body and systemic fatigue
• Cardio workouts affect systemic state and relevant muscle regions
• Strength workouts can inherit the planned target muscles from the current day’s recommendation
• Imported workouts feed the same recovery system as manually tracked sessions

This allows HealthKit data to directly change:
• Muscle freshness
• Recovery state
• Today completion state
• Recommendation follow-up logic

⸻

10. Routine Recommendation for Tonight
The app includes a separate routine recommendation engine for evening recovery and bedtime guidance.

It uses:
• Sleep vs baseline
• Resting HR vs baseline
• HRV vs baseline
• Step progress
• Recent training load
• Passive recovery score
• Current time
• Weather context

Outputs include:
• Whether tonight should prioritize rest, light activity, or normal activity
• A dynamic bedtime target
• A short explanation of why

The bedtime logic is no longer a fixed 23:00 suggestion. It now adapts to:
• Sleep debt
• Recovery pressure
• Training load
• Evening timing constraints
• Practical minimum time before bed

⸻

11. Cross-Day Stability Logic
The app handles midnight and new-day transitions more carefully.

This matters because health data often arrives asynchronously and not all metrics are ready right after 00:00.

Current protections include:
• If step data is temporarily unavailable after midnight, the UI can hold the last known value instead of showing a false “error-like” empty state
• If there is no new recovery anchor yet, the daily status does not blindly reset upward
• Sleep and body-state updates are gated so the app does not produce unrealistic new-day conclusions too early

This improves reliability around day boundaries.

⸻

12. Visual Health Dashboard
The Home screen is designed as a compact, glanceable dashboard rather than a raw prototype.

It includes:
• Today’s status
• Sleep trend
• Resting HR trend
• HRV trend
• Step goal and expected-by-now progress
• Muscle recovery state
• Routine recommendation
• Recommendation summary

Data visualization includes:
• 7-day sleep bars
• Resting HR trend line
• HRV trend line
• Daily step progress
• Compact muscle recovery heat-style cards

The UI is localized and built around a unified dark design system.

⸻

13. In-App Language Switching
The app supports in-app language switching independent of system language.

Supported languages:
• English
• Simplified Chinese

Localization covers:
• Main tabs
• Dashboard labels
• Recommendation labels
• Profile and settings
• Exercise names
• Dynamic recommendation text
• Routine recommendation explanations
• Many fallback and diagnostic messages

The localization architecture is key-based, so both static and dynamic UI text can be translated consistently.

⸻

14. Local-Only Persistence
All core app data is stored locally on device.

Persisted data includes:
• User profile
• Enabled exercises
• Custom exercises
• Daily health history
• Workout sessions
• Passive recovery responses
• Feedback
• App settings

There is:
• No backend
• No account system
• No cloud sync
• No external database service

This keeps the product private, lightweight, and easy to reason about.

⸻

15. Interpretable, Debuggable Logic
The app is intentionally not a black-box recommender.

It exposes and logs:
• Recommendation scores
• Score drivers
• Selected exercises
• Recovery decisions
• Passive completion behavior
• Imported workout effects

This makes it possible to:
• Validate why a recommendation was generated
• Debug unexpected outputs
• Improve the engine over time without losing interpretability

⸻

Summary
HealthPlanner is currently more than a metric dashboard. It is a local, adaptive, profile-aware recovery and training planner that combines:

• Real HealthKit data
• Personal baselines
• Dynamic body-state tracking
• Muscle recovery modeling
• Capability-aware recommendations
• Passive workout detection
• Evening routine guidance
• Bilingual UI
• Local-only privacy

The app is designed to keep getting smarter while remaining explainable, conservative, and health-oriented.
