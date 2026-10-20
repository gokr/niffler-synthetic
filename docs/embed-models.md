# Embed models on providers + `llm.embed`

Status: design settled, **not implemented** — `components/provider` and
`components/llm` live in the nifflerprod workspace, which this conversation
cannot write to (`E_WRITE_OUTSIDE`). This document is the work item; it should
be executed in a conversation whose workspace is `/home/gokr/git/nifflerprod`
so the changes can be built and tested.

## Decisions

1. **The provider owns the embed model.** `embedModel` is a second, optional
   model field on a provider record. One `model` field cannot express "chat on
   A, embeddings on B", which is the normal case (Synthetic: `syn:small:text`
   + `hf:nomic-ai/nomic-embed-text-v1.5`; any gateway).
2. **`llm` calls the endpoint directly.** No plugin is involved in the common
   path. `llm.embed` resolves provider → base URL → key → `embedModel` and
   posts to `{base}/embeddings`, exactly as `chat` posts to
   `{base}/chat/completions`.
3. **`x-embed-source` is metadata, not implementation.** A plugin declares
   which embed models a provider serves, their dimensions and context window.
   Consumers use it to *discover and choose*; nothing dispatches a call
   through it. This keeps the trust edge out of `llm` while still letting a
   plugin complete information the provider endpoint does not publish.
4. **Plugin removal is ordered after this lands.** `synthetic_embed` stays in
   niffler-synthetic until `llm.embed` exists, so the harness is never without
   an embedding path. Its `similarity`/`summary` shaping then moves to whatever
   consumer wants it; the raw-vector call belongs to `llm`.

## Part 1 — `components/provider/main.go`

All changes are additive; no existing field changes meaning.

### 1.1 `Provider` struct (near line 59)

```go
	// EmbedModel is the embedding model this provider serves (optional). It is
	// deliberately separate from Model: a backend commonly serves chat on one
	// model and embeddings on another, and the embedding endpoint takes no chat
	// roles. Empty means "this provider offers no embeddings", which the llm
	// component reports instead of guessing a model the endpoint would 400.
	EmbedModel string `json:"embedModel,omitempty"`
	// EmbedBaseURL overrides BaseURL for embeddings only, for a backend that
	// serves them elsewhere. Empty means "same base URL as chat".
	EmbedBaseURL string `json:"embedBaseUrl,omitempty"`
```

### 1.2 `providerSummary` + `summarizeProvider`

Add `EmbedModel` and `EmbedBaseURL` to both, mirroring `Model`. Without this,
interactive clients cannot show or edit the embed model without an admin
round-trip (same rationale as the existing `StripPrefix` note).

### 1.3 `provider_add` — schema, args struct, constructor

Schema (after `"model"`):

```go
"embedModel":   map[string]any{"type": "string", "description": "Embedding model this provider serves (optional; separate from the chat model)"},
"embedBaseUrl": map[string]any{"type": "string", "description": "Base URL for embeddings when it differs from the chat base URL (optional)"},
```

Args struct: `EmbedModel string \`json:"embedModel"\``, same for base URL.
Constructor `Provider{...}`: carry both through, then `.withDefaults()`.

### 1.4 `provider_update` — schema, args struct, assignment

Same two fields as `*string`, applied in the existing block:

```go
if args.EmbedModel != nil {
    p.EmbedModel = strings.TrimSpace(*args.EmbedModel)
}
if args.EmbedBaseURL != nil {
    p.EmbedBaseURL = strings.TrimSpace(*args.EmbedBaseURL)
}
```

Empty string is the way to clear an embed model; do not treat it as "unset".

### 1.5 No changes needed

`provider_get` returns the whole `Provider`, `provider_list` goes through
`providerSummary`, and `provider_export`/`provider_import` marshal the full
struct — so `embedModel` propagates automatically once it exists on the type.
`validStoredProvider` is unaffected (an embed model is not a credential).

## Part 2 — `components/llm/main.go`

### 2.1 plumbing

- `provider` struct (line ~62): add `EmbedModel`, `EmbedBaseURL`.
- `registryResponse.Provider` (line ~482): add both JSON fields.
- `requestStoredProvider` return (line ~537): copy both.

This is the only path by which a stored provider reaches the adapter, so all
three are required; missing one silently drops the field.

### 2.2 new `llm.embed` tool

Register beside `chat`, with the same concurrency reasoning as the comment at
line 1523 (an embedding call must never queue behind a streaming chat):

```go
comp.ToolConcurrent("embed", map[string]any{
    "type":        "object",
    "description": "Embed text through the active provider's embedding model.",
    "properties": map[string]any{
        "input":  map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
        "model":  map[string]any{"type": "string", "description": "Override the provider's embedModel"},
        "provider": map[string]any{"type": "string"},
        "dimensions": map[string]any{"type": "integer"},
    },
    "required":  []string{"input"},
    "x-harness": map[string]any{"hidden": true, "runner": true, "timeoutMs": 120000},
}, embedHandler)
```

Handler shape:

1. Resolve the provider with the existing `resolveRuntimeConfig`-adjacent path
   (`resolveProvider` is enough — no context window or vision traits apply).
2. `model := args.Model`; else `p.EmbedModel`; else fail with
   `provider "<name>" has no embedding model — set it with provider_add {embedModel: "..."}`
   (name the fix, never guess an id).
3. Base URL: `p.EmbedBaseURL` if set, else `p.BaseURL`.
4. Call via go-openai (already a dependency, v1.43):
   `client.CreateEmbeddings(ctx, openai.EmbeddingRequest{Model:, Input: []string, Dimensions:})`
   with `cfg.BaseURL` set to the resolved base. OpenAI-compatible only — see
   Limits.
5. Return `{ok, provider, model, dimensions, embeddings: [[float...]...], usage}`.

Timeout from the tool policy; no streaming, no cancellation subscription
(embeddings are short — if that proves false, mirror `chat`'s `llm.cancel.<id>`
pattern with the caller's `cancelId`).

### 2.3 surface the capability

Add `"embedModel": resolved.Provider.EmbedModel` to the `llm_resolve` response
(line ~1485), so a caller can check the capability without making a call. Same
argument as `hasKey` there: resolution is the place to learn what is
configured.

## Part 3 — `x-embed-source` (metadata)

Declared on a tool schema, discovered the way `x-models-source` is
(`components/models/catalog.go:420` + the `reg.publish` tap at
`components/models/main.go:73`):

```json
"x-embed-source": {
  "version": 1,
  "priority": 100,
  "provider": "synthetic",
  "models": [
    {"id": "hf:nomic-ai/nomic-embed-text-v1.5", "dimensions": 768,
     "context": 8192, "pricing": "included"}
  ]
}
```

Consumer: the `models` catalog, so embed models appear in `models_list` /
`models_get` and a future provider form can suggest an `embedModel` value.
A `reg.depart` drops the entries with the component, exactly as model sources
do.

Rationale for stopping here: `llm` must not dispatch an inference call through
an arbitrary plugin mid-request. Metadata is a read; delegation is a trust edge
with a timeout budget, and it buys nothing until a provider exists whose
embeddings are neither OpenAI-compatible nor reachable as a plain HTTP POST.

## Limits (state these in the docs, do not paper over)

- **OpenAI-compatible only.** Ollama works through its OpenAI shim
  (`baseUrl: http://localhost:11434/v1`) — its native `/api/embed` is a
  different request/response shape and is deliberately out of scope. If it is
  wanted later, it belongs behind a `protocol: "ollama"` on the provider, next
  to the existing `openai-chat`/`anthropic`/`openai-codex` enum.
- **Vectors need an owner.** `llm.embed` returning raw floats is only useful to
  a caller ranking a candidate set it already holds, or persisting them itself.
  Semantic `context_recall` additionally needs a store kind for vectors, a
  chunker and an incremental update path. That is a separate work item; this
  one only removes the "no embedding service" blocker. See "Vector search in
  SQLite" below for what the store can actually do.
- **models.dev cannot discover embed models.** Its `modalities.output` is
  `["text"]` even for `text-embedding-3-large`, so the catalog is not a source
  of truth here. Explicit `embedModel` plus optional `x-embed-source` is.

## Tests

- `components/provider/models_test.go`: round-trip `embedModel` through
  `provider_add` → `provider_get` → `provider_export`; clearing it with `""`.
- `components/llm/main_test.go`: follow the `httptest` pattern at line ~576 —
  a stub `/embeddings` endpoint asserting the model and input, one case for
  "no embedModel configured" (error names `provider_add`), one for
  `EmbedBaseURL` overriding the chat base.
- `niffler-synthetic`: once Part 2 is live, delete `synthetic_embed` and its
  selftest check, and declare `x-embed-source` on a remaining tool so the
  catalog still learns the model id.

## Suggested order

1. provider fields + `provider_add`/`provider_update` (+ tests) — inert, no
   behavior change until something reads them.
2. llm plumbing + `llm_resolve.embedModel` (+ test).
3. `llm.embed` (+ tests).
4. `x-embed-source` in the catalog.
5. Remove `synthetic_embed`, add the declaration.

## Vector search in SQLite — measured, not assumed

`sqlite-vec` works in this harness today, with one driver change confined to
`store-sqlite`. Everything below was compiled and run on this machine, not
inferred.

### The driver decision

`store-sqlite` uses `modernc.org/sqlite`, chosen for *"pure Go, no cgo, no
build prerequisites"* (`Makefile:171`, `MANUAL.md:431`). That driver has **no
extension-loading support at all**, so sqlite-vec cannot work with it. The
cgo route was verified end to end:

```
matTn/go-sqlite3 v1.14.24 + asg017/sqlite-vec-go-bindings/cgo v0.1.7-alpha.2
  sqlite-vec version: v0.1.7-alpha.2
  kNN: cat    distance=0.0006
  kNN: dog    distance=0.0015
```

**Prerequisite cost is one C compiler.** mattn vendors the SQLite
amalgamation, so `libsqlite3-dev` is *not* needed — only `gcc`/`cc`, which a
harness running Nim already has. No release headers, no `.so` to ship: the
bindings vendor `sqlite-vec.c` and compile it in, so nothing is loaded at
runtime and the build needs no network beyond the module fetch.

### Two landmines, both verified

1. **FTS5 is off by default in mattn.** Without `-tags sqlite_fts5`,
   `CREATE VIRTUAL TABLE … USING fts5` fails with `no such module: fts5`.
   The store's `docs_fts` search index (migration `00002_search_index.sql`)
   would break. The Makefile build line must become:

   ```make
   $(BUILD_WRAP) bash -c 'cd components/store-sqlite && CGO_ENABLED=1 \
     go build -tags sqlite_fts5 -o ../../var/bin/store-sqlite .'
   ```

2. **The existing DSN works unchanged.** `_txlock=immediate`,
   `_journal_mode=WAL`, `_busy_timeout=10000` and
   `_pragma=synchronous(NORMAL)` are all mattn-compatible — verified on a
   real file, including the `_pragma` form.

### Measured cost

| | modernc (today) | mattn + sqlite-vec |
|---|---|---|
| Prerequisite | none | `gcc` (already required for Nim) |
| Cold build | fast | **66 s** (mattn amalgamation + sqlite-vec C) |
| Warm rebuild | fast | **0.1 s** (Go build cache) |
| Cross-compile | trivial | needs a C toolchain per target (no `GOOS/GOARCH` in the build today) |

Cold-build cost is paid once per `make clean`; the warm path is noise. Nothing
in the repo currently cross-compiles, so the portability objection is
theoretical — but it would block producing a macOS/Windows binary from a Linux
box later.

### Scope

Only `store-sqlite` changes. `store-tidb` is a separate engine and is
unaffected. The document contract (`put/get/list/search/del`), the goose
migrations and `var/store.db` all stay as they are — mattn can open the
existing file.

### Residual risk, and how to contain it

`sqlite-vec` is `v0.1.7-alpha.2` — pre-stable. Contain it:

- **Pin the exact version.** No floating range.
- **Degrade, don't stop.** If `vec_version()` fails at startup, log it and
  fall back to a plain `BLOB` column with cosine computed in Go. That path
  needs no extension and works on either driver, so the store never loses
  the capability — only its index. This mirrors the compaction ladder's
  "the ladder degrades, it does not stop".
- The fallback also lets Phase 0 ship before the swap: a `BLOB` column plus
  a Go scan is sufficient for thousands of chunks, under `modernc`, today.

### Alternatives considered

| Option | Verdict |
|---|---|
| `ncruces/go-sqlite3` (pure Go, WASM) | Driver works (SQLite 3.51.3, `CGO_ENABLED=0`), but the sqlite-vec WASM bindings are **broken** on every version tested (v0.1.4→v0.1.7-alpha.2): `signature mismatch: … go_busy_timeout`, or `"go_final" is not exported` when the driver is overridden. Revisit when upstream fixes the ABI. |
| DuckDB | Native vector support, but analytics-shaped: no document-KV contract, different concurrency story, and also cgo. Rewriting the store contract to gain an index is the wrong trade. |
| A separate vector service (Qdrant/Chroma) | Violates the no-external-prerequisites property for a single-harness deployment. |
| Plain `BLOB` + Go cosine | No dependency change. Fine to a few thousand chunks; no ANN index. Good Phase 0, weak at scale. |

### Recommendation

Swap `store-sqlite` to mattn with `-tags sqlite_fts5`, and use sqlite-vec
pinned at `v0.1.7-alpha.2` with the `vec_version()` fallback above. It is
one component, one C compiler the repo already needs, a one-time 66 s build,
and it unlocks the extension ecosystem beyond vectors (other loadable or
buildable extensions become available too). The alpha status is manageable
because the fallback path is cheap and the data is a plain SQLite file.

Order of work is still the one at the top of this document: embeddings first
(`embedModel` + `llm.embed`), because vectors are worthless without a producer,
and the store change is only useful once something is writing vectors.
