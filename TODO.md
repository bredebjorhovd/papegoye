# Bilingual dictation — task list

Tracking for the NB-Whisper + English routing work (see [docs/bilingual.md](docs/bilingual.md)
for the design). Check items off as they land; add follow-ups at the bottom.

## Done (this branch)

- [x] Import upstream `digimata/parrot` @ 62f8d98 as base
- [x] `RoutingPolicy` — pure `(language, confidence, duration) → route` function
  - [x] English gate `p(en) ≥ τ` (default 0.6, `--en-threshold`)
  - [x] `no/nn/da/sv` cluster → Norwegian route
  - [x] < 0.6 s utterances skip LID → default route
- [x] `RoutingTranscriber` actor behind the existing `Transcriber` protocol
  - [x] Three pipelines (tiny LID / NB / EN), concurrent warm-up
  - [x] Atomic startup failure naming the missing model
  - [x] LID confidence via `exp(langProbs[lang])` (spec open question 2 — resolved)
  - [x] 30 s LID window, LID-failure fallback to Norwegian
  - [x] stderr decision logging `◐ lid no 0.94 · 12ms` + per-stage timings
- [x] `TranscriptionModel.modelRepo` / `.modelFolder`; registry entries
      `nb-whisper-small`, `nb-whisper-base`, hidden `whisper-tiny`
- [x] CLI: `--bilingual`, `--no-model`, `--en-model`, `--en-threshold`,
      `models download bilingual`, `models list --all`, `doctor --bilingual`
- [x] Composite-as-flag decision (spec open question 1 — flag, not registry entry)
- [x] Silence gate: RMS < 0.003 skips LID + decode
- [x] Menu bar: `nb-small+en-small` title + last routing decision
- [x] Table-driven `RoutingPolicyTests` + sanitize tests
- [x] `parrot bench warmup` — warm-start harness (gh#12): cold + warm per
      configuration, ratio vs the 1.5× budget, per-model load spans, and a flag
      when the three concurrent warm-ups did not actually overlap
  - [x] `WarmUpProfileTests` — overlap analysis, median, ratio, report verdicts
  - [x] Refuses to measure when a model is missing (names it) — no warm start
        with a download folded into it
- [x] `parrot bench lid` — LID latency harness (gh#20): synthetic audio at
      several lengths, fixed-cost vs tracks-length verdict, optional pad / mel /
      encoder / decode split, budget verdict, JSON. No mic or fixtures needed.
  - [x] `LIDProfileTests` — signal generation, scaling verdict, budget scope,
        debug-build warning
  - [x] Reports which build it measured; refuses to call a debug run a verdict
- [x] Opt-in integration test scaffold (`PARROT_INTEGRATION=1`) + fixtures README
- [x] `scripts/convert-nb-whisper.sh` (convert, sanity-check layout, optional HF upload)
- [x] Docs: `docs/bilingual.md`, README + architecture updates

## Next — needs a Mac (Apple Silicon)

- [x] `swift build` — first compile on macOS; fixed `RoutingTranscriber.modelID`
      (actor-isolated, broke the `Transcriber` conformance) and a Swift 6
      captured-var warning in `Run.run()`. Clean, no warnings.
- [x] `swift test --filter RoutingPolicyTests` — 6/6 pass
- [x] CLI smoke: `--help`, `models list [--all]`, `run --help`, `doctor --bilingual`
- [x] Convert NB-Whisper: `scripts/convert-nb-whisper.sh small` — needed two
      fixes first (CPython ≤ 3.12 for `torch==2.5.0`; copy `config.json` +
      `generation_config.json` from the HF snapshot). See c8c218c.
  - [x] Verify output layout matches an `argmaxinc/whisperkit-coreml` model —
        all four required paths present; `config.json` is multilingual
        whisper-small (d_model 768, 12/12 layers, vocab 51865)
  - [x] **WhisperKit loads the converted folder** — `✓ nb-whisper-small ready`
        via `PARROT_NB_MODEL_FOLDER`. Tokenizer resolution for a model id
        WhisperKit does not know was the open risk; it is not a problem.
  - [ ] Transcribe a Norwegian reference clip; diff against the PyTorch
        checkpoint (whitespace/punctuation drift OK, wording drift not)
  - [ ] Verify ANE residency with `sudo powermetrics --samplers ane_power`
        while transcribing — not just "it ran"
- [x] Publish artifacts — `Barrymanalow/nb-whisper-coreml`, public, 21 files.
      Uploaded the already-converted folder directly rather than re-running the
      script, which would have reconverted from scratch.
  - [x] `ModelRegistry.nbWhisperRepo` set to the real repo id. The HF account is
        `Barrymanalow`, not the GitHub handle — the placeholder guessed wrong,
        which is what the 403 on repo creation was.
  - [x] Verified as a fresh user would: `PARROT_NB_MODEL_FOLDER` unset, no
        cached copy, `parrot models download nb-whisper-small` → `✓ ready`
        (465 MB fetched to ~/Documents/huggingface). Anonymous HTTP 200 on
        config.json, so no token is needed to consume it.
- [ ] End-to-end smoke: `parrot --bilingual` — download, warm-up, dictate both languages
- [ ] Record fixtures with `--dump-wav` (no-bokmål, no-with-English-terms, en,
      short-ok, silence) → `Tests/fixtures/`
- [ ] `PARROT_INTEGRATION=1 swift test --filter RoutingIntegrationTests`

## Acceptance (spec §7/§9)

- [ ] Manual: 20 mixed utterances into a text field — ≥ 18 routed correctly,
      **zero** stock-Whisper-on-Norwegian outputs
- [ ] Latency: LID ≤ 30 ms on ANE for ≤ 10 s utterance (read from `◐ lid` logs)
      — **open and FAILING, now reproducibly.** ~52 ms against a 30 ms budget.
      - `parrot bench lid` (2026-07-31, gh#20): release build 15.4 ms median,
        PASS; the same sweep from a `swift build` debug binary gives ~52 ms.
        The CoreML encoder costs 6.1-6.2 ms in both — only the Swift half of
        the call changes. Latency is a fixed cost (1.17× spread over 30×
        utterance length), so a shorter LID window buys nothing: WhisperKit
        pads back to the model's own 30 s window. Default window unchanged.
      - `parrot bench lid --arms all --gap 10 --observed 52` (2026-08-12,
        gh#25): that PASS did not survive contact with the daemon, and the
        bench now says why. **The cost is the time since the previous LID
        call**, not resident models and not the call path. Back to back LID is
        ~20 ms; with 10 s of idle in front of each call it is ~52 ms, matching
        the live daemon's 46-74 ms from synthetic audio alone. Holding all
        three models resident costs 0.9 ms (3% of the gap) and the daemon's
        call path is below run-to-run spread — so **the ANE-contention
        hypothesis is not supported**, and it is not an argument against the
        memory item or a third route.
      - Still needs a mic (capture teardown is the one gh#25 candidate the
        bench cannot reach) and powermetrics for the "on ANE" half. The
        mechanism behind the idle cost — ANE clock ramp, cache eviction, or
        CoreML re-entry — is not distinguishable from wall-clock timings.
      - Lead for a fix, not done here: the daemon knows the user is recording
        before it needs LID, so a keep-alive call on hotkey-down would land
        the pipeline in its ~20 ms state by the time recording stops.
- [ ] Latency: total routing overhead ≤ 80 ms p50 vs single-model parrot
- [x] Startup: three-model warm start ≤ 1.5× current single-model warm start —
      **1.31×, PASS** (`parrot bench warmup --iterations 3`, release build,
      2026-07-31). single-model `whisper-base.en` warm 3.781s; bilingual
      `whisper-tiny + nb-whisper-small + whisper-small.en` warm 4.944s.
      Overlap efficiency 1.00 — the three `async let` warm-ups genuinely run
      concurrently rather than degrading into a chain of awaits.
      Warm numbers only; cold-from-boot needs `sudo purge` first.
      (First recorded as 1.11× from a debug build. Same lesson as gh#20:
      quote the build, or the number is not an acceptance result. Debug
      flattered the ratio here rather than hurting it.)
- [ ] Memory: confirm ~1 GB resident is acceptable; else fall back to
      `--en-model whisper-base.en` and document. gh#25 settles one half of
      this: holding all three models resident costs the LID pass 0.9 ms, so
      **latency is not an argument for shrinking the resident set** — decide
      this on memory alone.
- [ ] Verify NB-Whisper silence output is caught by `sanitize()` on real
      silence captures; extend patterns if new markers show up

## Later / open

- [ ] Evaluate `nb-whisper-*-distil` variants if latency needs headroom
- [ ] LID accuracy vs window length — **not worth running as things stand.**
      gh#20 asked for it before proposing a shorter `lidWindowSamples`, but a
      shorter window has no latency to buy: WhisperKit pads every LID input
      back up to the model's own 30 s mel window. The experiment only becomes
      meaningful if someone converts a short-window mel + encoder pair, and it
      would then need labelled Norwegian/English speech, not synthetic audio.
- [ ] Benchmark FluidAudio/Parakeet v3 (Norwegian-capable) vs NB-Whisper
      (spec open question 3)
- [ ] Consider tuning `--en-threshold` after real-world use (false-English rate)
- [x] Third language route — design note written up in `docs/bilingual.md`
      ("Design note: a third route"). Plumbing generalizes; three prerequisites
      identified (argmax over cleared gates, configurable default route,
      cluster-disjointness validation). No code change.
  - [x] Argmax over cleared gates (#18) — `route()` is a `[Gate]` table plus an
        argmax over the LID softmax, no longer an order-dependent if-chain
  - [ ] Make `defaultRoute` configuration rather than a hardcoded Norwegian
  - [ ] Reject overlapping clusters at construction
