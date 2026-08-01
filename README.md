# parrot (papegøye fork)

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

This fork adds **bilingual Norwegian/English dictation**: hold Fn, speak either
language, and each utterance is routed automatically to
[NB-Whisper](https://huggingface.co/NbAiLab) (Norwegian) or stock Whisper
(English) via a fast language-identification pass on multilingual tiny.

```sh
parrot --bilingual
```

See [docs/bilingual.md](docs/bilingual.md) for the design, routing policy, and
NB-Whisper → CoreML conversion.

## Install

```sh
curl -fsSL https://digimata.github.io/parrot/install.sh | sh
parrot setup                       # grants mic + accessibility, downloads the model
parrot install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The installer drops the binary in `/usr/local/bin/parrot`. Builds are unsigned for now, so the installer strips the quarantine xattr — once you've inspected the script you'll see exactly what it does.

### Launch at login

`install --launch-at-login` writes a LaunchAgent to
`~/Library/LaunchAgents/com.digimata.parrot.plist`. The run flags you pass it
are forwarded into the agent, so the daemon starts the way you'd start it by
hand:

```sh
parrot install --launch-at-login --bilingual
parrot install --launch-at-login --bilingual --en-model whisper-small.en
parrot install --uninstall             # boots the agent out and deletes the plist
```

Model ids are checked when you install, not at next login — a bad `--no-model`
fails in your terminal instead of silently in `/tmp/parrot.err.log`.

A LaunchAgent inherits none of your shell environment, so if
`PARROT_NB_MODEL_FOLDER` is set when you install — pointing at a local
NB-Whisper conversion from `scripts/convert-nb-whisper.sh` — it is baked into
the plist's `EnvironmentVariables` and printed back to you. It is a snapshot:
move the model and you have to re-run `parrot install --launch-at-login`.

> This env-var half exists only until the converted NB-Whisper CoreML artifacts
> are published (#2). Once `nb-whisper-small` downloads from Hugging Face like
> every other model, nothing needs `EnvironmentVariables` and you can install
> without it.

## How to use

1. **Run it.** Either `parrot install --launch-at-login` (daemonized, runs forever, lives in the menu bar), or `parrot` in any terminal tab.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold the `fn` key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** when you release. Usually within 200-300ms.

That's it. There is no record button, no stop button, no "send" — `fn` is the whole interface.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to flip it back to plain `fn`.

## CLI

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time setup: permissions + model download
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --launch-at-login --bilingual   # ...running bilingual mode at login
parrot install --uninstall             # remove the LaunchAgent
parrot doctor                          # check permissions + fn key setting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot models download bilingual       # pre-download the bilingual model set
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --bilingual                     # per-utterance Norwegian/English routing
parrot --bilingual --en-model whisper-base.en --en-threshold 0.7   # tweak routes
parrot --hotkey right-option           # change the push-to-talk key
parrot --no-overlay                    # disable the bottom-of-screen pill
parrot bench warmup                    # time single-model vs bilingual startup
parrot bench lid                       # time language detection across utterance lengths
```

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```
