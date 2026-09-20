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

Home (minimal: header + overflow menu + unified Ask composer) · Projects ·
Search History · Integrations · Help & Feedback · Import Project · Project
Explorer · AI Coding Chat (persistent sessions, resumable, copyable code
blocks) · Search Results · File Preview (copy + Ask-AI) · Change Diff ·
Build Logs · Export Project · Settings · Custom API Provider

## Power features

- **Multi-provider API keys** — the 🔑 header button opens the API Key
  Manager: any mix of OpenRouter, OpenAI, Google Gemini, Anthropic and
  custom OpenAI-compatible providers, each with multiple key slots, model,
  optional base URL, enable/disable, priority and default. Keys are masked
  (••••••••8F42), stored only in Keystore-backed secure storage, and never
  logged. Automatic routing tries Priority 1 first and falls back across
  keys/providers on rate limits, quota, invalid keys or outages (capped at
  5 attempts); Manual mode pins one provider. The previous single-provider
  setup migrates automatically on first open.
- **Project preview — no GitHub needed** — ▶ Preview (chat bottom bar, and
  the completed-task card) serves the open project over a loopback HTTP
  server and renders it in an in-app WebView: real CSS, real JavaScript,
  relative assets, SPA fallback. Static HTML/CSS/JS projects work fully
  offline. Flutter/Android/Node/Python/React-Next projects honestly show
  "Preview unavailable" with the real reason and options — never a fake
  preview. Reload, Open-in-browser and copy-URL actions included.
- **Chat memory** — every conversation is saved on-device (last 30) and
  resumes automatically after an app restart. Chat → 💬 lists and resumes
  previous chats, ✚ starts a new one.
- **Real file attachments** — the Home File button sends the actual file
  content to the AI (up to 12k chars, binary-safe), not just the name.
- **Copyable code blocks** — assistant replies render fenced code as
  monospace cards with a one-tap copy button; File Preview can copy the
  whole file or hand it to the AI with one tap.
- **Live agent activity** — while a task runs you see the model's short
  reasoning, real file reads/edits, terminal cards with actual output and
  exit codes, phase progress, and elapsed time. The final "What the agent
  did" summary is computed only from executed steps (no fake statistics),
  failures show an honest "Task incomplete" block with Retry, and the
  whole activity timeline is persisted mid-run so reopening the chat
  restores the exact state.

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
   pub get → analyze → test → debug APK → **small per-ABI release APKs** →
   (when signing is configured) a signed Play **App Bundle**.
3. Download artifacts from the workflow run: `app-release-apks` for a small
   sideload install (use `app-arm64-v8a-release.apk` on modern phones).

### Google Play upload signing (optional, for publishing)

Create a keystore once, locally:

```bash
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA \
    -keysize 2048 -validity 10000 -alias upload
base64 -w0 upload-keystore.jks   # macOS: base64 -i upload-keystore.jks
```

Add four repository **secrets** (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `KEYSTORE_BASE64` | the base64 string from the command above |
| `KEYSTORE_PASSWORD` | keystore password you chose |
| `KEY_ALIAS` | `upload` |
| `KEY_PASSWORD` | key password you chose |

With the secrets present, release APKs are signed with your upload key and
the workflow additionally produces `app-release-aab` for Play Console.
Without them, release APKs are debug-signed (fine for sideloading).
**Back up the keystore file and passwords** — Google requires the same key
for every update of the app.

## Sign-in options

Integrations → GitHub → **Sign in** offers two methods:

1. **Sign in with GitHub** — the official OAuth device flow. The app shows
   the one-time code on a big card (copy button + "Open GitHub"); enter it
   at github.com/login/device. Polling honors GitHub's interval, survives
   transient connection drops while the app is backgrounded (explicit
   timeouts + bounded retries), is cancelled cleanly when the sheet closes,
   and the token is verified via `GET /user` before GitHub shows
   **Connected** with your username/avatar. This is the only way GitHub
   itself allows sign-in without a redirect server — GitHub does not offer
   email OTP.
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
