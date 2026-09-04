# niffler-synthetic

First-class [Synthetic.new](https://dev.synthetic.new/docs/api/overview) support
for [Niffler](https://github.com/gokr/niffler) — an `niffler-component` plugin.

The `synthetic` component wraps Synthetic's OpenAI-compatible inference API
(`https://api.synthetic.new`) and its Synthetic-specific extras: subscription
usage tracking, the live model catalog, and zero-data-retention web search.

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
| `synthetic_usage` | Subscription usage + rate limits: requests this cycle, weekly token credits (percent and $ remaining, next regen), rolling five-hour limit, hourly search quota. Persists a snapshot to the store (`kind: synthetic`) on every call. Also the **`/synthetic` slash command** in the web UI. |
| `synthetic_history` | Recent usage snapshots with deltas (requests, weekly %, 5h headroom) — usage is trackable over time because `synthetic_usage` records every poll. |
| `synthetic_models` | Live model catalog: `syn:` aliases and pinned `hf:` ids with context/output limits, per-token pricing, features, vision. |
| `synthetic_search` | Web search (docs/synthetic/search) — ranked pages, zero data retention; draws on its own hourly quota. |
| `synthetic_models_source` | *Hidden* [models source plugin](https://github.com/gokr/niffler/blob/main/docs/MANUAL.md): a JSON Merge Patch (x-models-source v1) that refreshes the `models` component's `synthetic` provider block with live ids, limits and $/Mtok costs. |

## Slash command

`/synthetic` (web UI chat): renders current usage — one summary line plus the
numbers. Flags: `raw` (full provider JSON), `history` (tracked snapshots with
deltas instead of a live poll).

```
/synthetic
/synthetic history
```

## API key

`SYNTHETIC_API_KEY` from the harness environment or `NIF_ROOT/.env`
(dotenv), falling back to opencode's key store
(`~/.local/share/opencode/auth.json`, key `synthetic`). The key is never
logged. Get one at <https://dev.synthetic.new>.

## License

MIT
