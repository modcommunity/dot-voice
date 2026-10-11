# dot-voice

Voice chat for Godot 4: capture, two codecs, a jitter buffer, and a server-side router that decides who hears whom. Devices sit behind an interface so the whole path runs headless.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to voice.

**The distributable is `addons/dot_voice/`.** It requires [dot-core](../dot-core) and nothing else. dot-moderation and dot-server are optional, and neither is named by any class in the source (mutes arrive through the `dot_mute_source` registry name).

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | anything: the device interface, the `AudioServer` trap, format fingerprint, codecs, wire format, jitter buffer, what the server decides, privacy, what is not here |
| [docs/history.md](docs/history.md) | touching the packet or the capability check: the 16-bit speaker id, the headless `is_supported()` |

## Layout

| Path | What |
| --- | --- |
| `capture/` | `DotVoiceSource` and its microphone and buffer sources; `DotVoiceGate` |
| `playback/` | `DotVoiceSink` (player, buffer), `DotVoiceJitter` |
| `codec/` | `DotVoiceCodec` registry, `pcm16`, `adpcm` (the default) |
| `wire/dot_voice_packet.gd` | `DotVoicePacket`: version 2, `OFFSET_*`, `sequence_delta` |
| `runtime/dot_voice_router.gd` | `DotVoiceRouter`: the server side; channels, mutes, rate limit, `team_fn`, `position_fn`, `can_hear_fn` |
| `runtime/dot_voice_manager.gd` | `DotVoiceManager`: the client side; `start_capture()`, playback, `local_mutes` |
| `dot_voice_config.gd` | `DotVoiceConfig`: sample rate, frame length, codec, `format_fingerprint()`, `frame_samples()` |
| `examples/voice_selftest.tscn` | the suite, no audio device needed |
| `examples/voice_device_probe.tscn`, `tools/voice_device_probe.sh` | the capture bus and the player sink on a real device, under Xvfb |
| `examples/web_voice_probe.tscn`, `examples/web_voice_server.gd`, `tools/web_voice_check.mjs` | voice in a real browser: export, fake microphone, Playwright |

Paths except `examples/` are in `addons/dot_voice/`.

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `godot --headless --path . res://examples/voice_selftest.tscn` (136 checks, including two clients over real WebSockets). The device layer is not in it: `tools/voice_device_probe.sh` runs it on a real ALSA device under Xvfb, and `node tools/web_voice_check.mjs` in Chromium with a fake microphone. [design](docs/design.md#the-device-layer-and-the-browser)

## Rules that bite

- Never test for a sound card with the mix rate or device list; only `get_driver_name() == "Dummy"` tells. [design](docs/design.md#audioserver-lies-about-having-a-sound-card)
- Exchange `format_fingerprint()` at handshake; a format mismatch is noise, not an error. `frame_samples()` is the only place frame length is computed. [design](docs/design.md#format-and-the-fingerprint)
- One decoder instance per speaker for a stateful codec (`instance_for()`); nothing outside `codec/` names a codec. [design](docs/design.md#codecs)
- Byte offsets live only in `DotVoicePacket.OFFSET_*`; sequence arithmetic only in `sequence_delta`. Bump `VERSION` on any layout change. [design](docs/design.md#the-wire-format)
- The jitter buffer starts on `target_frames`, continues on one, drops the oldest past `max_frames`, fades gaps, and resets on a talk spurt. [design](docs/design.md#the-jitter-buffer-is-where-voice-is-won-or-lost)
- Playback runs on a real-time accumulator, never the frame rate. [design](docs/design.md#the-jitter-buffer-is-where-voice-is-won-or-lost)
- The router stamps the speaker from the transport, checks mute before relaying without telling the speaker, rate-limits, never sends back to the speaker, and a team channel with no `team_fn` reaches nobody. [design](docs/design.md#what-the-server-decides-and-why-it-has-to-be-the-server)
- `can_hear_fn` keeps dot-chat's signature so one function answers both. [design](docs/design.md#what-the-server-decides-and-why-it-has-to-be-the-server)
- A moderator's mute (router, server) and `local_mutes` (listener) are different features. [design](docs/design.md#what-the-server-decides-and-why-it-has-to-be-the-server)
- Nothing opens a microphone except an explicit `start_capture()` after the player agreed; a client calls `update_talk(held)` every frame and the first press is that agreement (and the browser's user gesture). [design](docs/design.md#privacy)
- A project that wants a microphone sets `audio/driver/enable_input=true`; for a delivered game it is the client shell's setting that counts. [design](docs/design.md#the-device-layer-and-the-browser)
- `default_channel` is the channel every packet is relayed on; the packet's field is the client's and is ignored unless `honour_packet_channel`. [history](docs/history.md#every-game-chose-a-channel-and-every-game-got-everybody)
- `enabled` (`sv_voice_enable`) is enforced on the router; clients follow it through `follow_cvars(link)` and only hide their key. `bind_cvars(add, FLAG_REPLICATED)` on the authoritative router. [design](docs/design.md#the-servers-switch)
- Positional playback needs `speaker_position_fn`; without it voices are flat, never at the origin. [history](docs/history.md#every-voice-at-the-worlds-origin)
- Test with full-width peer ids, not 2 and 7. [history](docs/history.md#the-speaker-id-was-16-bits)

Deliberately not here: Opus, echo cancellation, noise suppression (GDExtension work), a transport (`send_fn` takes bytes), a voice UI, recording to disk. [design](docs/design.md#deliberately-not-here)
