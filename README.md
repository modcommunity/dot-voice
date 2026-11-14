# dot-voice

Voice chat for Godot 4: microphone capture with push-to-talk or voice activation, a pluggable codec, one jitter buffer per speaker, and routing to everybody, to a team, or to whoever is close enough. The server decides who is heard.

## Install

1. Get [Godot 4.7](https://godotengine.org/download).
2. Either use [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap), which clones every project and links the addons, or copy `addons/dot_voice/` and [dot-core](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project and enable dot-voice in *Project > Project Settings > Plugins*.
3. Set `audio/driver/enable_input=true` in your project settings.

dot-core is the only dependency. [dot-moderation](https://github.com/modcommunity/dot-moderation) and [dot-server](https://github.com/modcommunity/dot-server) work with it and neither is imported.

## What you get

| Part | What it does |
| --- | --- |
| Capture | Push-to-talk, or voice activation with hysteresis and a hangover so words are not clipped. |
| Codecs | `pcm16` (exact) and `adpcm` (a quarter of the bandwidth). Register your own, such as an Opus GDExtension. |
| Wire | A ten-byte header carrying speaker, sequence, frame length, channel and codec. Every field is bounds-checked. |
| Playback | A jitter buffer per speaker that reorders, drops duplicates and fades over a lost frame. |
| Routing | All, team, proximity, or a filter you write, decided on the server. |
| On and off | `sv_voice_enable` and `sv_voice_mode` server cvars (`DotVoiceRouter.bind_cvars`), enforced on the relay. |
| Browser | Works in a web export. The microphone is asked for on the first press of the talk key. |
| Muting | A moderator's mute is enforced on the server; a player's own mute list is applied on their machine. |

## Things worth knowing

- **Nothing opens a microphone on its own.** Call `update_talk(held)` every frame. The first press of the talk key opens the microphone, which is the player agreeing, and in a browser is when the permission prompt appears.
- **Both ends must agree on the format**: sample rate, frame length and codec. `DotVoiceConfig.format_fingerprint()` is one number to exchange at handshake.
- **Devices sit behind an interface.** `DotVoiceSource` and `DotVoiceSink` have a real and a buffer implementation, so the tests run the whole path without an audio device.

## Settings

`DotVoiceConfig` holds them. Defaults:

| Setting | Default | Meaning |
| --- | --- | --- |
| `frame_ms` | 20 | Frame length. |
| `codec_id` | `adpcm` | Codec. |
| `capture_enabled` | false | Capture is off until you turn it on. |
| `push_to_talk` | true | Otherwise voice activation. |
| `activation_rms` | 0.02 | Level that opens the gate in voice activation. |
| `hangover_ms` | 250 | How long the gate stays open after speech. |
| `input_gain`, `output_gain` | 1.0 | Volume. |
| `jitter_ms` | 60 | Playback delay used to smooth out network jitter. |
| `jitter_max_ms` | 400 | Most the jitter buffer may grow. |
| `proximity_range` | 40 | Metres, in proximity mode. |
| `max_bytes_per_second` | 4096 | Per speaker, on the relay. 0 = unlimited. |

## Where a game plugs in

| To change | Where |
| --- | --- |
| Where bytes go | `DotVoiceManager.send_fn`, `DotVoiceRouter.send_fn` |
| Where audio comes from | A `DotVoiceSource` subclass |
| Where audio goes | A `DotVoiceSink` subclass, or `DotVoiceManager.sink_factory` |
| The codec | A `DotVoiceCodec` subclass plus `DotVoiceCodec.register` |
| Who hears whom | `DotVoiceRouter.team_fn`, `position_fn`, `can_hear_fn`, `listener_filter` |
| Who may be heard at all | Anything with `is_voice_muted(peer)` registered as `dot_mute_source` |

## Not included

- Opus: Godot exposes no Opus encoder to GDScript, so the codec interface is there for a GDExtension.
- Echo cancellation and noise suppression.
- A voice UI. `talking_changed`, `speaker_changed` and `input_level()` are what a HUD needs; see [dot-ui](https://github.com/modcommunity/dot-ui).
- A transport. `send_fn` takes bytes; putting them on a wire is the host's job, as in [dot-net](https://github.com/modcommunity/dot-net).
- A Linux microphone without PulseAudio: Godot's ALSA driver has no input.

## Testing

Link dot-core into `addons/`, import the project once, then run `examples/voice_selftest.tscn` headless with Godot. `tools/voice_device_probe.sh` tests a real audio device under Xvfb, and `tools/web_voice_check.mjs` runs a real browser with a fake microphone.

## Status and licence

Part of the TMC **dot-\*** family of Godot addons. Written with Claude Code and maintained by `gamemann`. Every addon has headless tests, but little of this has been played by real users yet, so expect rough edges and please [open an issue](https://github.com/modcommunity/dot-voice/issues) when you hit one.

MIT licence, see [LICENSE](LICENSE). The only closed part of the TMC platform is the web back end; you can use your own instead of TMC's.
