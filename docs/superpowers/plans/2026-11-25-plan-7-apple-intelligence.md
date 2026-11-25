# Plan 7 — Apple Intelligence Features

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Four on-device Apple Intelligence features that appear only when Apple Intelligence is available and turned on. They are part of v0.1.0.

**Owner decisions (2026-11-25, via question tool):**
- all four features below
- hidden completely when unavailable
- included in v0.1.0

**Architecture:**
- A new package target `Assistant` that depends on `LocalLibrary`, `AppCore` and `DownscaleVideo`, plus Apple's `FoundationModels`.
- Every model call goes through one protocol `LanguageModelClient`, so tests use a fake and never need the model:
  - `isAvailable`
  - `respond(to:instructions:) -> String`
  - `generate<T: Generable>(_:instructions:) -> T`
- The real client wraps `SystemLanguageModel.default` and `LanguageModelSession`.
- `AssistantAvailability` (`@MainActor @Observable`):
  - reads `SystemLanguageModel.default.availability`
  - `.available` → shown
  - any `.unavailable(reason)` → hidden
  - re-checked when the app becomes active, since the user may turn Apple Intelligence on or off in System Settings

## Global Constraints

- **Hidden completely when unavailable.** No AI control, menu item, placeholder text, empty space or log noise appears unless `isAvailable` is true. With it false, the app looks exactly as it does today.
- **On-device only.** Use `FoundationModels` and the system model; no network or third-party models. Prompts contain metadata only (names, dates, sizes, resolutions, codecs, badges, outcome reasons). Never send video frames or file contents, and never log prompts or responses with personal file names.
- **The model never acts on its own.** Every result is shown for the user to confirm: filters as editable chips, picks with an "Add these to the queue" button. Nothing is queued, deleted or replaced by the model, and Siri/Spotlight quick runs follow Plan 4's rules (never Replace, skip on loss).
- **Graceful failure.** Handle these without crashing or blocking the UI:
  - model errors: guardrail refusals, context too long, rate limits and unsupported language
  - timeouts: 10 s for a query, 20 s for a summary

  Fall back silently: the plain-text search still works, and Smart picks show the metadata-only list.
- **Deterministic tests.** Unit tests use the fake client. One optional smoke test per feature runs against the real model and is skipped with `.enabled(if: LanguageModelClient.real.isAvailable)`.
- Plan 2–6 constraints hold: brand-neutral Swift, Swift 6 strict, zero warnings, lint clean, macOS 26 APIs only (check availability).

## Review Focus

1. Apple Intelligence off, or turned off while the app runs: every AI control disappears and nothing errors.
2. Nonsense, hostile or very long input in the search field: no crash, no queue action, and the plain search still works.
3. The model returns a filter value the app doesn't have (e.g. "8K"): it is dropped with a note, never crashes.
4. A large library (1,600+ Photos videos): Smart picks summarise aggregated buckets, never one prompt line per video.
5. Non-English system language: the feature hides if the model doesn't support it, or works in that language.

---

### Task 1: `Assistant` target, availability, "Ask in plain words"
- The `LanguageModelClient` protocol, the real and fake clients, and `AssistantAvailability`.
- `@Generable struct LibraryQuery` uses `@Guide` descriptions so it maps exactly onto the existing filters:
  - media-type badges
  - quality buckets (resolution and fps)
  - size and duration ranges
  - codec and dynamic range
  - date range: an absolute range, resolved from relative phrases ("last summer") using today's date passed in the instructions
  - "not yet shrunk" (no Completed job for the item)
  - free text for name search
- `QueryTranslator.translate(_ text: String, today: Date) async -> TranslatedQuery`: filters plus dropped parts, plus a short plain-language echo.
- UI on Local files and Videos: when available, the search field gets a sparkle button, or Return on a sentence. It shows the resulting filters as removable chips plus the echo line ("Showing 4K videos over 500 MB from Jun–Aug 2026"). Plain substring search stays the default for short queries.
- Tests (fake client): mapping of each filter kind, unknown values dropped with a note, relative dates resolved, the hidden-when-unavailable view state, timeouts.

### Task 2: "Explain this result"
- `OutcomeExplainer.explain(job:outcome:report:) async -> String`, with 2–4 plain sentences from the job's own report:
  - reason, notes and warnings
  - predicted versus actual losses
  - sizes and preset
- A "Why?" button on Kept as is, Completed with warnings and Failed rows (and in their popovers) when available; the answer appears in a popover. Cached per job id.
- Tests: the prompt contains only allowed fields, the cache works, and a fallback on error shows the existing reason text.

### Task 3: "Smart picks" on Overview (after Plan 3 Task 7's Overview dashboard)
- `SavingsAnalyzer` aggregates the library in plain Swift into buckets: quality × year × source (Local / Photos), plus "not yet shrunk" and the estimated savings per bucket. The model receives only the top buckets, so the context stays small.
- `@Generable struct SmartPicks` holds up to 3 picks, each with a title, a one-sentence why and a bucket id. Each pick has "Add these to the queue" (with the existing loss sheet) and "Show" (applies the bucket's filters).
- Without the model, Overview shows the top buckets as a plain list, with no AI text.
- Tests: aggregation correctness, only bucket ids from the input are accepted, the fallback path.

### Task 4: Siri and Spotlight actions (with Plan 4 Task 5)
- Extend `ShrinkVideosIntent` with optional parameters: date range, quality bucket, source (Local files or Photos), preset. It also gets an `AppShortcutsProvider` with natural phrases, e.g. "Shrink my videos from last month with ${applicationName}" and "Shrink 4K videos with ${applicationName}".
- The intent resolves the matching items with the same filter code as Task 1 and runs them through QuickRun: never Replace, skip on loss, one notification.
- Spotlight: the intent and its parameters are exposed so it shows up as a Spotlight action on macOS 26 (check the current App Intents API for Spotlight and Siri on macOS 26/27).
- These system entry points don't need the language model; they're always available. Only the natural-language phrase matching depends on Siri/Apple Intelligence, which the system handles.
- Tests: parameter mapping to filters and QuickRunOverrides, empty-match handling.

### Task 5: Polish
- VoiceOver labels and keyboard access for the sparkle button, chips and "Why?" popovers.
- README "Apple Intelligence" section: what runs on-device, what is sent to the model (metadata only), and how to turn it off.
- Manual check with Apple Intelligence on and off.
