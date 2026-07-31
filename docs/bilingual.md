# Bilingual dictation: NB-Whisper + English

Per-utterance automatic language routing between NB-Whisper (Norwegian) and
stock Whisper (English). Hold Fn, speak either language, release — the correct
transcript lands at the cursor. No mode switch, no per-utterance config.

```sh
parrot --bilingual
```

## How it works

Upstream pipeline is unchanged: `HotkeyMonitor → AudioCapture → Transcriber →
TextInjector`. The single `WhisperKitTranscriber` is replaced (at construction
only) by a `RoutingTranscriber` behind the same `Transcriber` protocol:

```
                         [Float] PCM (utterance)
                                  │
                                  ▼
                     ┌────────────────────────┐
                     │   RoutingTranscriber    │
                     │  (actor, Transcriber)   │
                     │                         │
                     │  1. LID pass (tiny)     │
                     │  2. dispatch by lang    │
                     └──────┬──────────┬───────┘
                       lang=no      lang=en
                            ▼          ▼
                 ┌──────────────┐  ┌──────────────┐
                 │  NB-Whisper  │  │ Whisper .en  │
                 │ (WhisperKit) │  │ (WhisperKit) │
                 └──────────────┘  └──────────────┘
```

Three pipelines stay warm: multilingual `whisper-tiny` for language
identification only, `nb-whisper-small` for the Norwegian route,
`whisper-small.en` for the English route. All three load concurrently at
startup; if any is missing, startup fails atomically naming the model —
bilingual mode never silently degrades to single-model.

LID runs WhisperKit's language-detection path on tiny: one encoder pass plus a
single decode step over the `<|lang|>` token distribution
(`detectLangauge(audioArray:)` — the typo is WhisperKit's). It returns the
argmax language and its softmax log-probability, which answers spec open
question 2: the confidence is available directly, `p = exp(langProbs[lang])`.

## Routing policy

The policy is a pure function `(language, confidence, duration) → route`
(`RoutingPolicy.swift`), table-tested in `RoutingPolicyTests`:

- **Norwegian is the default route.** False-English on Norwegian speech is the
  expensive error: NB-Whisper on English is merely degraded, stock English
  Whisper on Norwegian is garbage.
- `en` routes to English only when `p(en) ≥ τ` (default τ = 0.6,
  `--en-threshold`).
- `no`/`nn`/`da`/`sv` all route to NB-Whisper — Whisper LID frequently
  confuses the Scandinavian languages and NB-Whisper is the right target for
  all of them in practice. No per-language routes for these.
- Utterances shorter than 0.6 s skip LID entirely → Norwegian. Short
  "ok"/"nei" gives unreliable LID and the routing cost isn't worth it.
- NB-Whisper's own LID head is never consulted — it is fine-tuned almost
  exclusively on Norwegian and its language distribution is skewed. LID always
  runs on stock tiny.
- Norwegian sentences containing English terms route to NB-Whisper by design;
  it was trained on real Norwegian speech and handles anglicisms. There is no
  mid-utterance code-switch segmentation — one decision per utterance.

Every decision is logged to stderr in the existing style — the primary
debugging surface:

```
◐ lid no 0.94 · 12ms
◐ route no (nb-whisper-small) · lid 12ms · decode 483ms
```

The menu bar shows the active pair (`nb-small+en-small`) and, in the dropdown,
the last routing decision.

## Edge cases

- **Silence / noise-only:** captures with RMS below 0.003 are skipped before
  LID — language detection on silence is meaningless (`∅ silence … skipped`).
  Sanitization of non-speech bracket tokens is the second line of defense;
  NB-Whisper emits the same token families as stock Whisper.
- **Long utterances (> 30 s):** LID sees only the first 30 s window; language
  rarely changes mid-utterance in dictation.
- **LID failure:** logged, then the default (Norwegian) route — never a crash,
  never stock-English-on-Norwegian.

## Models

| id | role | size | source |
|----|------|-----:|--------|
| `whisper-tiny` | LID (hidden from `models list`; `--all` shows it) | ~42 MB | argmaxinc/whisperkit-coreml |
| `nb-whisper-small` | Norwegian route | ~500 MB | converted, see below |
| `whisper-small.en` | English route | ~488 MB | argmaxinc/whisperkit-coreml |

Resident together ≈ 1 GB — fine on 16 GB+ Apple Silicon. If that's too fat,
drop the English route to base.en: `--en-model whisper-base.en`.

`TranscriptionModel` gained two fields for models outside WhisperKit's default
repo: `modelRepo` (custom HF repo for the CoreML artifacts) and `modelFolder`
(local path override, takes precedence — also settable at runtime for the NB
model via `PARROT_NB_MODEL_FOLDER` for testing a fresh conversion).

The bilingual composite is a **flag**, not a registry entry (spec open
question 1): the registry stays purely per-model, and
`parrot models download bilingual` resolves all three.

### Converting NB-Whisper

NB-Whisper (`NbAiLab/nb-whisper-*`) is a standard Whisper-architecture
fine-tune, so whisperkittools conversion applies directly:

```sh
scripts/convert-nb-whisper.sh small                          # convert
HF_UPLOAD_REPO=you/nb-whisper-coreml scripts/convert-nb-whisper.sh small  # + publish
```

Acceptance: the converted model transcribes a Norwegian reference clip with
output matching the PyTorch checkpoint (whitespace/punctuation drift allowed),
and runs on ANE — verify with `powermetrics --samplers ane_power`, not just
"it ran". Start with `nb-whisper-small`; evaluate distil variants if latency
needs headroom.

## Budgets

- Routing overhead: LID ≤ 30 ms on ANE for a ≤ 10 s utterance; total added
  overhead ≤ 80 ms p50 over single-model parrot. Per-stage timings (lid /
  decode) are in every route log line.
- Startup: three warm-ups run concurrently; target ≤ 1.5× the current
  single-model warm start. Measured with `parrot bench warmup` (below).

### Measuring warm start

```sh
parrot bench warmup                    # single-model vs bilingual, 3 iterations each
parrot bench warmup --only bilingual   # just the three-model set
parrot bench warmup --json             # machine-readable, for pasting into a ticket
```

Each iteration builds a *fresh* pipeline set and times `warmUp()`, so nothing
is cached inside the process between iterations. The first iteration is
reported as **cold** and the median of the rest as **warm** — only the first
pays for cold page cache and CoreML compilation. The reported ratio is
warm ÷ warm, against the 1.5× budget.

"Cold" here means cold-in-process: the OS page cache and CoreML's on-disk
compilation cache survive between runs. For a cold-from-boot number, `sudo
purge` first and use `--iterations 1`.

The harness refuses to measure when a model is not on disk — a warm start with
a download folded into it is not a warm start. It names the missing models and
the `parrot models download` command to fix it; `--allow-download` overrides.

Because the three loads are supposed to overlap, the bilingual run also reports
per-model load spans and an overlap efficiency (slowest single load ÷ wall
clock). At 1.0 the wall clock is just the slowest model; below 0.8 the report
flags the warm-up as effectively serialized and prints how many seconds were
lost — the failure mode where the `async let` warm-ups accidentally become a
chain of awaits.

## CLI

```sh
parrot --bilingual                     # nb-whisper-small + whisper-small.en + tiny LID
parrot --bilingual --no-model <id>     # override Norwegian route model
parrot --bilingual --en-model <id>     # override English route model
parrot --bilingual --en-threshold 0.6  # LID confidence gate for the English route
parrot --model <id>                    # unchanged single-model behavior
parrot models download bilingual       # pre-fetch all three models
parrot doctor --bilingual              # checks the bilingual model set is downloaded
```

## Testing

- `swift test --filter RoutingPolicyTests` — table-driven policy tests, no
  audio or models needed.
- `swift test --filter WarmUpProfileTests` — warm-start analysis: median,
  ratio vs the 1.5× budget, and the "not overlapping" flag. No models needed.
- `PARROT_INTEGRATION=1 swift test --filter RoutingIntegrationTests` —
  fixture WAVs → assert route + transcript emptiness; see
  `Tests/fixtures/README.md`. Fixtures are recorded with `--dump-wav`.
- Manual acceptance: dictate 20 mixed utterances into a text field; ≥ 18
  routed correctly, zero stock-Whisper-on-Norwegian outputs.

## Design note: a third route

Nothing here is planned work. This is the answer, written down while the design
is fresh, to "could we add a third language?" — what it would take, what it
would cost, and which parts of the current design would have to change rather
than extend.

**Verdict:** the shape holds. The `Transcriber` protocol boundary, the LID pass,
the decision log, the menu bar, and the whole upstream pipeline are already
route-count-agnostic. But "slots in as another `(cluster, model)` pair" is only
true of the plumbing. Three of the policy's load-bearing assumptions are
*pairwise*, not general, and would have to be replaced first.

### What hardcodes two routes

Mechanical — widening these is typing, not design:

| Where | What |
|---|---|
| `RoutingPolicy.swift:4` | `Route` — two cases |
| `RoutingPolicy.swift:23` | `norwegianCluster` — a single named `Set`, not a table |
| `RoutingPolicy.swift:26` | `englishThreshold` — one scalar |
| `RoutingTranscriber.swift:18` | `norwegian` / `english` stored properties |
| `RoutingTranscriber.swift:36` | `modelID` — built in `init` as `"\(no.id)+\(en.id)"` |
| `RoutingTranscriber.swift:54` | `warmUp()` — three fixed `async let`s |
| `RoutingTranscriber.swift:110` | dispatch — `route == .english ? english : norwegian` |
| `ModelRegistry.swift:96` | `BilingualConfiguration` — `norwegian` / `english` / `lid` fields, pairwise `shortLabel`, two-ID init |
| `ModelRegistry.swift:140` | `abbreviate` — knows `nb-whisper-*` and `whisper-*.en` only |
| `Parrot.swift:41-50` | `--bilingual`, `--no-model`, `--en-model`, `--en-threshold`, and their mutual validation |
| `Parrot.swift:332` | `models download bilingual` |

The natural refactor is a `[RouteSpec]` — `(id, cluster, model, threshold)` —
with `BilingualConfiguration` becoming `RoutingConfiguration` holding one
default route plus N gated challengers, and `Route` becoming a struct wrapping
a route id instead of an enum. `--bilingual` stays as sugar for the NB+EN pair.

### What has to change, not extend

**1. The if-chain silently depends on source order.** `route()` tests the
Norwegian cluster, then `en`, then falls through. With one challenger that is
unambiguous. With two, both can clear their gates at once and whichever is
written first wins. That looks impossible — LID returns a softmax, so at
τ ≥ 0.5 only one language can clear — but τ is user-settable and
`RoutingPolicyTests.testCustomThreshold` already exercises τ = 0.3. So the
ordering bug is reachable today; it is merely unobservable with one challenger.
A third route makes it real. The fix is small and should land *with* the third
route, not after: collect the routes whose gate is cleared, take the argmax of
`p`, fall back to the default.

**2. The default route is justified by a pairwise argument.** "Norwegian is the
safe fallback" rests on a claim about two specific models — NB-Whisper on
English is degraded, stock English Whisper on Norwegian is garbage. That is an
asymmetry between *those two*, not a property of Norwegian. Add a German route
and there is no longer a single model that is least-bad for everything that
falls through; the safe fallback becomes a function of what the user actually
speaks. `defaultRoute` would have to become configuration, and the bias
paragraph at the top of `RoutingPolicy.swift` would have to be rewritten as
"the default route is the user's primary language" rather than "Norwegian".

**3. Clusters must partition, and nothing enforces that.** `norwegianCluster`
claims `da` and `sv` on the argument that NB-Whisper is the right target for all
of them. A Danish route means taking `da` out of that set — and there is no
check that two clusters are disjoint, so overlapping sets would reintroduce
exactly the order-dependence of (1). A multi-route config needs a validating
initializer that rejects an overlap at construction.

### What it would actually cost

**A fourth warm pipeline.** Three load today (~42 + 500 + 488 MB of artifacts,
≈ 1 GB resident by the doc's estimate — itself not yet verified on a Mac, see
TODO.md). A third small route is ~+500 MB, so ≈ 1.5 GB. That is still fine on
16 GB and stops being fine on 8 GB, where two routes are already the ceiling.
The honest answer is that the binding constraint is probably not RAM but ANE
model residency: four compiled CoreML models competing for the ANE may mean the
route-switch path pays a reload that the current two-model steady state hides.
Nothing in the current instrumentation would show this — the `◐ route` line
times decode, which includes any reload without distinguishing it. **Before
adding a third route, split that timer**, and measure the second utterance after
a route switch, not the steady state.

**Startup gets stricter, not just slower.** `warmUp()` is concurrent and
atomic — all four load together, any failure aborts. The ≤ 1.5× single-model
budget assumes concurrency hides the extra loads; that assumption is
unverified at three and should not be extrapolated to four, since the loads
contend for the same compile path. Atomicity also gets more expensive: one
missing model out of four blocks startup entirely. Worth reconsidering whether
a *challenger* route failing should be fatal, or should just disable that route
and log it. (For the default route, fatal is still right.)

**Three-way LID is where the real risk is, and it depends on which language.**
The Scandinavian cluster currently absorbs tiny's most common confusion
harmlessly: `no`/`nn`/`da`/`sv` all land on NB-Whisper, so getting them
"wrong" costs nothing. A third route on a language tiny *doesn't* confuse with
Norwegian — German, French — is cheap, and the existing gate handles it. A
third route on Danish or Swedish is expensive: it converts a confusion that is
currently free into a user-visible wrong-model transcript, and no threshold
tuning recovers it, because the confusion is in the LID model. **So the cost of
a third route is not a function of the route count. It is a function of how
close the new language sits to Norwegian in tiny's language space.** If the
third language is Scandinavian, the prerequisite is a better LID model, not a
better policy.

**Tests.** The policy table grows combinatorially in the interesting direction —
each language now needs a case per competing route, not one. Two existing
assertions bake in two-ness and would flip:
`RoutingPolicyTests.swift:32` (`de` → default) and the `models.count == 3`
assertion at line 79. Integration fixtures grow by one language's worth.

## Future

- A third route: see the design note above — the plumbing generalizes, but the
  argmax fix, the configurable default route, and cluster-disjointness
  validation are prerequisites, not follow-ups.
- Upstream's `Engine` enum already anticipates Parakeet. FluidAudio/Parakeet
  v3 covers European languages including Norwegian; worth benchmarking against
  NB-Whisper before deepening the Whisper-only route (spec open question 3 —
  left open, does not block this feature).
