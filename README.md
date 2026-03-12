## This project was completed jointly by me and Codex. If you are interested in my project, please contact me at [ dsong25@gmu.edu ]. Thank you for your attention.

# HealthPlanner

A local-only iPhone health planner that uses Apple Health and Apple Watch data to generate personalized exercise, recovery, and routine recommendations.

## Overview

HealthPlanner is a personalized iPhone wellness and training planning app built around a simple idea:

**Use real body signals, not generic templates, to decide what kind of activity is most appropriate today.**

Instead of relying only on fixed workout plans or heavy manual logging, the app reads Apple Health data, estimates daily readiness and recovery, tracks recent activity patterns, and recommends suitable exercise, intensity, and routine adjustments.

The project focuses on three principles:

- **Local-first**: no backend, no account system, no cloud dependency for core logic
- **Personalized**: decisions are based on the user’s own historical baseline, not only generic population rules
- **Low-friction**: after initial setup, the app tries to minimize daily manual input and rely more on passive physiological and activity data

---

## Core Goals

HealthPlanner is designed to help a user:

- maintain a healthier and more consistent lifestyle
- improve activity balance across walking, cardio, recovery, and strength work
- avoid overtraining on poor-recovery days
- avoid being too inactive on good-recovery days
- build a more sustainable exercise rhythm rather than chasing random hard sessions

This is not intended to be a medical diagnostic tool. It is a **local personal health-and-training planner**.

---

## Current Product Direction

The app is built around a personalized daily recommendation loop:

1. Read Apple Health data
2. Build personal baselines from historical trends
3. Compare the current day against those baselines
4. Estimate recovery / readiness / movement need
5. Recommend today’s activity
6. Track completed activity
7. Update future recommendations based on body response over time

