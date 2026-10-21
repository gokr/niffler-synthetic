## synthetic — first-class Synthetic.new support for Niffler.
##
## https://dev.synthetic.new/docs/api/overview — an OpenAI-compatible and an
## Anthropic-compatible inference API on `https://api.synthetic.new`
## (`/openai/v1`, `/anthropic/v1`), plus Synthetic-specific endpoints for
## usage quotas (docs/synthetic/quotas), zero-data-retention web search
## (docs/synthetic/search), chat, text completion, embeddings and token
## counting.
##
## What this component provides:
## - synthetic_usage  — live subscription usage + rate limits (the
##   `/synthetic` slash command); every poll is persisted to the store
##   (kind "synthetic", id "usage") so usage is trackable over time.
## - synthetic_history — stored usage snapshots with deltas.
## - synthetic_models — the live model catalog: syn: aliases and pinned
##   hf: ids with context/output limits, per-token pricing, features —
##   filterable by capability, context window and free-text query.
## - synthetic_search — web search (results only enter the conversation;
##   the provider retains no query data).
## - synthetic_chat — one auxiliary OpenAI-compatible completion: a prompt
##   or a full messages array, vision images, JSON mode, reasoning effort,
##   tool schemas, streaming aggregation, and a resolved-model readback
##   (`syn:` alias → concrete hf: id). Not a conversation path — core's
##   hidden `chat` owns that; this is for one-shot work where an explicit
##   model override is the point.
## - synthetic_count_tokens — Anthropic-compatible token counting
##   (`/anthropic/v1/messages/count_tokens`) for sizing a prompt before
##   spending a request (subscriber-only endpoint).
## - synthetic_models_source — hidden x-models-source plugin: feeds the
##   models component a live JSON-Merge-Patch for the "synthetic" provider
##   block (ids, limits, $/Mtok costs), so model selection resolves against
##   what the endpoint actually serves.
##
## `synthetic` here is the provider's own extra surface, not a replacement
## for the harness `llm` component: the runner's `chat` tool owns the
## conversation, these tools serve one-shot calls the conversation itself
## does not need to route through a configured provider.
##
## Key resolution (never logged): SYNTHETIC_API_KEY env var (harness env or
## NIF_ROOT/.env), else the opencode key store
## (~/.local/share/opencode/auth.json → synthetic.key). The API origin can
## be overridden with SYNTHETIC_BASE_URL (proxy/self-hosted gateway).

import std/[httpclient, json, math, os, strutils, times]
import niffler/sdk

let comp = newComponent("synthetic", "0.2.0")

const defaultBaseUrl = "https://api.synthetic.new"
const defaultModel = "syn:small:text"
  ## Alias for the always-current small text model: cheap and fast, the
  ## right default for an auxiliary one-shot call.
const maxHistory = 60
  ## Rolling snapshot cap in the store doc — about two months of daily polls.

proc baseUrl(): string =
  ## API origin; SYNTHETIC_BASE_URL overrides it (proxy, gateway, tests).
  result = getEnv("SYNTHETIC_BASE_URL", defaultBaseUrl).strip()
  while result.len > 1 and result[^1] == '/':
    result.setLen(result.len - 1)
  if result.len == 0: result = defaultBaseUrl

# ---------------------------------------------------------------------------
# helpers

proc perM(s: string): float =
  ## Pricing string "$0.00000015" (per token) → $/Mtok, the models.dev cost
  ## shape. 0.0 when absent or unparseable.
  var t = s.strip()
  if t.len > 0 and t[0] == '$': t = t[1 .. ^1]
  try:
    # six decimals is far below a cent per million tokens and keeps derived
    # values like 0.44999999999999996 out of the reply
    return round(parseFloat(t) * 1_000_000 * 1_000_000) / 1_000_000
  except CatchableError:
    return 0.0

proc hasStr(arr: JsonNode, val: string): bool =
  ## Array-of-strings membership (nil-safe).
  if arr != nil and arr.kind == JArray:
    for e in arr:
      if e.getStr("") == val: return true

# ---------------------------------------------------------------------------
# key + transport

proc apiKey(): string =
  ## SYNTHETIC_API_KEY env (dotenv loaded by the SDK), else opencode's store.
  result = getEnv("SYNTHETIC_API_KEY")
  if result.len == 0:
    let p = getHomeDir() / ".local" / "share" / "opencode" / "auth.json"
    if fileExists(p):
      try:
        result = parseJson(readFile(p)){"synthetic"}{"key"}.getStr("")
      except CatchableError:
        discard
  if result.len == 0:
    raise newException(ValueError,
      "no Synthetic API key — set SYNTHETIC_API_KEY (harness env or " &
      "NIF_ROOT/.env) or log in via opencode (~/.local/share/opencode/auth.json)")

proc synRequestRaw(verb: HttpMethod, path: string, body: JsonNode = nil,
                   timeoutMs: int = 20_000): string =
  ## One authenticated API call; returns the body text (SSE included) and
  ## raises IOError with a short, key-free message on a non-2xx reply.
  let key = apiKey()
  let c = newHttpClient("niffler-synthetic/0.2", timeout = max(timeoutMs, 1000))
  defer: c.close()
  c.headers = newHttpHeaders({"Authorization": "Bearer " & key,
                              "Content-Type": "application/json"})
  var resp = c.request(baseUrl() & path, verb,
                       if body == nil: "" else: $body)
  if not resp.code.is2xx():
    var detail = resp.body.strip()
    if detail.len > 200: detail = detail[0 ..< 200] & "…"
    raise newException(IOError,
      "synthetic: HTTP " & $resp.code.int & " from " & path &
      (if detail.len > 0: ": " & detail else: ""))
  result = resp.body

proc synRequest(verb: HttpMethod, path: string, body: JsonNode = nil,
                timeoutMs: int = 20_000): JsonNode =
  ## synRequestRaw plus JSON decoding (the JSON API surface).
  let raw = synRequestRaw(verb, path, body, timeoutMs)
  try:
    return parseJson(raw)
  except CatchableError as e:
    raise newException(IOError, "synthetic: bad JSON from " & path & ": " & e.msg)

# ---------------------------------------------------------------------------
# usage tracking (store kind "synthetic", id "usage")

proc compact(quotas: JsonNode): JsonNode =
  ## The human-first usage payload: a short multi-line summary (one metric
  ## per line, rendered verbatim by UIs) plus the numbers that matter.
  ## Sized for a slash-command meta block (~400 chars of JSON).
  let sub = quotas{"subscription"}
  let wk = quotas{"weeklyTokenLimit"}
  let fh = quotas{"rollingFiveHourLimit"}
  let se = quotas{"search"}{"hourly"}
  var s = "Synthetic: " & $sub{"requests"}.getInt(0) & "/" &
          $sub{"limit"}.getInt(0) & " requests this cycle"
  if sub{"renewsAt"}.getStr("").len >= 16:
    s.add(" (renews " & sub{"renewsAt"}.getStr("")[0 ..< 16] & ")")
  if wk != nil and wk.kind == JObject:
    s.add("\nweekly credits " & wk{"remainingCredits"}.getStr("?") & "/" &
          wk{"maxCredits"}.getStr("?") & " (" &
          wk{"percentRemaining"}.getFloat(0).formatFloat(ffDecimal, 1) & "% left")
    if wk{"nextRegenAt"}.getStr("").len >= 16:
      s.add(", +" & wk{"nextRegenCredits"}.getStr("?") & " at " &
            wk{"nextRegenAt"}.getStr("")[0 ..< 16])
    s.add(")")
  if fh != nil and fh.kind == JObject:
    s.add("\n5h rolling " & fh{"remaining"}.getFloat(0).formatFloat(ffDecimal, 1) &
          "/" & $fh{"max"}.getInt(0) &
          (if fh{"limited"}.getBool(false): " LIMITED" else: ""))
  if se != nil and se.kind == JObject:
    s.add("\nsearch " & $se{"requests"}.getInt(0) & "/" &
          $se{"limit"}.getInt(0) & " per hour")
  let ft = quotas{"freeToolCalls"}
  if ft != nil and ft.kind == JObject and ft{"limit"}.getInt(0) > 0:
    s.add("\nfree tool calls " & $ft{"requests"}.getInt(0) & "/" &
          $ft{"limit"}.getInt(0) & " this cycle")
  %*{"ok": true, "summary": s,
     "subscription": {"requests": sub{"requests"}.getInt(0),
                      "limit": sub{"limit"}.getInt(0)},
     "weekly": {"percentRemaining": wk{"percentRemaining"}.getFloat(0),
                "remainingCredits": wk{"remainingCredits"}.getStr(""),
                "maxCredits": wk{"maxCredits"}.getStr("")},
     "rollingFiveHour": {"remaining": fh{"remaining"}.getFloat(0),
                         "max": fh{"max"}.getInt(0),
                         "limited": fh{"limited"}.getBool(false)},
     "search": {"requests": se{"requests"}.getInt(0),
                "limit": se{"limit"}.getInt(0)},
     "freeToolCalls": {"requests": ft{"requests"}.getInt(0),
                       "limit": ft{"limit"}.getInt(0)}}

proc snapshotEntry(quotas: JsonNode): JsonNode =
  ## One compact history point (store doc size stays ~10 KB at the cap).
  let sub = quotas{"subscription"}
  let wk = quotas{"weeklyTokenLimit"}
  let fh = quotas{"rollingFiveHourLimit"}
  let se = quotas{"search"}{"hourly"}
  %*{"at": $int(epochTime()),
     "subRequests": sub{"requests"}.getInt(0),
     "subLimit": sub{"limit"}.getInt(0),
     "weeklyPct": wk{"percentRemaining"}.getFloat(0),
     "weeklyCredits": wk{"remainingCredits"}.getStr(""),
     "fiveRemaining": fh{"remaining"}.getFloat(0),
     "fiveMax": fh{"max"}.getInt(0),
     "searchRequests": se{"requests"}.getInt(0),
     "searchLimit": se{"limit"}.getInt(0)}

proc persistSnapshot(quotas: JsonNode): bool =
  ## Append to the rolling usage history in the store. Best effort: the
  ## snapshot is still returned when the store is unavailable.
  try:
    let cur = comp.request("store", "get",
      %*{"kind": "synthetic", "id": "usage"}, 10_000)
    var doc: JsonNode
    if cur{"ok"}.getBool(false) and cur{"value"} != nil:
      doc = cur{"value"}
    else:
      doc = %*{"history": []}
    if doc{"history"} == nil or doc{"history"}.kind != JArray:
      doc["history"] = newJArray()
    doc["history"].add(snapshotEntry(quotas))
    if doc["history"].len > maxHistory:
      let excess = doc["history"].len - maxHistory
      var trimmed = newJArray()
      for i in excess ..< doc["history"].len:
        trimmed.add(doc["history"][i])
      doc["history"] = trimmed
    doc["updatedAt"] = %($int(epochTime()))
    discard comp.request("store", "put",
      %*{"kind": "synthetic", "id": "usage", "value": doc}, 10_000)
    return true
  except CatchableError:
    return false

proc historyDoc(): JsonNode =
  ## The stored usage doc, or nil when none/tracking unavailable.
  try:
    let r = comp.request("store", "get",
      %*{"kind": "synthetic", "id": "usage"}, 10_000)
    if r{"ok"}.getBool(false) and r{"value"} != nil:
      return r{"value"}
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# tools

proc usageHistory(limit: int): JsonNode =
  ## Shared by synthetic_history and the slash history flag: the most
  ## recent stored snapshots, oldest first, with deltas vs the previous.
  let doc = historyDoc()
  if doc == nil:
    return %*{"ok": true, "history": [],
              "note": "no usage tracked yet — call synthetic_usage"}
  var hist: JsonNode = doc{"history"}
  if hist == nil or hist.kind != JArray or hist.len == 0:
    return %*{"ok": true, "history": []}
  let n = min(max(limit, 1), maxHistory)
  let start = max(0, hist.len - n)
  var res = newJArray()
  for i in start ..< hist.len:
    var e = copy(hist[i])
    if i > 0:
      e["dSubRequests"] = %(hist[i]{"subRequests"}.getInt(0) -
                            hist[i-1]{"subRequests"}.getInt(0))
      e["dWeeklyPct"] = %(hist[i]{"weeklyPct"}.getFloat(0) -
                           hist[i-1]{"weeklyPct"}.getFloat(0))
      e["dFiveRemaining"] = %(hist[i]{"fiveRemaining"}.getFloat(0) -
                                hist[i-1]{"fiveRemaining"}.getFloat(0))
    res.add(e)
  return %*{"ok": true, "count": res.len, "history": res,
            "snapshots": hist.len}

comp.tool(%*{"onDemand": true,
             "hint": "Check the Synthetic.new subscription: quota left, weekly credits, 5h window, search quota"}):
  proc synthetic_usage(raw: bool = false, history: bool = false): JsonNode =
    ## Current Synthetic.new subscription usage and rate limits: requests
    ## this billing cycle, weekly token credits (percent and $ remaining,
    ## next regen), the rolling five-hour limit, and the hourly search
    ## quota. Every call snapshots into the store (kind "synthetic") so
    ## usage is trackable over time — synthetic_history reads it back.
    ## This is also the /synthetic slash command.
    ## - raw: return the provider's full quota JSON instead of the summary
    ## - history: show tracked snapshots with deltas instead of polling
    if history:
      var res = usageHistory(5)
      let hist = res{"history"}
      if hist != nil and hist.kind == JArray and hist.len > 0:
        let last = hist[^1]
        res["summary"] = %("tracked: " & $last{"subRequests"}.getInt(0) &
          "/" & $last{"subLimit"}.getInt(0) & " requests, weekly credits " &
          last{"weeklyCredits"}.getStr("?") & " left (" &
          last{"weeklyPct"}.getFloat(0).formatFloat(ffDecimal, 1) & "%)")
      return res
    let quotas = synRequest(HttpGET, "/v2/quotas")
    if raw:
      return %*{"ok": true, "quotas": quotas,
                "tracked": persistSnapshot(quotas)}
    var res = compact(quotas)
    res["tracked"] = %persistSnapshot(quotas)
    return res

comp.tool(%*{"onDemand": true,
             "hint": "Tracked Synthetic.new usage over time — snapshots with deltas, no live poll"}):
  proc synthetic_history(limit: int = 10): JsonNode =
    ## Recent Synthetic.new usage snapshots recorded by synthetic_usage,
    ## oldest first, each with the delta versus the previous snapshot
    ## (subscription requests, weekly credit percentage). Empty when
    ## nothing has been tracked yet.
    ## - limit: how many of the most recent snapshots to show (1-60)
    usageHistory(limit)

comp.tool(%*{"onDemand": true, "effect": "read",
             "hint": "List or filter the live Synthetic.new model catalog — ids, syn: alias targets, context limits, $/Mtok, vision/tools/reasoning"}):
  proc synthetic_models(query: string = "", vision: bool = false,
                        tools: bool = false, reasoning: bool = false,
                        minContext: int = 0, full: bool = false): JsonNode =
    ## The live Synthetic.new model catalog: syn: aliases (always route to
    ## the current recommended model) and pinned hf: ids, each with
    ## context/output limits, per-token pricing and supported features.
    ## Use before naming a model in a provider, llm or synthetic_chat call.
    ## Filters are ANDed. Every entry is either an alias (kind "alias":
    ## syn:/infinite:, huggingFace names the model it currently resolves to —
    ## the value to pin if you need a fixed model) or a pinned hf: model
    ## (kind "model"). `free` marks $0 entries; `categories` lists the
    ## provider's own labels (e.g. "recommended").
    ## - query: free-text match on id, huggingFace id, display name, description
    ## - vision: only models that accept image input
    ## - tools: only models with tool calling
    ## - reasoning: only models with a reasoning/thinking mode
    ## - minContext: only models with at least this many context tokens
    ## - full: include every descriptor field the API returns
    let data = synRequest(HttpGET, "/openai/v1/models"){"data"}
    let needle = query.strip().toLowerAscii()
    var res = newJArray()
    var total = 0
    for m in data:
      inc total
      let id = m{"id"}.getStr("")
      let hf = m{"hugging_face_id"}.getStr("")
      let isVision = hasStr(m{"input_modalities"}, "image")
      let feats = m{"supported_features"}
      if vision and not isVision: continue
      if tools and not hasStr(feats, "tools"): continue
      if reasoning and not hasStr(feats, "reasoning"): continue
      if minContext > 0 and m{"context_length"}.getInt(0) < minContext: continue
      if needle.len > 0:
        let hay = (id & " " & hf & " " & m{"display_name"}.getStr("") &
                   " " & m{"description"}.getStr("")).toLowerAscii()
        if hay.find(needle) < 0: continue
      let p = m{"pricing"}
      let inCost = perM(p{"prompt"}.getStr(""))
      let outCost = perM(p{"completion"}.getStr(""))
      # The provider's `name` is the alias for syn:/infinite: entries and the
      # bare owner/model path for pinned hf: ones; `huggingFace` is the model
      # the alias resolves to right now, which is what a pin should use.
      var entry = %*{"id": id,
                     "name": m{"name"}.getStr(""),
                     "huggingFace": hf,
                     "displayName": m{"display_name"}.getStr(""),
                     "kind": (if id.startsWith("hf:"): "model" else: "alias"),
                     "alwaysOn": m{"always_on"}.getBool(false),
                     "context": m{"context_length"}.getInt(0),
                     "maxOutput": m{"max_output_length"}.getInt(0),
                     "input$/M": inCost,
                     "output$/M": outCost,
                     "free": inCost == 0.0 and outCost == 0.0,
                     "features": feats,
                     "vision": isVision}
      if m{"categories"} != nil and m{"categories"}.len > 0:
        entry["categories"] = m{"categories"}
      if m{"reasoning_parameters"}{"efforts"} != nil:
        entry["reasoningEfforts"] = m{"reasoning_parameters"}{"efforts"}
      if full:
        # every remaining descriptor field: the ones promoted to the compact
        # (camelCase) shape are skipped so the result has one spelling each
        const promoted = ["id", "name", "hugging_face_id", "display_name",
                          "categories", "context_length", "max_output_length",
                          "pricing", "input_modalities", "supported_features",
                          "reasoning_parameters", "always_on"]
        for k, v in m:
          if k notin promoted: entry[k] = v
      res.add(entry)
    return %*{"ok": true, "count": res.len, "total": total,
              "models": res}

comp.tool(%*{"onDemand": true, "effect": "read",
             "hint": "Search the web through Synthetic (zero data retention): ranked pages with excerpts and dates"}):
  proc synthetic_search(query: string, results: int = 5,
                        maxChars: int = 900): JsonNode =
    ## Web search via Synthetic.new's zero-data-retention search API:
    ## ranked pages with title, url, publication date and a text excerpt.
    ## Use when you need fresh facts from the web. Queries are not retained
    ## by the provider; searches draw on an hourly quota (see
    ## synthetic_usage), separate from the subscription's request quota.
    ## The API itself takes only the query and returns five hits, so
    ## `results` and `maxChars` bound what enters the conversation.
    ## - query: what to search for
    ## - results: how many hits to return (1-5; the API returns 5)
    ## - maxChars: per-result excerpt cap in characters (200-4000, default 900)
    if query.strip().len == 0:
      raise newException(ValueError, "synthetic_search needs a query")
    let n = min(max(results, 1), 5)
    let cap = min(max(maxChars, 200), 4000)
    let resp = synRequest(HttpPOST, "/v2/search", %*{"query": query}, 30_000)
    var res = newJArray()
    var i = 0
    for r in resp{"results"}:
      if i >= n: break
      var text = r{"text"}.getStr("")
      if text.len > cap: text = text[0 ..< cap] & "…"
      var hit = %*{"url": r{"url"}.getStr(""),
                   "title": r{"title"}.getStr(""),
                   "text": text}
      let published = r{"published"}.getStr("")
      if published.len > 0: hit["published"] = %published
      res.add(hit)
      inc i
    return %*{"ok": true, "query": query, "count": res.len,
              "returned": resp{"results"}.len, "results": res}

# ---------------------------------------------------------------------------
# chat / completion / embedding plumbing

proc asText(n: JsonNode): string =
  ## Message content as plain text: a string, or the text parts of an
  ## OpenAI content array (image parts have no text and are skipped).
  if n == nil: return ""
  case n.kind
  of JString: return n.getStr("")
  of JArray:
    for part in n:
      if part{"type"}.getStr("text") == "text":
        result.add(part{"text"}.getStr(""))
  else: discard

proc messageArray(prompt, system: string, messages: JsonNode,
                  images: seq[string]): JsonNode =
  ## Caller messages win; otherwise build [{system?}, {user prompt}]. When
  ## images are given they are attached as image_url parts to the last
  ## user message (URL or data: URI, per docs/openai/chat-completions).
  if messages != nil and messages.kind == JArray and messages.len > 0:
    result = copy(messages)
  else:
    if prompt.strip().len == 0:
      raise newException(ValueError,
        "synthetic_chat needs a prompt (or a messages array)")
    result = newJArray()
    if system.strip().len > 0:
      result.add(%*{"role": "system", "content": system})
    result.add(%*{"role": "user", "content": prompt})
  if images.len == 0: return
  var idx = -1
  for i in countdown(result.len - 1, 0):
    if result[i]{"role"}.getStr("") == "user":
      idx = i
      break
  if idx < 0:
    raise newException(ValueError,
      "images need a user message to attach to")
  var parts = newJArray()
  let content = result[idx]{"content"}
  if content != nil and content.kind == JString and content.getStr("").len > 0:
    parts.add(%*{"type": "text", "text": content.getStr("")})
  elif content != nil and content.kind == JArray:
    for p in content:
      parts.add(p)
  for img in images:
    parts.add(%*{"type": "image_url", "image_url": {"url": img}})
  result[idx]["content"] = parts

proc usageSummary(usage: JsonNode): JsonNode =
  ## One usage shape for chat/completion/embedding replies, nil-safe.
  if usage == nil or usage.kind != JObject: return newJObject()
  let inp = usage{"prompt_tokens"}.getInt(usage{"input_tokens"}.getInt(0))
  let outp = usage{"completion_tokens"}.getInt(usage{"output_tokens"}.getInt(0))
  result = %*{"inputTokens": inp, "outputTokens": outp,
              "totalTokens": usage{"total_tokens"}.getInt(inp + outp)}
  let cached = usage{"prompt_tokens_details"}{"cached_tokens"}.getInt(
               usage{"cache_read_input_tokens"}.getInt(0))
  if cached > 0: result["cachedInputTokens"] = %cached

proc aggregateSse(raw: string): tuple[content, reasoning: string,
                                      model, finishReason: string,
                                      usage: JsonNode, toolCalls: JsonNode] =
  ## Fold an OpenAI-style SSE chat stream into one message. The provider
  ## sends `delta.content`, `delta.reasoning`/`delta.reasoning_content`
  ## and, for tool calls, per-index `delta.tool_calls` fragments whose
  ## name/arguments arrive split across chunks.
  var calls = newJArray()
  var argsByIndex: seq[string]
  for line in raw.splitLines():
    let t = line.strip()
    if not t.startsWith("data:"): continue
    let payload = t[5 .. ^1].strip()
    if payload.len == 0 or payload == "[DONE]": continue
    var chunk: JsonNode
    try:
      chunk = parseJson(payload)
    except CatchableError:
      continue
    if chunk{"model"}.getStr("").len > 0:
      result.model = chunk{"model"}.getStr("")
    if chunk{"usage"} != nil and chunk{"usage"}.kind == JObject:
      result.usage = chunk{"usage"}
    let choices = chunk{"choices"}
    if choices == nil or choices.kind != JArray: continue
    for choice in choices:
      let delta = choice{"delta"}
      if delta != nil and delta.kind == JObject:
        let c = delta{"content"}.getStr("")
        if c.len > 0: result.content.add(c)
        var r = delta{"reasoning"}.getStr("")
        if r.len == 0: r = delta{"reasoning_content"}.getStr("")
        if r.len > 0: result.reasoning.add(r)
        let tc = delta{"tool_calls"}
        if tc != nil and tc.kind == JArray:
          for frag in tc:
            let idx = frag{"index"}.getInt(0)
            while calls.len <= idx:
              calls.add(%*{"id": "", "type": "function",
                            "function": {"name": "", "arguments": ""}})
              argsByIndex.add("")
            let fn = frag{"function"}
            if fn != nil:
              if fn{"name"}.getStr("").len > 0:
                calls[idx]["function"]["name"] = %fn{"name"}.getStr("")
              argsByIndex[idx].add(fn{"arguments"}.getStr(""))
            if frag{"id"}.getStr("").len > 0:
              calls[idx]["id"] = %frag{"id"}.getStr("")
      let fr = choice{"finish_reason"}.getStr("")
      if fr.len > 0: result.finishReason = fr
  for i in 0 ..< calls.len:
    calls[i]["function"]["arguments"] = %argsByIndex[i]
  if calls.len > 0: result.toolCalls = calls

# ---------------------------------------------------------------------------
# tools

comp.tool(%*{"onDemand": true, "effect": "read", "timeoutMs": 600000,
             "hint": "Auxiliary one-shot completion with an explicit model: a cheap/fast model for a subtask, a vision read, a JSON extraction — not a conversation path (core's chat owns that); reports which model answered"}):
  proc synthetic_chat(prompt: string = "", model: string = defaultModel,
                      systemPrompt: string = "", messages: JsonNode = nil,
                      images: seq[string] = @[], maxTokens: int = 1024,
                      temperature: float = -1.0, topP: float = -1.0,
                      topK: int = -1, stop: seq[string] = @[],
                      seed: int = 0, reasoningEffort: string = "",
                      jsonMode: bool = false, tools: JsonNode = nil,
                      toolChoice: string = "", stream: bool = false,
                      timeout: int = 120000): JsonNode =
    ## One auxiliary OpenAI-compatible completion on Synthetic.new
    ## (POST /openai/v1/chat/completions).
    ##
    ## This is NOT the way to run the conversation: core's hidden `chat`
    ## (the llm component) owns that, with retries, cancellation, context
    ## admission, compaction accounting and provider/model resolution.
    ## Use this for one-shot auxiliary work where choosing the model is the
    ## point — a cheap small model for a classification or extraction
    ## instead of the session's model, a vision read, or reading back which
    ## concrete model a `syn:` alias currently resolves to so it can be
    ## pinned. Costs one billed request, has no retry and no cancellation,
    ## and does not appear in the session's usage accounting.
    ##
    ## Give either a prompt (plus an optional system prompt) or a full
    ## OpenAI messages array. Returns the assistant text, the reasoning
    ## trace when the model exposes one, tool calls, token usage and the
    ## concrete model that answered. Give the model its own `systemPrompt`
    ## rather than the harness's.
    ## - prompt: user message text (ignored when messages is given)
    ## - model: model id or syn: alias (default syn:small:text)
    ## - systemPrompt: system message (ignored when messages is given)
    ## - messages: OpenAI-style messages array [{role, content}], for multi-turn
    ## - images: image URLs or data: URIs attached to the last user message
    ##   (only for vision models — check synthetic_models {vision: true})
    ## - maxTokens: output token cap, reasoning tokens included (default 1024)
    ## - temperature: sampling randomness 0.0-2.0, omitted when negative
    ## - topP: nucleus sampling threshold 0.0-1.0, omitted when negative
    ## - topK: limit sampling to the top K tokens, omitted when negative
    ## - stop: stop sequence(s)
    ## - seed: random seed for deterministic sampling, omitted when 0
    ## - reasoningEffort: low|medium|high (model-specific efforts in
    ##   synthetic_models.reasoningEfforts); empty leaves the model default
    ## - jsonMode: ask for a JSON object reply (response_format json_object)
    ## - tools: OpenAI tool definitions array the model may call
    ## - toolChoice: auto|none|required when tools are given
    ## - stream: request SSE and fold it back into one message (required for
    ##   infinite: aliases, which are slow by design; no live deltas here)
    ## - timeout: request timeout in ms (default 120000, max 600000)
    var body = %*{"model": (if model.strip().len > 0: model else: defaultModel),
                  "messages": messageArray(prompt, systemPrompt, messages,
                                           images)}
    if maxTokens > 0: body["max_tokens"] = %maxTokens
    if temperature >= 0: body["temperature"] = %temperature
    if topP >= 0: body["top_p"] = %topP
    if topK >= 0: body["top_k"] = %topK
    if stop.len > 0: body["stop"] = %stop
    if seed != 0: body["seed"] = %seed
    if reasoningEffort.strip().len > 0:
      body["reasoning_effort"] = %reasoningEffort.strip()
    if jsonMode: body["response_format"] = %*{"type": "json_object"}
    if tools != nil and tools.kind == JArray and tools.len > 0:
      body["tools"] = tools
      if toolChoice.strip().len > 0: body["tool_choice"] = %toolChoice.strip()
    let ms = min(max(timeout, 1000), 600_000)
    var content, reasoning, finishReason, answered: string
    var usage, toolCalls: JsonNode
    if stream:
      body["stream"] = %true
      body["stream_options"] = %*{"include_usage": true}
      let agg = aggregateSse(synRequestRaw(HttpPOST,
        "/openai/v1/chat/completions", body, ms))
      content = agg.content
      reasoning = agg.reasoning
      finishReason = agg.finishReason
      answered = agg.model
      usage = agg.usage
      toolCalls = agg.toolCalls
    else:
      let resp = synRequest(HttpPOST, "/openai/v1/chat/completions", body, ms)
      answered = resp{"model"}.getStr("")
      usage = resp{"usage"}
      let choice = resp{"choices"}{0}
      if choice != nil and choice.kind == JObject:
        finishReason = choice{"finish_reason"}.getStr("")
        let msg = choice{"message"}
        content = asText(msg{"content"})
        reasoning = msg{"reasoning_content"}.getStr("")
        if reasoning.len == 0: reasoning = msg{"reasoning"}.getStr("")
        let tc = msg{"tool_calls"}
        if tc != nil and tc.kind == JArray and tc.len > 0:
          # keep the OpenAI request/echo shape: the provider also stamps an
          # index here, which only means something inside a stream
          toolCalls = newJArray()
          for call in tc:
            toolCalls.add(%*{"id": call{"id"}.getStr(""),
                             "type": call{"type"}.getStr("function"),
                             "function": {"name": call{"function"}{"name"}.getStr(""),
                                          "arguments": call{"function"}{"arguments"}.getStr("")}})
    var res = %*{"ok": true, "model": answered,
                 "requestedModel": model, "content": content,
                 "finishReason": finishReason,
                 "usage": usageSummary(usage)}
    if reasoning.len > 0: res["reasoning"] = %reasoning
    if toolCalls != nil: res["toolCalls"] = toolCalls
    if content.len == 0 and toolCalls == nil and reasoning.len > 0:
      res["note"] = %("empty content — the model spent the whole " &
        $maxTokens & "-token budget on reasoning; raise maxTokens")
    return res

comp.tool(%*{"onDemand": true, "effect": "read",
             "hint": "Count input tokens for a prompt/messages before spending a request"}):
  proc synthetic_count_tokens(prompt: string = "", systemPrompt: string = "",
                              messages: JsonNode = nil,
                              model: string = defaultModel): JsonNode =
    ## Count input tokens before paying for a request, using the
    ## Anthropic-compatible endpoint POST /anthropic/v1/messages/count_tokens
    ## (a subscriber-only endpoint that itself does not count against the
    ## subscription limit). Use it to check a prompt fits a context window
    ## or to budget a multi-message conversation.
    ## - prompt: single user message text (or use messages)
    ## - systemPrompt: system prompt to include in the count
    ## - messages: Anthropic-style [{role: user|assistant, content: text}]
    ## - model: model id or syn: alias whose tokenizer is used
    var msgs: JsonNode
    if messages != nil and messages.kind == JArray and messages.len > 0:
      msgs = copy(messages)
    elif prompt.strip().len > 0:
      msgs = %*[{"role": "user", "content": prompt}]
    else:
      raise newException(ValueError,
        "synthetic_count_tokens needs a prompt or a messages array")
    var body = %*{"model": (if model.strip().len > 0: model else: defaultModel),
                  "messages": msgs}
    if systemPrompt.strip().len > 0: body["system"] = %systemPrompt
    let resp = synRequest(HttpPOST, "/anthropic/v1/messages/count_tokens",
                          body, 30_000)
    return %*{"ok": true, "model": model,
              "inputTokens": resp{"input_tokens"}.getInt(0),
              "messages": msgs.len,
              "note": "counts input only; output cost is maxTokens " &
                      "times the model's output rate"}

# The macro derives the schema from the Nim signature, and JsonNode maps to
# {"type": "object"}; `messages` and `tools` are arrays of objects on the wire,
# so correct the advertisement before the registration is published.

proc advertiseArray(toolName, prop, itemsKind: string) =
  for t in comp.tools.mitems:
    if t.name != toolName: continue
    let p = t.schema{"properties"}{prop}
    if p == nil or p.kind != JObject: continue
    p["type"] = %"array"
    p["items"] = %*{"type": itemsKind}

advertiseArray("synthetic_chat", "messages", "object")
advertiseArray("synthetic_chat", "tools", "object")

# ---------------------------------------------------------------------------
# models-catalog source plugin (hidden; docs/MANUAL.md §Source plugins)
# Registered via the low-level API: x-models-source is a top-level schema
# key, not part of x-harness.

proc modelsSourceImpl(version: int): JsonNode =
  if version != 1:
    raise newException(ValueError, "unsupported models source version " & $version)
  let data = synRequest(HttpGET, "/v1/models"){"data"}
  var models = newJObject()
  for m in data:
    let id = m{"id"}.getStr("")
    if id.len == 0: continue
    let p = m{"pricing"}
    # models.dev shape: modalities drive consumers' input/output filters
    # (the tui's picker passes input:"text", which strictly requires this
    # object — a patch entry without it is invisible to pickers).
    var modsIn = %["text"]
    if hasStr(m{"input_modalities"}, "image"):
      modsIn.add(%"image")
    var modsOut = newJArray()
    if m{"output_modalities"} == nil or hasStr(m{"output_modalities"}, "text"):
      modsOut.add(%"text")
    var entry = %*{"id": id,
                   "name": m{"hugging_face_id"}.getStr(id),
                   "limit": {"context": m{"context_length"}.getInt(0),
                             "output": m{"max_output_length"}.getInt(0)},
                   "cost": {"input": perM(p{"prompt"}.getStr("")),
                            "output": perM(p{"completion"}.getStr("")),
                            "cache_read": perM(p{"input_cache_reads"}.getStr(""))}}
    entry["modalities"] = %*{"input": modsIn, "output": modsOut}
    entry["reasoning"] = %hasStr(m{"supported_features"}, "reasoning")
    entry["attachment"] = %hasStr(m{"input_modalities"}, "image")
    # Reasoning effort levels this model accepts, in the provider's order.
    # models.dev has no field for this (only a boolean `reasoning`), so it is
    # a plugin-only extension: consumers use it to constrain an effort ladder
    # (shift-tab in a UI, core's session.thinking enum) instead of guessing
    # low/medium/high/max.
    #
    # ADVISORY, NOT A CONTRACT. Probing shows the provider's own list is
    # wrong in both directions: one alias declared none/low/high/xhigh/max
    # but rejected `max` with HTTP 400; another declared low/high/max but
    # accepted medium and xhigh. Never use this to reject a value that
    # works — use it to narrow what is offered, and fall back to the
    # caller's own ladder when the key is absent. The key is omitted when
    # the API declares nothing, so an empty list is never mistaken for
    # "this model has no reasoning".
    let efforts = m{"reasoning_parameters"}{"efforts"}
    if efforts != nil and efforts.kind == JArray and efforts.len > 0:
      var levels = newJArray()
      for e in efforts:
        let level = e.getStr("")
        if level.len > 0 and level notin levels:
          levels.add(%level)
      if levels.len > 0: entry["reasoning_efforts"] = levels
    models[id] = entry
  %*{"patch": {"synthetic": {"id": "synthetic", "name": "Synthetic",
                             "models": models}}}

discard comp.tool("synthetic_models_source", %*{
  "type": "object",
  "properties": {"version": {"type": "integer",
    "description": "models source protocol version"}},
  "description": "Synthetic.new model metadata for the models component " &
    "(x-models-source v1): a JSON Merge Patch that refreshes the " &
    "\"synthetic\" provider block with live ids, limits, $/Mtok costs, " &
    "modalities and the advisory reasoning_efforts levels each model " &
    "declares, from GET /openai/v1/models.",
  "x-models-source": {"version": 1, "priority": 200}},
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    modelsSourceImpl(toolArgs{"version"}.getInt(1)),
  %*{"hidden": true, "timeoutMs": 20000})

# ---------------------------------------------------------------------------
# selftest (docs/WIRE.md — /doctor fans out to it; the two probes are free:
# /v2/quotas never counts against subscription limits and /openai/v1/models
# is a catalog read, so neither spends a request or a search credit)

discard comp.selfTest(proc(c: Component, args: JsonNode): JsonNode =
  let deep = args{"deep"}.getBool(false)
  var checks = newJArray()

  proc run(name: string, probe: proc(): string): JsonNode =
    ## One check: the probe returns its detail string or raises.
    let started = epochTime()
    var ok = true
    var detail = ""
    try:
      detail = probe()
    except CatchableError as e:
      ok = false
      detail = e.msg
    result = %*{"name": name, "ok": ok, "detail": detail,
                "ms": int((epochTime() - started) * 1000)}

  checks.add(run("api-key", proc(): string =
    discard apiKey()
    "resolved (value never logged)"))
  checks.add(run("base-url", proc(): string = baseUrl()))
  checks.add(run("quotas", proc(): string =
    let q = synRequest(HttpGET, "/v2/quotas")
    $q{"subscription"}{"limit"}.getInt(0) & " requests per cycle"))
  checks.add(run("models", proc(): string =
    let n = synRequest(HttpGET, "/openai/v1/models"){"data"}.len
    if n == 0: raise newException(ValueError, "empty catalog")
    $n & " catalog entries"))
  checks.add(run("tools", proc(): string =
    var names: seq[string] = @[]
    for t in comp.tools:
      if not t.schema{"x-harness"}{"hidden"}.getBool(false): names.add(t.name)
    $names.len & " exposed: " & names.join(", ")))
  if deep:
    checks.add(run("search", proc(): string =
      let r = synRequest(HttpPOST, "/v2/search",
                         %*{"query": "synthetic.new api"}, 30_000)
      let n = r{"results"}.len
      if n == 0: raise newException(ValueError, "no search hits")
      $n & " hits (one search credit)"))
  var failed = 0
  for ck in checks:
    if not ck{"ok"}.getBool(false): inc failed
  %*{"ok": failed == 0, "summary": $checks.len & " checks, " &
       $failed & " failed", "checks": checks})

# ---------------------------------------------------------------------------
# slash commands (docs/WIRE.md — declarative UI surface)

let usageParams = parseJson("""
  [{"name": "raw", "kind": "bool", "default": false,
    "description": "full provider JSON"},
   {"name": "history", "kind": "bool", "default": false,
    "description": "recent tracked snapshots instead of a live poll"}]
""")
discard comp.slashCommand("synthetic", "Synthetic.new usage & quotas",
  usageParams, tool = "synthetic_usage")

# Namespaced by package name (docs/WIRE.md, slash naming convention): the
# slash namespace is global, so these must not be bare /models or /search.
discard comp.slashCommand("synthetic-models",
  "Synthetic.new live model catalog (ids, limits, pricing)",
  parseJson("""
    [{"name": "query", "kind": "string", "description": "free-text match"},
     {"name": "vision", "kind": "bool", "default": false,
      "description": "only image-input models"},
     {"name": "tools", "kind": "bool", "default": false,
      "description": "only tool-calling models"},
     {"name": "reasoning", "kind": "bool", "default": false,
      "description": "only models with a reasoning mode"},
     {"name": "minContext", "kind": "int", "default": 0,
      "description": "minimum context window in tokens"},
     {"name": "full", "kind": "bool", "default": false,
      "description": "every descriptor field the API returns"}]
  """), tool = "synthetic_models")

discard comp.slashCommand("synthetic-search",
  "Web search via Synthetic.new (zero data retention)",
  parseJson("""
    [{"name": "query", "kind": "string", "description": "what to search for"},
     {"name": "results", "kind": "int", "default": 5,
      "description": "how many hits (1-5)"},
     {"name": "maxChars", "kind": "int", "default": 900,
      "description": "per-result excerpt cap"}]
  """), tool = "synthetic_search")

discard comp.slashCommand("synthetic-chat",
  "One-shot chat completion via Synthetic.new",
  parseJson("""
    [{"name": "prompt", "kind": "string", "description": "user message"},
     {"name": "model", "kind": "enum", "default": "syn:small:text",
      "values": ["syn:small:text", "syn:small:vision", "syn:large:text",
                 "syn:large:vision"],
      "description": "model id or syn: alias"},
     {"name": "systemPrompt", "kind": "string", "description": "system message"},
     {"name": "jsonMode", "kind": "bool", "default": false,
      "description": "ask for a JSON object reply"}]
  """), tool = "synthetic_chat")

discard comp.slashCommand("synthetic-tokens",
  "Count prompt tokens via Synthetic.new",
  parseJson("""
    [{"name": "prompt", "kind": "string", "description": "text to count"},
     {"name": "model", "kind": "string", "default": "syn:small:text",
      "description": "model whose tokenizer is used"}]
  """), tool = "synthetic_count_tokens")

comp.run()
