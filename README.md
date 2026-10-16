# Sustain — GLP-1 Companion

A native iOS app for people on GLP-1 medications (Ozempic, Wegovy, Zepbound, Mounjaro, and others), built around a muscle-preservation angle rather than generic weight tracking. [Live on the App Store](https://apps.apple.com/us/app/sustain-glp-1-companion/id6793802192).

I wrote roughly half of this Swift/SwiftUI codebase by hand and directed AI-assisted development on the rest, most notably the AI photo-to-protein-estimate feature.

## What it does

- Dose logging with injection-site rotation tracking, on a configurable schedule
- Weight and protein intake tracking, including an AI photo-to-protein estimate (a photo of a meal is sent through a Supabase Edge Function proxy to Claude, never a key shipped in the client)
- Side-effect logging with a shareable summary a user can bring to a prescriber
- Apple Watch companion app and Lock Screen / Dynamic Island Live Activities for dose reminders
- HealthKit sync (weight, protein) in both directions
- Sign in with Apple, with account data synced across devices via Supabase
- Subscription billing via RevenueCat/StoreKit, with a free tier for manual logging

## Stack

SwiftUI, SwiftData (local persistence), HealthKit, WidgetKit/ActivityKit (Live Activities), RevenueCat + StoreKit (billing), Supabase (Auth, Postgres, Edge Functions). The project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) rather than a committed `.xcodeproj`.

## Structure

```
Sustain/                 iOS app target
  App/                   App entry point and root view
  Models/                SwiftData models (dose logs, weight, protein, side effects, titration)
  Services/              Business logic: HealthKit sync, notifications, AI estimator, auth, entitlements
  ViewModels/
  Views/                 Onboarding, Dashboard, Logging, Trends, Paywall, Settings
SustainWatch/            watchOS companion app
SustainWidgetExtension/  Lock Screen / Dynamic Island widgets
SustainTests/            Unit tests
supabase/functions/      Edge Functions: the Claude API proxy, account deletion, referrals
```

## Running it

This repo has the app's source but not the generated Xcode project or any real credentials.

```bash
brew install xcodegen
xcodegen generate
cp Sustain/Secrets.xcconfig.example Sustain/Secrets.xcconfig
# fill in Secrets.xcconfig with your own Supabase/RevenueCat/TelemetryDeck project values
open Sustain.xcodeproj
```

Without a Secrets.xcconfig filled in, the app builds and runs, but the AI photo-estimate, cloud sync, and billing features no-op gracefully rather than crash.

## License

Source is shared for portfolio purposes. Not licensed for reuse or redistribution.
