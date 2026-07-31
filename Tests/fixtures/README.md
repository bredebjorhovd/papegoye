# Test fixtures

Fixture WAVs for `RoutingIntegrationTests` — 16 kHz mono 16-bit PCM, exactly
what `parrot --dump-wav` writes to `/tmp/parrot-last.wav`. Record an utterance,
then copy the dump here under a prefix that encodes the expectation:

| prefix        | content to record                              | asserted |
|---------------|------------------------------------------------|----------|
| `no-*.wav`      | Norwegian bokmål; also one with English tech terms ("deploye Kubernetes-clusteret") | routes to NB-Whisper, non-empty transcript |
| `en-*.wav`      | English                                        | routes to English Whisper, non-empty transcript |
| `short-*.wav`   | < 0.6 s — "ok", "nei"                          | LID skipped, Norwegian route |
| `silence-*.wav` | hold Fn, say nothing                           | empty transcript after sanitize |

WAVs are not committed (see `.gitignore`); they're personal voice recordings.
Run with:

```sh
PARROT_INTEGRATION=1 swift test --filter RoutingIntegrationTests
```
