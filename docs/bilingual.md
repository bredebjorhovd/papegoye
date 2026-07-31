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

## Future

- A third route slots in as another `(cluster, model)` pair in
  `RoutingPolicy`/`BilingualConfiguration` — the design doesn't preclude it.
- Upstream's `Engine` enum already anticipates Parakeet. FluidAudio/Parakeet
  v3 covers European languages including Norwegian; worth benchmarking against
  NB-Whisper before deepening the Whisper-only route (spec open question 3 —
  left open, does not block this feature).
