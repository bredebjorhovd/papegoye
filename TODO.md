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
- [x] Opt-in integration test scaffold (`PARROT_INTEGRATION=1`) + fixtures README
- [x] `scripts/convert-nb-whisper.sh` (convert, sanity-check layout, optional HF upload)
- [x] Docs: `docs/bilingual.md`, README + architecture updates

## Next — needs a Mac (Apple Silicon)

- [ ] `swift build` — first compile; fix any nits (written on Linux, unverified)
- [ ] `swift test --filter RoutingPolicyTests`
- [ ] Convert NB-Whisper: `scripts/convert-nb-whisper.sh small`
  - [ ] Verify output layout matches an `argmaxinc/whisperkit-coreml` model
  - [ ] Transcribe a Norwegian reference clip; diff against the PyTorch
        checkpoint (whitespace/punctuation drift OK, wording drift not)
  - [ ] Verify ANE residency with `sudo powermetrics --samplers ane_power`
        while transcribing — not just "it ran"
- [ ] Publish artifacts: `HF_UPLOAD_REPO=<owner>/nb-whisper-coreml scripts/convert-nb-whisper.sh small`
  - [ ] Confirm/rename `ModelRegistry.nbWhisperRepo` to the real repo id
- [ ] End-to-end smoke: `parrot --bilingual` — download, warm-up, dictate both languages
- [ ] Record fixtures with `--dump-wav` (no-bokmål, no-with-English-terms, en,
      short-ok, silence) → `Tests/fixtures/`
- [ ] `PARROT_INTEGRATION=1 swift test --filter RoutingIntegrationTests`

## Acceptance (spec §7/§9)

- [ ] Manual: 20 mixed utterances into a text field — ≥ 18 routed correctly,
      **zero** stock-Whisper-on-Norwegian outputs
- [ ] Latency: LID ≤ 30 ms on ANE for ≤ 10 s utterance (read from `◐ lid` logs)
- [ ] Latency: total routing overhead ≤ 80 ms p50 vs single-model parrot
- [ ] Startup: three-model warm start ≤ 1.5× current single-model warm start
- [ ] Memory: confirm ~1 GB resident is acceptable; else fall back to
      `--en-model whisper-base.en` and document
- [ ] Verify NB-Whisper silence output is caught by `sanitize()` on real
      silence captures; extend patterns if new markers show up

## Later / open

- [ ] Evaluate `nb-whisper-*-distil` variants if latency needs headroom
- [ ] Benchmark FluidAudio/Parakeet v3 (Norwegian-capable) vs NB-Whisper
      (spec open question 3)
- [ ] Consider tuning `--en-threshold` after real-world use (false-English rate)
- [ ] Third language route if ever needed — design allows another
      `(cluster, model)` pair
