# CodePilot Mobile

AI coding agent for Android (Flutter). Works with any OpenAI-compatible API —
default preset **xKiro** (`https://api.xkiro.com/v1`, model
`qwen/qwen3.7-flash:free`). Import a project ZIP, browse/search/read files,
chat with the AI, review diffs, apply changes with undo, and export the
modified project.

> **Build status: source-only.** This repository ships complete Dart source
> but no compiled APK (the packaging environment has no Flutter SDK). Build it
> yourself (below) or let the included GitHub Actions workflow build the APK
> for you.

## Screens

Home (minimal: header + overflow menu + File/Search/Integrate bar) · Projects ·
Search History · Integrations · Help & Feedback · Import Project · Project
Explorer · AI Coding Chat (persistent sessions, resumable, copyable code
blocks) · Search Results · File Preview (copy + Ask-AI) · Change Diff ·
Build Logs · Export Project · Settings · Custom API Provider

## Power features

- **Chat memory** — every conversation is saved on-device (last 30) and
  resumes automatically after an app restart. Chat → 💬 lists and resumes
  previous chats, ✚ starts a new one.
- **Real file attachments** — the Home File button sends the actual file
  content to the AI (up to 12k chars, binary-safe), not just the name.
- **Copyable code blocks** — assistant replies render fenced code as
  monospace cards with a one-tap copy button; File Preview can copy the
  whole file or hand it to the AI with one tap.

## Security model

- The API key lives **only** in Android secure storage
  (`flutter_secure_storage`, Keystore-backed `EncryptedSharedPreferences`).
- It is sent only in the `Authorization: Bearer` header to your provider.
- It is never written to chat, logs, project files, error messages, or
  exported ZIPs (export strips any `.codepilot_exclude` entries too).
- `analysis_options.yaml` enforces `avoid_print`.

## Build locally

```bash
flutter create . --org com.codepilot --project-name codepilot_mobile   # regenerate android/ios platform folders
flutter pub get
flutter analyze
flutter test
flutter build apk --debug      # output: build/app/outputs/flutter-apk/app-debug.apk
```

## Build via GitHub Actions (no local SDK needed)

1. Push this folder to a GitHub repository.
2. The included `.github/workflows/flutter-build.yml` runs on every push:
   pub get → analyze → test → `flutter build apk --debug` → upload artifact.
3. Download `app-debug-apk` from the workflow run's Artifacts.

## Sign-in options

Integrations → GitHub → **Sign in** offers two methods:

1. **Sign in with GitHub** — the official OAuth device flow. The app shows
   the one-time code on a big card (copy button + "Open GitHub"); enter it
   at github.com/login/device. This is the only way GitHub itself allows
   sign-in without a redirect server — GitHub does not offer email OTP.
2. **Sign in with email** — CodePilot's own one-time-code sign-in. Requires
   a [Resend](https://resend.com) API key:
   - Local/CI builds: `flutter build apk --debug --dart-define=RESEND_API_KEY=re_…`
     (the GitHub Actions workflow picks it up from a repository secret named
     `RESEND_API_KEY` automatically).
   - Emails are sent from `onboarding@resend.dev`; use your own verified
     domain by changing the `from` address in `lib/github_service.dart`.

Both identities are stored on-device (token in Keystore-backed secure
storage, email in SharedPreferences) and neither is ever exported.

## API setup (in-app)

Home ⋮ menu → Settings → **Custom API Provider** (shows your provider, model,
and a masked key once saved):

| Field | Value |
|---|---|
| Provider name | xKiro |
| Base URL | `https://api.xkiro.com/v1` |
| Model ID | `qwen/qwen3.7-flash:free` |
| API key | your key (secure storage, never hardcoded) |

Save → **Test connection** makes a real `/chat/completions` request.
**Fetch model list** hits `/models` for the selector. Timeout and streaming
(SSE) are configurable.

## Notes on builds inside the app

`flutter build apk`, `flutter test`, and dependency installation require the
Flutter/Android toolchain, which cannot run inside an Android app sandbox.
The Build screen therefore runs real local static checks (project type,
manifests, lockfiles, TODO scan) and never fakes a build result — it points
you to the included GitHub Actions workflow for a real APK.
