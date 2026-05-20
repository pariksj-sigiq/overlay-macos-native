# Overlay Intelligence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build first-class OpenAI + LM Studio provider support and the full Overlay intelligence pass: question analysis, grounded suggestions, memory, compact cards, privacy/audit, prep, review, export, and delete.

**Architecture:** Keep SQLite/GRDB as the source of truth and add focused local services under `Overlay/Intelligence/`. Live path is local-first: transcript chunks update question analysis, memory, grounding snippets, and compact UI immediately; provider calls are optional and controlled by privacy mode. LM Studio is implemented as an OpenAI-compatible local provider with a default `http://localhost:1234/v1` base URL and dummy non-empty API key.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, Combine, GRDB/SQLite FTS5, WhisperKit, existing provider streaming/SSE layer.

---

## File Structure

- Create `Overlay/Intelligence/IntelligenceModels.swift`: enums and Codable structs for confidence, answer mode, tone, privacy mode, question analysis, memory items, grounding snippets, and structured suggestion cards.
- Create `Overlay/Intelligence/QuestionAnalyzer.swift`: local deterministic question splitting, assumption/trap/contradiction detection, confidence labeling.
- Create `Overlay/Intelligence/ConversationMemory.swift`: rolling extraction of names, claims, decisions, objections, and open loops from transcript chunks.
- Create `Overlay/Intelligence/GroundingEngine.swift`: local brief/doc/transcript/memory retrieval and snippet scoring.
- Create `Overlay/Intelligence/PrepReviewEngine.swift`: provider-assisted prep/review artifact generation with local fallback.
- Create `Overlay/Session/SessionExportService.swift`: JSON export and destructive session delete orchestration.
- Create `Overlay/Providers/LMStudioProvider.swift`: OpenAI-compatible local provider preset.
- Modify `Overlay/Database/Models.swift`: add persisted models for `analysis_event`, `memory_item`, `privacy_audit`, `session_artifact`.
- Modify `Overlay/Database/Migrations.swift`: add migration `addIntelligenceSchema`.
- Modify `Overlay/Database/AppDatabase.swift`: add typed accessors for intelligence data, export fetches, session delete, grounding search.
- Modify `Overlay/Providers/ProviderRegistry.swift`: load `.lmStudio`.
- Modify `Overlay/UI/ProviderEditorView.swift`: expose OpenAI and LM Studio clearly.
- Modify `Overlay/Intelligence/PromptBuilder.swift`: build structured grounded prompts with answer mode/tone/privacy context.
- Modify `Overlay/Intelligence/SuggestionEngine.swift`: accept analysis/grounding/memory/settings and emit structured card metadata.
- Modify `Overlay/Session/CallSessionStore.swift`: wire local intelligence pipeline, privacy audit, prep/review actions, export/delete.
- Modify `Overlay/UI/SuggestionsTab.swift`: compact next-thought cards with confidence/citations.
- Modify `Overlay/UI/LiveTab.swift`: privacy indicator + memory chips.
- Modify `Overlay/UI/BriefTab.swift`: pre-call prep action/cards.
- Modify `Overlay/UI/HistoryTab.swift`: post-call review, export, delete.
- Modify `Overlay/UI/SettingsTab.swift`: answer mode, tone, privacy controls.
- Modify `OverlayOpus.xcodeproj/project.pbxproj`: add new Swift files to target.

## Task 1: Provider Support For OpenAI And LM Studio

**Files:**
- Modify: `Overlay/Database/Models.swift`
- Create: `Overlay/Providers/LMStudioProvider.swift`
- Modify: `Overlay/Providers/ProviderRegistry.swift`
- Modify: `Overlay/UI/ProviderEditorView.swift`
- Modify: `OverlayOpus.xcodeproj/project.pbxproj`

- [ ] **Step 1: Extend provider enum**

Add `lmStudio` to `ProviderKind`:

```swift
enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case azureOpenAI
    case bedrock
    case lmStudio
    case openAI

    var id: String { rawValue }

    var label: String {
        switch self {
        case .azureOpenAI: return "Azure OpenAI"
        case .bedrock: return "AWS Bedrock"
        case .lmStudio: return "LM Studio"
        case .openAI: return "OpenAI"
        }
    }
}
```

- [ ] **Step 2: Add LM Studio provider wrapper**

Create `Overlay/Providers/LMStudioProvider.swift`:

```swift
import Foundation

struct LMStudioProviderConfig: Codable, Equatable {
    var baseURL: URL
    var apiKey: String

    init(baseURL: URL = URL(string: "http://localhost:1234/v1")!,
         apiKey: String = "lm-studio") {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

final class LMStudioProvider: LLMProvider {
    let id: String
    let displayName: String

    private let provider: OpenAIProvider

    init(id: String,
         displayName: String,
         config: LMStudioProviderConfig) {
        self.id = id
        self.displayName = displayName
        provider = OpenAIProvider(id: id,
                                  displayName: displayName,
                                  config: OpenAIProviderConfig(baseURL: config.baseURL,
                                                               apiKeySecretName: "lmstudio.inline"),
                                  apiKey: config.apiKey.isEmpty ? "lm-studio" : config.apiKey)
    }

    func stream(_ req: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        provider.stream(req)
    }

    func listModels() async throws -> [String] {
        try await provider.listModels()
    }
}
```

- [ ] **Step 3: Load LM Studio configs**

In `ProviderRegistry.makeProvider(from:)`, add:

```swift
case .lmStudio:
    let config = try decode(LMStudioProviderConfig.self, from: record.configJSON)
    return LMStudioProvider(id: record.id, displayName: record.name, config: config)
```

- [ ] **Step 4: Update provider editor defaults**

In `ProviderEditorView`, change defaults:

```swift
@State private var kind: ProviderKind = .lmStudio
@State private var name = "Local LM Studio"
@State private var endpoint = "http://localhost:1234/v1"
```

In `onChange(of: kind)`, set known defaults:

```swift
switch value {
case .lmStudio:
    name = "Local LM Studio"
    endpoint = "http://localhost:1234/v1"
case .ollama:
    name = "Local Ollama"
    endpoint = "http://localhost:11434"
case .openAI:
    name = "OpenAI"
    endpoint = "https://api.openai.com/v1"
case .azureOpenAI:
    name = "Azure OpenAI"
case .bedrock:
    name = "AWS Bedrock"
}
```

Add UI case:

```swift
case .lmStudio:
    TextField("Base URL", text: $endpoint)
        .textFieldStyle(.roundedBorder)
    Text("Default: http://localhost:1234/v1. Start LM Studio local server and load a model.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
```

Add config case:

```swift
case .lmStudio:
    let url = URL(string: endpoint).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(string: "http://localhost:1234/v1")!
    return try encoder.encode(LMStudioProviderConfig(baseURL: url, apiKey: "lm-studio"))
```

- [ ] **Step 5: Add file to Xcode target**

Add `LMStudioProvider.swift` to PBX file refs and sources next to other provider files.

- [ ] **Step 6: Verify build**

Run:

```bash
xcodebuild -project OverlayOpus.xcodeproj -scheme OverlayOpus -configuration Debug -derivedDataPath /tmp/overlay-opus-build build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Overlay/Database/Models.swift Overlay/Providers/LMStudioProvider.swift Overlay/Providers/ProviderRegistry.swift Overlay/UI/ProviderEditorView.swift OverlayOpus.xcodeproj/project.pbxproj
git commit -m "Add LM Studio provider support"
```

## Task 2: Intelligence Models And Database Schema

**Files:**
- Create: `Overlay/Intelligence/IntelligenceModels.swift`
- Modify: `Overlay/Database/Models.swift`
- Modify: `Overlay/Database/Migrations.swift`
- Modify: `Overlay/Database/AppDatabase.swift`
- Modify: `OverlayOpus.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create shared intelligence types**

Create `Overlay/Intelligence/IntelligenceModels.swift`:

```swift
import Foundation

enum ConfidenceLabel: String, Codable, CaseIterable, Identifiable {
    case strong
    case uncertain
    case askClarifier
    case needsSource
    var id: String { rawValue }
}

enum AnswerMode: String, Codable, CaseIterable, Identifiable {
    case concise
    case firstPrinciples
    case framework
    case steelman
    case caveats
    var id: String { rawValue }
}

enum AnswerTone: String, Codable, CaseIterable, Identifiable {
    case direct
    case socratic
    case diplomatic
    case technical
    case executive
    var id: String { rawValue }
}

enum PrivacyMode: String, Codable, CaseIterable, Identifiable {
    case localOnly
    case providerAssisted
    var id: String { rawValue }
}

enum RecommendedMove: String, Codable {
    case answerDirectly
    case clarify
    case challengePremise
    case citeSource
    case defer
}

struct QuestionAnalysis: Codable, Equatable {
    var question: String
    var parts: [String]
    var assumptions: [String]
    var traps: [String]
    var contradictions: [String]
    var confidence: ConfidenceLabel
    var recommendedMove: RecommendedMove
}

enum MemoryKind: String, Codable, CaseIterable {
    case name
    case claim
    case decision
    case objection
    case openLoop
}

struct MemoryItemPayload: Codable, Equatable {
    var kind: MemoryKind
    var text: String
    var sourceTranscriptID: String?
}

enum GroundingSourceKind: String, Codable {
    case brief
    case document
    case transcript
    case memory
}

struct GroundingSnippet: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var sourceKind: GroundingSourceKind
    var title: String
    var excerpt: String
    var rowID: String?
}

struct SuggestionCard: Codable, Equatable {
    var nextThought: String
    var answerBullets: [String]
    var caveat: String?
    var citations: [GroundingSnippet]
    var confidence: ConfidenceLabel
}
```

- [ ] **Step 2: Add persisted record models**

Append to `Overlay/Database/Models.swift`:

```swift
struct AnalysisEventRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "analysis_event"
    var id: String
    var sessionID: String
    var ts: Int64
    var kind: String
    var payloadJSON: Data
}

struct MemoryItemRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "memory_item"
    var id: String
    var sessionID: String
    var ts: Int64
    var kind: MemoryKind
    var text: String
    var sourceTranscriptID: String?
    var payloadJSON: Data?
}

struct PrivacyAuditRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "privacy_audit"
    var id: String
    var sessionID: String?
    var ts: Int64
    var action: String
    var detail: String
}

struct SessionArtifactRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "session_artifact"
    var id: String
    var sessionID: String
    var ts: Int64
    var kind: String
    var title: String
    var content: String
    var payloadJSON: Data?
}
```

- [ ] **Step 3: Add migration**

In `Migrations.makeMigrator()`, after `createCallAssistantSchema`, register:

```swift
migrator.registerMigration("addIntelligenceSchema") { db in
    try db.create(table: "analysis_event") { t in
        t.column("id", .text).primaryKey()
        t.column("session_id", .text).notNull().references("call_session", onDelete: .cascade)
        t.column("ts", .integer).notNull()
        t.column("kind", .text).notNull()
        t.column("payload_json", .blob).notNull()
    }

    try db.create(table: "memory_item") { t in
        t.column("id", .text).primaryKey()
        t.column("session_id", .text).notNull().references("call_session", onDelete: .cascade)
        t.column("ts", .integer).notNull()
        t.column("kind", .text).notNull()
        t.column("text", .text).notNull()
        t.column("source_transcript_id", .text)
        t.column("payload_json", .blob)
    }

    try db.create(table: "privacy_audit") { t in
        t.column("id", .text).primaryKey()
        t.column("session_id", .text).references("call_session", onDelete: .cascade)
        t.column("ts", .integer).notNull()
        t.column("action", .text).notNull()
        t.column("detail", .text).notNull()
    }

    try db.create(table: "session_artifact") { t in
        t.column("id", .text).primaryKey()
        t.column("session_id", .text).notNull().references("call_session", onDelete: .cascade)
        t.column("ts", .integer).notNull()
        t.column("kind", .text).notNull()
        t.column("title", .text).notNull()
        t.column("content", .text).notNull()
        t.column("payload_json", .blob)
    }

    try db.create(index: "idx_analysis_session_ts", on: "analysis_event", columns: ["session_id", "ts"])
    try db.create(index: "idx_memory_session_kind", on: "memory_item", columns: ["session_id", "kind"])
    try db.create(index: "idx_privacy_audit_session_ts", on: "privacy_audit", columns: ["session_id", "ts"])
    try db.create(index: "idx_artifact_session_kind", on: "session_artifact", columns: ["session_id", "kind"])
}
```

- [ ] **Step 4: Add database accessors**

Add to `AppDatabase`:

```swift
func insertAnalysisEvent(_ event: AnalysisEventRecord) async throws -> AnalysisEventRecord {
    try await write { db in try event.insert(db); return event }
}

func insertMemoryItem(_ item: MemoryItemRecord) async throws -> MemoryItemRecord {
    try await write { db in try item.insert(db); return item }
}

func memoryItems(sessionID: String) async throws -> [MemoryItemRecord] {
    try await read { db in
        try MemoryItemRecord
            .filter(Column("session_id") == sessionID)
            .order(Column("ts").desc)
            .fetchAll(db)
    }
}

func insertPrivacyAudit(_ audit: PrivacyAuditRecord) async throws -> PrivacyAuditRecord {
    try await write { db in try audit.insert(db); return audit }
}

func insertSessionArtifact(_ artifact: SessionArtifactRecord) async throws -> SessionArtifactRecord {
    try await write { db in try artifact.insert(db); return artifact }
}

func sessionArtifacts(sessionID: String, kind: String? = nil) async throws -> [SessionArtifactRecord] {
    try await read { db in
        var request = SessionArtifactRecord.filter(Column("session_id") == sessionID)
        if let kind { request = request.filter(Column("kind") == kind) }
        return try request.order(Column("ts").desc).fetchAll(db)
    }
}
```

- [ ] **Step 5: Verify build**

Run the same `xcodebuild` command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Overlay/Intelligence/IntelligenceModels.swift Overlay/Database/Models.swift Overlay/Database/Migrations.swift Overlay/Database/AppDatabase.swift OverlayOpus.xcodeproj/project.pbxproj
git commit -m "Add intelligence persistence schema"
```

## Task 3: Local Question Analyzer And Conversation Memory

**Files:**
- Create: `Overlay/Intelligence/QuestionAnalyzer.swift`
- Create: `Overlay/Intelligence/ConversationMemory.swift`
- Modify: `Overlay/Session/CallSessionStore.swift`
- Modify: `OverlayOpus.xcodeproj/project.pbxproj`

- [ ] **Step 1: Implement `QuestionAnalyzer`**

Create `QuestionAnalyzer` with this public shape:

```swift
import Foundation

struct QuestionAnalyzer {
    func analyze(question: String, context: [TranscriptChunkRecord]) -> QuestionAnalysis {
        let parts = splitParts(question)
        let assumptions = detectAssumptions(question)
        let traps = detectTraps(question)
        let contradictions = detectContradictions(question: question, context: context)
        let confidence = label(parts: parts, assumptions: assumptions, traps: traps, contradictions: contradictions)
        return QuestionAnalysis(question: question,
                                parts: parts,
                                assumptions: assumptions,
                                traps: traps,
                                contradictions: contradictions,
                                confidence: confidence,
                                recommendedMove: move(confidence: confidence, traps: traps, contradictions: contradictions))
    }
}
```

Implement private helpers with deterministic matching:

```swift
private func splitParts(_ text: String) -> [String] {
    text.components(separatedBy: CharacterSet(charactersIn: "?;"))
        .flatMap { $0.components(separatedBy: " and ") }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func detectAssumptions(_ text: String) -> [String] {
    let lower = text.lowercased()
    return ["assuming", "given that", "since you", "why did you", "isn't it true"].filter { lower.contains($0) }
}

private func detectTraps(_ text: String) -> [String] {
    let lower = text.lowercased()
    return ["always", "never", "obviously", "admit", "failed", "can't you just"].filter { lower.contains($0) }
}
```

- [ ] **Step 2: Implement `ConversationMemory`**

Create actor:

```swift
import Foundation

actor ConversationMemory {
    private var seen = Set<String>()

    func extract(from chunk: TranscriptChunkRecord) -> [MemoryItemPayload] {
        let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var items: [MemoryItemPayload] = []
        let lower = text.lowercased()

        if lower.contains("my name is ") || lower.contains("i'm ") {
            items.append(MemoryItemPayload(kind: .name, text: text, sourceTranscriptID: chunk.id))
        }
        if lower.contains("we decided") || lower.contains("decision") {
            items.append(MemoryItemPayload(kind: .decision, text: text, sourceTranscriptID: chunk.id))
        }
        if lower.contains("i disagree") || lower.contains("concern") || lower.contains("objection") {
            items.append(MemoryItemPayload(kind: .objection, text: text, sourceTranscriptID: chunk.id))
        }
        if lower.contains("follow up") || lower.contains("open question") || lower.contains("circle back") {
            items.append(MemoryItemPayload(kind: .openLoop, text: text, sourceTranscriptID: chunk.id))
        }
        if lower.contains("we believe") || lower.contains("the claim") || lower.contains("because") {
            items.append(MemoryItemPayload(kind: .claim, text: text, sourceTranscriptID: chunk.id))
        }

        return items.filter { seen.insert("\($0.kind.rawValue):\($0.text)").inserted }
    }
}
```

- [ ] **Step 3: Wire into `CallSessionStore`**

Add properties:

```swift
@Published private(set) var questionAnalyses: [QuestionAnalysis] = []
@Published private(set) var memoryItems: [MemoryItemRecord] = []
private let questionAnalyzer = QuestionAnalyzer()
private let conversationMemory = ConversationMemory()
```

In transcript sink, after appending transcript:

```swift
let analysis = self.questionAnalyzer.analyze(question: chunk.text, context: self.transcript)
if chunk.text.contains("?") || analysis.parts.count > 1 || !analysis.traps.isEmpty {
    self.questionAnalyses.append(analysis)
    if let data = try? JSONEncoder().encode(analysis) {
        Task {
            try? await AppDatabase.shared.insertAnalysisEvent(
                AnalysisEventRecord(id: UUID().uuidString,
                                    sessionID: chunk.sessionID,
                                    ts: Date.unixMilliseconds,
                                    kind: "question",
                                    payloadJSON: data)
            )
        }
    }
}

Task {
    let payloads = await self.conversationMemory.extract(from: chunk)
    for payload in payloads {
        let data = try? JSONEncoder().encode(payload)
        let record = MemoryItemRecord(id: UUID().uuidString,
                                      sessionID: chunk.sessionID,
                                      ts: Date.unixMilliseconds,
                                      kind: payload.kind,
                                      text: payload.text,
                                      sourceTranscriptID: payload.sourceTranscriptID,
                                      payloadJSON: data)
        try? await AppDatabase.shared.insertMemoryItem(record)
        await MainActor.run { self.memoryItems.insert(record, at: 0) }
    }
}
```

- [ ] **Step 4: Verify build and commit**

Run build. Commit:

```bash
git add Overlay/Intelligence/QuestionAnalyzer.swift Overlay/Intelligence/ConversationMemory.swift Overlay/Session/CallSessionStore.swift OverlayOpus.xcodeproj/project.pbxproj
git commit -m "Add local question analysis and memory"
```

## Task 4: Grounded Prompting And Structured Suggestion Cards

**Files:**
- Create: `Overlay/Intelligence/GroundingEngine.swift`
- Modify: `Overlay/Intelligence/PromptBuilder.swift`
- Modify: `Overlay/Intelligence/SuggestionEngine.swift`
- Modify: `Overlay/Database/Models.swift`
- Modify: `Overlay/Session/CallSessionStore.swift`
- Modify: `OverlayOpus.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add `GroundingEngine`**

Create:

```swift
import Foundation

struct GroundingEngine {
    func snippets(question: String,
                  brief: String,
                  contextDocs: [ContextDocRecord],
                  transcriptTail: [TranscriptChunkRecord],
                  memoryItems: [MemoryItemRecord]) -> [GroundingSnippet] {
        let terms = Set(question.lowercased().split(separator: " ").map(String.init).filter { $0.count > 3 })
        var snippets: [GroundingSnippet] = []

        if !brief.isEmpty {
            snippets.append(GroundingSnippet(sourceKind: .brief,
                                             title: "Brief",
                                             excerpt: String(brief.prefix(500)),
                                             rowID: nil))
        }

        snippets += contextDocs.prefix(5).map {
            GroundingSnippet(sourceKind: .document,
                             title: $0.title,
                             excerpt: bestExcerpt(in: $0.text, terms: terms),
                             rowID: $0.id)
        }

        snippets += transcriptTail.suffix(8).map {
            GroundingSnippet(sourceKind: .transcript,
                             title: "Transcript",
                             excerpt: $0.text,
                             rowID: $0.id)
        }

        snippets += memoryItems.prefix(8).map {
            GroundingSnippet(sourceKind: .memory,
                             title: $0.kind.rawValue,
                             excerpt: $0.text,
                             rowID: $0.id)
        }

        return Array(snippets.prefix(8))
    }

    private func bestExcerpt(in text: String, terms: Set<String>) -> String {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".?!\n"))
        let best = sentences.max { lhs, rhs in score(lhs, terms: terms) < score(rhs, terms: terms) }
        return String((best ?? text).trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    }

    private func score(_ text: String, terms: Set<String>) -> Int {
        let lower = text.lowercased()
        return terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
    }
}
```

- [ ] **Step 2: Extend `SuggestionUpdate`**

Add optional card:

```swift
var card: SuggestionCard?
```

Update all initializers/usages to pass `card: nil` until structured parsing is available.

- [ ] **Step 3: Extend prompt builder**

Replace `buildRequest` signature:

```swift
func buildRequest(brief: String,
                  question: String,
                  analysis: QuestionAnalysis?,
                  grounding: [GroundingSnippet],
                  memoryItems: [MemoryItemRecord],
                  answerMode: AnswerMode,
                  tone: AnswerTone,
                  contextDocs: [ContextDocRecord],
                  transcriptTail: [TranscriptChunkRecord],
                  modelID: String) -> LLMRequest
```

System prompt must include:

```swift
Return concise live-call help. Use this format:
NEXT: one sentence
ANSWER:
- bullet
- bullet
CAVEAT: one sentence or "none"
CONFIDENCE: strong|uncertain|askClarifier|needsSource
CITATIONS: cite only provided source labels, or "none"
Do not invent facts. If sources are weak, say what is missing.
```

- [ ] **Step 4: Parse structured card**

In `SuggestionEngine`, add:

```swift
private func parseCard(text: String, fallbackConfidence: ConfidenceLabel, citations: [GroundingSnippet]) -> SuggestionCard {
    let lines = text.components(separatedBy: .newlines)
    let next = lines.first(where: { $0.hasPrefix("NEXT:") })?.replacingOccurrences(of: "NEXT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let bullets = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "- \t")) }
        .filter { !$0.isEmpty }
    let caveat = lines.first(where: { $0.hasPrefix("CAVEAT:") })?
        .replacingOccurrences(of: "CAVEAT:", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return SuggestionCard(nextThought: next.isEmpty ? String(text.prefix(140)) : next,
                          answerBullets: bullets.isEmpty ? [String(text.prefix(240))] : bullets,
                          caveat: caveat == "none" ? nil : caveat,
                          citations: citations,
                          confidence: fallbackConfidence)
}
```

- [ ] **Step 5: Wire grounding into `CallSessionStore`**

Before calling `suggestionEngine.suggest`, compute snippets with `GroundingEngine`.

- [ ] **Step 6: Verify build and commit**

Run build. Commit:

```bash
git add Overlay/Intelligence/GroundingEngine.swift Overlay/Intelligence/PromptBuilder.swift Overlay/Intelligence/SuggestionEngine.swift Overlay/Database/Models.swift Overlay/Session/CallSessionStore.swift OverlayOpus.xcodeproj/project.pbxproj
git commit -m "Add grounded structured suggestions"
```

## Task 5: Settings, Privacy Mode, And Audit

**Files:**
- Modify: `Overlay/UI/SettingsTab.swift`
- Modify: `Overlay/Session/CallSessionStore.swift`
- Modify: `Overlay/UI/LiveTab.swift`

- [ ] **Step 1: Add AppStorage controls**

Use these keys:

```swift
@AppStorage("overlay.answerMode") private var answerModeRaw = AnswerMode.concise.rawValue
@AppStorage("overlay.answerTone") private var answerToneRaw = AnswerTone.direct.rawValue
@AppStorage("overlay.privacyMode") private var privacyModeRaw = PrivacyMode.providerAssisted.rawValue
```

Add pickers in Settings:

```swift
Picker("Answer mode", selection: $answerModeRaw) {
    ForEach(AnswerMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
}
Picker("Tone", selection: $answerToneRaw) {
    ForEach(AnswerTone.allCases) { Text($0.rawValue).tag($0.rawValue) }
}
Picker("Privacy", selection: $privacyModeRaw) {
    ForEach(PrivacyMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
}
```

- [ ] **Step 2: Block provider calls in local-only mode**

In `CallSessionStore`, read privacy mode before suggestion:

```swift
private var privacyMode: PrivacyMode {
    PrivacyMode(rawValue: UserDefaults.standard.string(forKey: "overlay.privacyMode") ?? "") ?? .providerAssisted
}
```

If `.localOnly`, publish local analysis card and do not call `SuggestionEngine`.

- [ ] **Step 3: Add audit helper**

```swift
private func audit(_ action: String, detail: String = "") {
    let record = PrivacyAuditRecord(id: UUID().uuidString,
                                    sessionID: activeSession?.id,
                                    ts: Date.unixMilliseconds,
                                    action: action,
                                    detail: detail)
    Task { try? await AppDatabase.shared.insertPrivacyAudit(record) }
}
```

Call on session start/stop, recording start/stop, provider request attempt, export, delete, privacy mode changes.

- [ ] **Step 4: Show privacy indicator in Live tab**

Add badge:

```swift
Text(privacyModeRaw == PrivacyMode.localOnly.rawValue ? "LOCAL ONLY" : "PROVIDER ASSISTED")
    .font(.system(size: 10, weight: .bold, design: .monospaced))
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(Capsule().fill(Color.green.opacity(0.15)))
```

- [ ] **Step 5: Verify build and commit**

Run build. Commit:

```bash
git add Overlay/UI/SettingsTab.swift Overlay/Session/CallSessionStore.swift Overlay/UI/LiveTab.swift
git commit -m "Add privacy mode and audit controls"
```

## Task 6: Compact Cognitive Load UI

**Files:**
- Modify: `Overlay/UI/SuggestionsTab.swift`
- Modify: `Overlay/UI/LiveTab.swift`

- [ ] **Step 1: Render suggestion card metadata**

In `SuggestionsTab.suggestionCard`, if `suggestion.card != nil`, render:

```swift
Text(card.nextThought)
    .font(.system(size: 13, weight: .semibold))
ForEach(card.answerBullets, id: \.self) { bullet in
    Label(bullet, systemImage: "chevron.right")
        .font(.system(size: 12))
}
if let caveat = card.caveat {
    Label(caveat, systemImage: "exclamationmark.triangle")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
}
Text(card.confidence.rawValue)
    .font(.system(size: 10, weight: .bold))
```

- [ ] **Step 2: Render citations**

```swift
ForEach(card.citations) { citation in
    Text("[\(citation.sourceKind.rawValue)] \(citation.title): \(citation.excerpt)")
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .lineLimit(2)
}
```

- [ ] **Step 3: Render memory chips in Live tab**

Add horizontal chip row from `sessionStore.memoryItems.prefix(6)`.

- [ ] **Step 4: Verify build and commit**

Run build. Commit:

```bash
git add Overlay/UI/SuggestionsTab.swift Overlay/UI/LiveTab.swift
git commit -m "Add compact intelligence cards"
```

## Task 7: Pre-Call Prep And Post-Call Review

**Files:**
- Create: `Overlay/Intelligence/PrepReviewEngine.swift`
- Modify: `Overlay/Session/CallSessionStore.swift`
- Modify: `Overlay/UI/BriefTab.swift`
- Modify: `Overlay/UI/HistoryTab.swift`
- Modify: `OverlayOpus.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create `PrepReviewEngine`**

Public methods:

```swift
actor PrepReviewEngine {
    func makePrep(sessionID: String,
                  brief: String,
                  docs: [ContextDocRecord],
                  providerID: String?,
                  modelID: String?,
                  privacyMode: PrivacyMode) async throws -> SessionArtifactRecord

    func makeReview(session: CallSessionRecord,
                    transcript: [TranscriptChunkRecord],
                    suggestions: [SuggestionRecord],
                    providerID: String?,
                    modelID: String?,
                    privacyMode: PrivacyMode) async throws -> SessionArtifactRecord
}
```

Local-only prep content:

```swift
Likely questions:
- What is the main decision needed?
- What evidence supports the recommendation?
- What risks or tradeoffs should be named?

Answer bullets:
- State the goal.
- Cite the strongest available source.
- Name uncertainty directly.
```

Provider-assisted path uses existing provider with compact prompt and stores result in `session_artifact`.

- [ ] **Step 2: Add store actions**

In `CallSessionStore`:

```swift
@Published private(set) var prepArtifacts: [SessionArtifactRecord] = []
@Published private(set) var reviewArtifacts: [SessionArtifactRecord] = []

func generatePrep()
func generateReview()
```

- [ ] **Step 3: Add Brief UI prep button**

Button:

```swift
Button("Generate Prep") { sessionStore.generatePrep() }
```

Render `prepArtifacts` as cards.

- [ ] **Step 4: Add History review button**

Button:

```swift
Button("Generate Review") { Task { await generateReviewForSelectedSession() } }
```

Render post-call review text.

- [ ] **Step 5: Verify build and commit**

Run build. Commit:

```bash
git add Overlay/Intelligence/PrepReviewEngine.swift Overlay/Session/CallSessionStore.swift Overlay/UI/BriefTab.swift Overlay/UI/HistoryTab.swift OverlayOpus.xcodeproj/project.pbxproj
git commit -m "Add prep and review artifacts"
```

## Task 8: Export And Delete Session

**Files:**
- Create: `Overlay/Session/SessionExportService.swift`
- Modify: `Overlay/Database/AppDatabase.swift`
- Modify: `Overlay/UI/HistoryTab.swift`
- Modify: `OverlayOpus.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add export snapshot fetch**

Add struct:

```swift
struct SessionExportSnapshot: Codable {
    var session: CallSessionRecord
    var contextDocs: [ContextDocRecord]
    var transcript: [TranscriptChunkRecord]
    var suggestions: [SuggestionRecord]
    var memory: [MemoryItemRecord]
    var artifacts: [SessionArtifactRecord]
    var audits: [PrivacyAuditRecord]
}
```

Add `AppDatabase.exportSnapshot(sessionID:)`.

- [ ] **Step 2: Add delete API**

```swift
func deleteSession(id: String) async throws {
    try await write { db in
        _ = try CallSessionRecord.deleteOne(db, key: id)
    }
}
```

Foreign keys cascade related rows.

- [ ] **Step 3: Add export service**

```swift
struct SessionExportService {
    func export(sessionID: String) async throws -> URL {
        let snapshot = try await AppDatabase.shared.exportSnapshot(sessionID: sessionID)
        let data = try JSONEncoder().encode(snapshot)
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("overlay-session-\(sessionID).json")
        try data.write(to: url, options: [.atomic])
        return url
    }
}
```

- [ ] **Step 4: Add History UI actions**

Add Export and Delete buttons. Delete uses SwiftUI confirmation dialog:

```swift
.confirmationDialog("Delete this session permanently?", isPresented: $confirmingDelete) {
    Button("Delete Session", role: .destructive) { Task { await deleteSelected() } }
}
```

- [ ] **Step 5: Verify build and commit**

Run build. Commit:

```bash
git add Overlay/Session/SessionExportService.swift Overlay/Database/AppDatabase.swift Overlay/UI/HistoryTab.swift OverlayOpus.xcodeproj/project.pbxproj
git commit -m "Add session export and delete"
```

## Task 9: Final Verification

**Files:**
- Read only unless fixes are needed.

- [ ] **Step 1: Confirm capture invisibility rule**

Run:

```bash
rg -n "sharingType = \\.none" Overlay/OverlayWindow.swift
```

Expected: line with `self.sharingType = .none`.

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild -project OverlayOpus.xcodeproj -scheme OverlayOpus -configuration Debug -derivedDataPath /tmp/overlay-opus-build build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Diff check**

Run:

```bash
git diff --check
```

Expected: no output.

- [ ] **Step 4: Manual smoke**

Run:

```bash
open /tmp/overlay-opus-build/Build/Products/Debug/OverlayOpus.app
```

Manual checks:

- Settings shows LM Studio, OpenAI, answer mode, tone, privacy.
- LM Studio provider saves with `http://localhost:1234/v1`.
- Brief can start a call.
- Live tab shows privacy badge and transcript.
- Suggestions tab shows compact cards.
- History can export and requires confirmation before delete.

- [ ] **Step 5: Commit final fixes**

If smoke fixes are needed:

```bash
git add Overlay OverlayOpus.xcodeproj
git commit -m "Polish overlay intelligence workflow"
```

## Self-Review

Spec coverage:

- OpenAI + LM Studio: Task 1.
- Question intelligence: Task 3.
- High-IQ answer modes/tone: Tasks 4 and 5.
- Source grounding: Task 4.
- Conversation memory: Task 3 and Task 6.
- Cognitive load cards: Task 6.
- Latency budget: Tasks 3 and 4 keep local analysis immediate and prompts compact.
- Confidence labels: Tasks 2, 3, 4, 6.
- Consent/privacy/audit/export/delete: Tasks 5 and 8.
- Pre-call prep/post-call review: Task 7.

Instruction completeness scan: each task lists exact paths, code shape, commands, and expected results.

Type consistency: shared enums live in `IntelligenceModels.swift`; DB records use those enums; store/UI/prompt tasks use the same names.
