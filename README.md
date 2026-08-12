# 🦜🦜🦜 Papegøye (Parrot fork)

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

Fork of [Parrot](https://github.com/digimata/parrot) (© 2026 Andrew Jones) — this repo is `digimata/parrot` plus bilingual Norwegian/English routing.

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

Download the latest release into a directory on your `PATH` — `~/.local/bin`
needs no `sudo`:

```sh
mkdir -p ~/.local/bin
curl -fsSL https://github.com/bredebjorhovd/papegoye/releases/latest/download/parrot-macos-arm64.tar.gz \
  | tar xz -C ~/.local/bin

parrot setup                                    # mic + accessibility permissions
parrot --bilingual                              # first run downloads the models
parrot install --launch-at-login --bilingual    # optional — starts at login
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on
the Apple Neural Engine via CoreML, so Intel is not supported.

First run downloads three models (~1 GB total): multilingual `whisper-tiny` for
language identification, [`nb-whisper-small`](https://huggingface.co/Barrymanalow/nb-whisper-coreml)
for Norwegian, and `whisper-small.en` for English. No account or token needed.

Models are cached in `~/Library/Application Support/parrot/models`. Versions up
to v0.3.0 used `~/Documents/huggingface` instead — WhisperKit's default — which
iCloud syncs and evicts if you have "Desktop & Documents Folders" turned on;
evicted weights break bilingual warm-up with *Resource deadlock avoided*
(#34). Your existing cache keeps working where it is; `parrot models migrate`
moves it, and `parrot doctor` warns when it needs moving.

### A note on the unsigned binary

Releases are unsigned and un-notarized. The `curl` command above is unaffected —
`curl` does not set the quarantine attribute, so the binary runs as-is.

If you download the tarball **through a browser** instead, macOS quarantines it
and refuses to run it. macOS 15 removed the old Control-click → Open bypass, so
either clear the attribute:

```sh
xattr -d com.apple.quarantine ~/.local/bin/parrot
```

or approve it once under System Settings → Privacy & Security → *Open Anyway*.

Because the binary is unsigned, macOS identifies it by path and contents — so
**replacing it on upgrade usually means re-granting Accessibility** under
System Settings → Privacy & Security → Accessibility. `parrot doctor` recognises
that case and says so, instead of reporting a plain "not granted". A local build
can avoid it entirely: see [Build a signed `Papegøye.app`](#build-a-signed-papegøyeapp-37).

### If the accessibility prompt never appears

macOS offers that prompt at most once per app, so on a machine where it was
already dismissed — or over SSH, where it can't appear at all — `parrot setup`
skips the wait, opens Privacy & Security → Accessibility for you, and names the
app to toggle. That app is your *terminal* (Terminal, iTerm, Ghostty…), not
parrot: the grant follows whatever launched parrot. Setup keeps watching while
you flip the switch and continues on its own, so there is nothing to re-run.

The exception is when nothing GUI launched parrot — the LaunchAgent, or opening
`Papegøye.app` yourself. Then parrot *is* the subject, and the entry to enable
is **Papegøye** (or the bare binary, if you run an unsigned build).

### Build from source instead

```sh
git clone https://github.com/bredebjorhovd/papegoye.git
cd papegoye && swift build -c release
cp .build/release/parrot ~/.local/bin/parrot
```

Building locally sidesteps quarantine entirely — but see the next section for
the version that also keeps its permissions.

### Build a signed `Papegøye.app` (#37)

A grant in Privacy & Security is keyed to a code signature, and an unsigned
binary's signature is its own contents: every rebuild is a different program, so
Accessibility is dropped and a fresh, indistinguishable row appears in the list.
Signing with a certificate that outlives the build fixes that, and it does not
need a paid developer account.

```sh
make install                                   # build, sign, install the .app
parrot install --launch-at-login --bilingual   # re-point the agent at the bundle
```

`make install` puts `Papegøye.app` in `~/Applications` and links
`~/.local/bin/parrot` at the binary inside it, so the CLI is unchanged — macOS
resolves the symlink before it looks at the signature, which means the command,
the daemon and the Accessibility row are all one identity. Override the
locations with `APP_DIR=` / `BIN_DIR=`.

The certificate is discovered, never hardcoded — `security find-identity -v -p
codesigning`, since the hash differs per machine and certificates expire. A free
Apple ID gives you an *Apple Development* certificate (Xcode → Settings →
Accounts → Manage Certificates → +), which is all this needs; pick a specific
one with `CODESIGN_IDENTITY=...`.

**What it buys.** Rebuild, `make install` again, and the Accessibility grant is
still there with no second row — the whole point. `make verify` proves the
mechanism without a click: it rebuilds and asks `codesign` whether the new build
still satisfies the requirement recorded for the installed one, which is the
test TCC itself makes.

To see the other half for yourself:

```sh
make install
open ~/Applications/Papegøye.app     # adds a Papegøye row to Accessibility
                                     # → turn it on in System Settings
launchctl kickstart -k gui/$(id -u)/com.digimata.parrot
parrot doctor                        # launch agent: running (pid …)

# now rebuild and do it again
make install
launchctl kickstart -k gui/$(id -u)/com.digimata.parrot
parrot doctor                        # still running, and still one row
```

**What it does not buy.** Anything for anyone else: an Apple Development
certificate is not trusted on another Mac and the app is not notarized, so
distributing to other people is still #36. It also does not skip the *first*
grant — moving from an unsigned binary to the app changes the identity once, so
Accessibility has to be granted one last time. It appears as **Papegøye**, under
its own name and icon, rather than as a path.

**When the certificate expires** — Apple Development certificates last a year,
and `parrot doctor` prints the date — the next build signs under an identity
macOS has not seen, which costs exactly one re-grant. Renew it in Xcode →
Settings → Accounts → Manage Certificates, rebuild, toggle it once.

```sh
make app        # build and sign into build/Papegøye.app, install nothing
make identity   # what TCC sees: identifier, team, requirement, expiry
make uninstall  # remove the app and the symlink
```

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

When parrot is installed as `Papegøye.app`, the plist names the binary *inside*
the bundle rather than the symlink on your `PATH` — that is the program the
Accessibility grant belongs to, and pointing anywhere else installs a daemon
macOS will never trust.

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

The agent never opens a permission dialog: nobody typed the command, so nobody
is waiting to answer one. If Accessibility is missing — most often after an
upgrade replaced the binary — the daemon says so in `/tmp/parrot.err.log` and
**stops**, rather than letting launchd restart it into a permission it cannot
obtain by retrying. `parrot doctor` reports that state under `launch agent`.
Grant it from a terminal with `parrot setup`, then start the agent again:

```sh
launchctl kickstart -k gui/$(id -u)/com.digimata.parrot
```

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
parrot models migrate                  # move a pre-v0.3.1 cache out of ~/Documents
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --bilingual                     # per-utterance Norwegian/English routing
parrot --bilingual --en-model whisper-base.en --en-threshold 0.7   # tweak routes
parrot --hotkey right-option           # change the push-to-talk key
parrot --no-overlay                    # disable the bottom-of-screen pill
parrot --input-device "Shure MV7"      # record from a specific microphone
parrot --input-device default          # record from the system default, Bluetooth and all
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
