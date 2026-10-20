# niffler-synthetic

First-class [Synthetic.new](https://dev.synthetic.new/docs/api/overview) support
for [Niffler](https://github.com/gokr/niffler) — an `niffler-component` plugin.

The `synthetic` component wraps everything Synthetic's API exposes, not just
the inference path: subscription usage tracking, the live model catalog,
zero-data-retention web search, one-shot chat, and token counting.

| Synthetic API | Base | Tools |
| --- | --- | --- |
| OpenAI-compatible inference | `https://api.synthetic.new/openai/v1` | `synthetic_chat`, `synthetic_models` |
| Anthropic-compatible | `https://api.synthetic.new/anthropic/v1` | `synthetic_count_tokens` |
| Synthetic extras | `https://api.synthetic.new/v2` | `synthetic_usage`, `synthetic_search` |

## Install

On a running harness:

```bash
./var/bin/cli install file:///path/to/niffler-synthetic   # local
./var/bin/cli install <user>/niffler-synthetic            # GitHub
```

or ask the agent to `plugin_search synthetic` and `install` it. Installs clone
into `var/plugins/`, build the Nim component via the builder, and spawn it on
the bus.

## Tools (all onDemand — reachable via discover/invoke)

| Tool | What it does |
| --- | --- |
| `synthetic_usage` | Subscription usage + rate limits: requests this cycle, weekly token credits (percent and $ remaining, next regen), rolling five-hour limit, hourly search quota, free tool calls. Persists a snapshot to the store (`kind: synthetic`) on every call. Also the **`/synthetic` slash command** in the web UI. |
| `synthetic_history` | Recent usage snapshots with deltas (requests, weekly %, 5h headroom) — usage is trackable over time because `synthetic_usage` records every poll. |
| `synthetic_models` | Live model catalog: `syn:`/`infinite:` aliases (with the concrete model each resolves to right now) and pinned `hf:` ids — context/output limits, $/Mtok, features, vision, reasoning efforts. Filters: `query`, `vision`, `tools`, `reasoning`, `minContext`. |
| `synthetic_search` | Web search (docs/synthetic/search) — ranked pages with title, url, publication date and an excerpt; zero data retention, draws on its own hourly quota. |
| `synthetic_chat` | An **auxiliary** one-shot completion — not a conversation path. Use it when choosing the model is the point: a cheap small model for a subtask instead of the session's model, a vision read, a JSON extraction, or reading back which concrete model a `syn:` alias resolves to so it can be pinned. Takes `prompt`/`systemPrompt` or a full `messages` array, vision `images` (URL or data URI), `jsonMode`, `reasoningEffort`, `tools`/`toolChoice`, sampling knobs, `stream`. Like the rest of this plugin it has **no retry, no cancellation and no session usage accounting** — core's hidden `chat` owns the conversation and provides those. |
| `synthetic_count_tokens` | Token count before paying for a request (`/anthropic/v1/messages/count_tokens`; subscriber-only, itself free). |
| `synthetic_models_source` | *Hidden* [models source plugin](https://github.com/gokr/niffler/blob/main/docs/MANUAL.md): a JSON Merge Patch (x-models-source v1) that refreshes the `models` component's `synthetic` provider block with live ids, limits and $/Mtok costs. |

Plus the standard hidden `selftest`, which `/doctor` fans out to: it checks
key resolution, the base URL, quotas and the catalog, and in `deep` mode one
search.

These tools do **not** replace the harness `llm` component — the runner's
hidden `chat` tool still owns the conversation, with the retries,
cancellation, context admission and usage accounting that go with it. The
`llm` path resolves provider and model from the session and is not reachable
from the model's own toolset at all, so `synthetic_chat` is not a duplicate of
it: it is the explicit-model escape hatch for a single auxiliary call.

## Slash commands

All namespaced with the package name, since the slash namespace is global.
`/synthetic` renders current usage; `raw` dumps the provider JSON, `history`
shows tracked snapshots with deltas instead of a live poll.

```
/synthetic
/synthetic history
/synthetic-models vision=true minContext=200000
/synthetic-search nim 2.2 release notes 3
/synthetic-chat syn:small:text "Summarize this changelog"
/synthetic-tokens "how long is this prompt"
```

## Configuration

| Variable | Meaning |
| --- | --- |
| `SYNTHETIC_API_KEY` | API key — harness environment or `NIF_ROOT/.env` (dotenv), falling back to opencode's key store (`~/.local/share/opencode/auth.json`, key `synthetic`). Never logged. |
| `SYNTHETIC_BASE_URL` | API origin; defaults to `https://api.synthetic.new`. Point it at a gateway or a test double. |

Get a key at <https://dev.synthetic.new>.

## Notes from the API

- Model ids must carry a prefix: `hf:owner/model` (pinned) or `syn:` /
  `infinite:` (alias). A bare name is a 400. `infinite:` aliases require
  `stream: true` and a Big plan.
- `/models` lists always-on models plus on-demand models recently used; a
  pinned `hf:` id can 404 after the provider rotates models out, which is why
  `syn:` aliases exist. `synthetic_models` reports both the alias and its
  current `huggingFace` target.
- Reasoning models spend `max_tokens` on reasoning first. With a small budget
  the reply can be `content: ""` and `finishReason: "length"` — the tool says
  so in `note` instead of returning an empty string silently.
- `/quotas` and `/messages/count_tokens` do not count against subscription
  limits (and `/embeddings` is free too — the `llm` component will own that
  call; see `docs/embed-models.md`); `/search` draws on its own hourly quota; `/v2/search`
  accepts only `query` and always returns five hits, so `results`/`maxChars`
  bound what enters the conversation.

## License

MIT
