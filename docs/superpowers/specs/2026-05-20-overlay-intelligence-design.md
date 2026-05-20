# Overlay Intelligence Full Product Pass

Date: 2026-05-20
Status: approved design, pending implementation plan

## Goal

Build the full intelligence layer for Overlay-Opus while keeping the product local-first and capture-invisible. The app should help during live discussions by converting transcript, brief, and documents into compact reasoning support: question analysis, source-grounded answers, conversation memory, pre-call prep, and post-call review.

This work must not weaken `OverlayWindow.sharingType = .none`, must not add cloud STT, and must keep SQLite/GRDB as the local data store.

## Scope

Implement these product areas:

- Question intelligence: detect multi-part questions, hidden assumptions, traps, contradictions, and confidence.
- High-IQ answer mode: concise frameworks, first-principles reasoning, steelman/counterpoint, caveats.
- Source-grounded replies: cite brief/docs/transcript snippets and avoid unsupported claims.
- Conversation memory: track names, key claims, decisions, open loops, objections.
- Cognitive load UI: small "next best thought" cards instead of long paragraphs.
- Latency budget: local analysis appears immediately; streamed suggestions target a useful first token within 1-2 seconds when provider latency permits.
- Confidence labels: strong, uncertain, ask clarifier, needs source.
- Tone controls: Socratic, direct, diplomatic, technical, executive.
- Consent/privacy mode: visible local-only indicator, audit log, session export, session delete.
- Pre-call prep: likely questions and answer bullets from agenda/docs.
- Post-call review: missed questions, better answers, follow-ups, and searchable history.

## Non-Goals

- No stealth or evasion feature beyond the existing capture exclusion window behavior.
- No cloud speech-to-text.
- No remote database.
- No diarization or speaker identity model in this pass.
- No exact hard guarantee of 1-2 second final answer latency; only first useful streamed content is targeted.

## Architecture

Add four local intelligence services:

- `QuestionAnalyzer`: consumes recent transcript chunks and emits structured question analysis.
- `ConversationMemory`: keeps rolling session memory for names, claims, decisions, objections, and open loops.
- `GroundingEngine`: retrieves relevant snippets from brief, documents, and transcript using local SQLite FTS and lightweight keyword scoring.
- `PrepReviewEngine`: generates pre-call prep artifacts before/during setup and post-call review artifacts after a session ends.

`SuggestionEngine` remains the provider-facing streaming component. It will receive structured analysis, memory, grounding snippets, answer mode, tone, and privacy settings from the session store, then build compact prompts through `PromptBuilder`.

## Data Model

Add migrations for:

- `analysis_event`: structured question analyses and confidence data.
- `memory_item`: local conversation memory entries.
- `privacy_audit`: local privacy/action audit events.
- `session_artifact`: pre-call prep, post-call review, exports, and other generated session artifacts.

Each table stores a minimal set of indexed fields plus JSON for flexible structured payloads. This avoids repeated schema churn while keeping history searchable and exportable.

Existing `suggestion` rows will continue storing the streamed answer text. Structured metadata for confidence, citations, and card layout can be stored in `analysis_event` or `session_artifact` depending on whether it is live or review/prep oriented.

## Question Intelligence

`QuestionAnalyzer` should combine deterministic local heuristics with optional LLM refinement:

- Deterministic path: fast regex/token heuristics classify question starts, conjunction-heavy multi-part prompts, assumption phrases, contradiction phrases, and adversarial/trap phrasing.
- LLM path: `SuggestionEngine` includes the local analysis in prompts so the provider can refine answer strategy without blocking live UI.

Detected output:

- `parts`: individual subquestions.
- `assumptions`: implied premises.
- `traps`: loaded framing, false dichotomy, contradiction, impossible standard, or ambiguity.
- `contradictions`: transcript-local claim conflicts.
- `confidence`: strong, uncertain, ask clarifier, needs source.
- `recommendedMove`: answer directly, clarify, challenge premise, cite source, or defer.

## Grounding

`GroundingEngine` searches local context only:

- Brief text.
- Context documents via `doc_fts`.
- Transcript via `transcript_fts`.
- Recent memory items.

It returns short `GroundingSnippet` values with source type, title, excerpt, and optional row ID. Prompts must instruct the LLM to cite only these snippets and label unsupported claims as uncertain.

## Answer Modes And Tone

Add persisted settings:

- `overlay.answerMode`: concise, firstPrinciples, framework, steelman, caveats.
- `overlay.answerTone`: direct, socratic, diplomatic, technical, executive.
- `overlay.privacyMode`: localOnly or providerAssisted.

Prompt shape:

- First show a one-line next thought.
- Then 2-4 answer bullets.
- Then caveat or clarifier only if useful.
- Then citations when available.
- Include confidence label.

## UI

Suggestions tab:

- Replace long freeform card emphasis with compact cards.
- Card sections: next thought, answer bullets, caveat, citations, confidence badge.
- Keep streaming text visible while structured parse is incomplete.

Live tab:

- Show visible privacy/local-only indicator.
- Show recent memory chips: names, open loops, objections.
- Keep transcript readable and unchanged.

Brief tab:

- Add pre-call prep action after brief/docs are present.
- Show likely questions and answer bullets as prep cards.

History tab:

- Add session export.
- Add session delete with confirmation.
- Add post-call review cards: missed questions, better answers, follow-ups.

Settings tab:

- Add answer mode, tone, and privacy mode controls.
- Keep provider settings unchanged.

## Privacy And Audit

Privacy mode controls whether provider-assisted suggestions are allowed:

- `localOnly`: local STT, local heuristics, local memory, local search. No LLM provider calls.
- `providerAssisted`: current provider calls allowed for suggestions/prep/review.

Audit events are written locally for:

- Session start/stop.
- Recording start/stop.
- Provider request started/completed/failed.
- Export.
- Delete.
- Privacy mode change.

No secrets are stored in audit rows.

## Export And Delete

Export should produce a local JSON file containing session metadata, brief, context doc summaries, transcript, suggestions, memory items, prep/review artifacts, and audit events.

Delete should remove the session and cascade context docs, transcript chunks, suggestions, analyses, memory, artifacts, and audit rows. The UI must require confirmation because this is destructive.

## Latency Strategy

Live path:

1. Transcript chunk arrives from WhisperKit.
2. `QuestionAnalyzer` and `ConversationMemory` update locally.
3. UI receives immediate cards/memory changes.
4. `SuggestionEngine` starts provider stream with compact grounded prompt when privacy mode permits.

Heavy path:

- Pre-call prep and post-call review run as explicit user actions.
- Grounding uses capped snippets.
- Prompt token budget stays small by default.

## Error Handling

- Local analysis failures should not stop recording.
- Grounding failures should produce an empty snippet list and lower confidence to `needs source`.
- Provider failures should keep local question/memory cards visible and show a compact error in the suggestion card.
- Export failures should report the path/error.
- Delete failures should leave session intact and report error.

## Testing

Verification should include:

- Unit coverage for question splitting, assumptions, trap detection, confidence labels, and memory extraction.
- Database migration/build verification.
- Manual smoke for start call, transcript ingestion, suggestion card rendering, prep, review, export, and delete.
- Confirm `OverlayWindow.sharingType = .none` remains present.

## Implementation Order

1. Add models, migrations, DB accessors, and settings enums.
2. Add local `QuestionAnalyzer`, `ConversationMemory`, and `GroundingEngine`.
3. Extend prompt builder and suggestion update metadata.
4. Add compact Suggestions UI and Settings controls.
5. Add privacy audit, export, and delete.
6. Add pre-call prep and post-call review flows.
7. Verify build and core smoke paths.
