# homi

**Home Modifications for Independence**

We built homi to help people review their homes, identify changes they may need, and find possible help paying for them. It brings room assessments, assistance programs, draft forms, and follow-up tasks into one iPhone and Android app.

## What it does

- Create and name home plans, save them to an account, and resume them across devices.
- Organize a home into named rooms and record safety concerns with room checklists.
- Scan rooms in 3D using LiDAR or camera-based capture on supported phones. Photos and manual measurements are available as alternatives.
- Review model features and findings before adding them to a plan.
- Find home-repair and accessibility resources by location, and compare the requirements of the programs included in the app.
- Prepare draft application forms or checklists with reviewed answers and selected photos.
- Track follow-up tasks, reminders, and application updates, and give helpers access to selected information.
- Ask the on-device assistant for help with the current plan on compatible phones.

The interface supports English, Spanish, Simplified Chinese, Traditional Chinese, Vietnamese, and Filipino. Available capture and assistant features depend on the phone. Connected features also need the corresponding backend configuration.

Program results are possible assistance options, not funding approvals. Scans are approximate, and application files remain drafts until the resident completes the program's submission process. We use fictional cases for the team beta.

## Built with

Flutter and Dart for the app, Swift for iPhone features, Kotlin for Android features, Node.js and TypeScript for the API, and Supabase Auth with PostgreSQL for accounts and storage.

## Run locally

The project uses Flutter 3.41.5, Dart 3.11.3, and Node.js 24.12 or later. iPhone builds need Xcode; Android builds need the Android SDK.

```sh
flutter pub get
npm --prefix backend ci --ignore-scripts
flutter run
```

The default build opens fictional examples. To connect the app, create an ignored configuration file containing `SAH_LIVE_BACKEND`, `SAH_API_URL`, `SUPABASE_URL`, and `SUPABASE_PUBLISHABLE_KEY`:

```sh
flutter run --dart-define-from-file=backend/local-artifacts/mobile-config.json
```

Set `SAH_LIVE_BACKEND` to `true` and use the configured HTTPS API address. Keep database passwords and elevated credentials out of the app configuration.

## Check the project

```sh
bash tool/verify_project.sh all
```

This checks Dart formatting, Flutter analysis and tests, backend types and tests, shared contracts, and local HTTP integration. Native builds and physical-device checks are separate.

The [backend README](backend/README.md), [Android README](android/README.md), and [device-test README](integration_test/README.md) cover their setup and checks.
