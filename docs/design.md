# Design

Why dot-voice is shaped the way it is. The one-line rules are in [CLAUDE.md](../CLAUDE.md).

## The devices are behind an interface

**That is why there is a test suite.** A voice addon whose only input is a real microphone can be exercised by a person wearing headphones and by nothing else: no headless suite, no bot, no regression test. So:

```
DotVoiceSource  -> DotVoiceSourceMicrophone   AudioEffectCapture on its own bus
                -> DotVoiceSourceBuffer       samples a test wrote

DotVoiceSink    -> DotVoiceSinkPlayer         AudioStreamGenerator, flat or positional
                -> DotVoiceSinkBuffer         keeps what a listener would have heard
```

`examples/voice_selftest.tscn` runs with **no audio device in the process**, and everything between the two ends is the code a player runs. It is the same shape and reasoning as dot-player-controller's `DotFpsSampler`: devices, bots and demo playback behind one interface.

## The device layer is not covered, and that is said out loud

`DotVoiceSourceMicrophone` and `DotVoiceSinkPlayer` need an audio device, so a headless run cannot exercise them, and a test that required one would fail on the machine it is meant to protect. The suite's last section (`_test_device_layer_is_not_covered`) prints that rather than leaving somebody to assume otherwise, and names the two checks below that do run them.

### The device layer and the browser

- **`tools/voice_device_probe.sh`** runs under `xvfb-run`, where the driver is ALSA rather than Dummy. Godot's ALSA driver has **no input at all** (only PulseAudio, WASAPI, CoreAudio and the web driver implement `input_start`), so on a Linux box without PulseAudio no microphone can open. The probe plays a 440 Hz tone into the capture bus instead (`DotVoiceSourceMicrophone.input_stream`); everything after the driver's input runs as for a person: the capture effect at the engine's mix rate, resampling to the wire rate, the encoder, two clients and a router on real WebSockets, and a `DotVoiceSinkPlayer` on the device. It measures the pitch at the far end, because a capture read at the wrong rate is loud and wrong.
- **`node tools/web_voice_check.mjs`** exports `examples/web_voice_probe.tscn` with the no-threads web template (the one the client shell uses), serves it, runs `examples/web_voice_server.gd` natively with a bot that talks a tone, and drives Chromium with its fake microphone through Playwright. It asserts the page makes **no `getUserMedia` call before V is pressed**, that holding V asks for it, that the browser's speech reaches the native bot through the server, and that the bot's speech plays in the page. Measured 2026-10-11: AudioWorklet driver at 48 kHz, all of it working.
- **The web needs three things a game does not control from GDScript.** `audio/driver/enable_input=true` in the exported project (for a delivered game, the client shell's `project.godot`); a secure context (https, or localhost); and, when the page is framed, the frame must be allowed the microphone: the parent's `Permissions-Policy` must delegate `microphone` to the frame's origin and the `<iframe>` must carry `allow="microphone"`. Without the last two the browser refuses `getUserMedia` and the capture reads silence.
- **Both players are streams** (`playback_type = PLAYBACK_TYPE_STREAM`): a browser build plays samples by default, and neither a generator nor a microphone can be one.

### `AudioServer` lies about having a sound card

The first `DotVoiceSourceMicrophone.is_supported()` checked the mix rate and the input device list, and **passed in a headless run**. Measured headless:

| | headless |
| --- | --- |
| `get_mix_rate()` | 44100.0 |
| `get_input_device_list()` | `["Default"]` |
| `get_output_latency()` | 0.0 |
| `get_driver_name()` | **`"Dummy"`** |

Everything except the driver name looks like a working sound card. A check built on any of the others passes on a machine with no audio, and the symptom is a capture that returns silence for ever with nothing reporting a problem. The driver name is the only reliable tell, and it is a capability question rather than a platform one: equally true of CI, a dedicated server and a desktop started with `--audio-driver Dummy`.

## Format, and the fingerprint

Sample rate, frame length and codec must match on both ends. A mismatch is **not an error**: a decoder reading ADPCM as PCM produces noise, and reading a 20 ms frame as a 40 ms one produces speech at half speed. Both read as a broken microphone. `DotVoiceConfig.format_fingerprint()` is one number to exchange at handshake, so all of that becomes one refusal.

`frame_samples()` is the only place `rate * ms / 1000` is computed. Two places doing it differently is a decoder reading one frame's worth of samples out of a packet holding another's.

## Codecs

| | Bytes per 480-sample frame | |
| --- | --- | --- |
| `pcm16` | 960 | Exact, stateless. The reference every other codec is checked against, and the right choice on a LAN. |
| `adpcm` | 244 | Four bits a sample. **The default**, because at 24 kHz PCM is 48 kB/s per speaker and a twenty-slot server with four people talking is 3.6 MB/s of upstream against 900 kB/s. |

**ADPCM carries its own starting state in a four-byte preamble.** Without it one lost packet desynchronises the decoder until the speaker stops talking.

**Every speaker needs their own decoder instance.** `DotVoiceCodec.instance_for()` hands out a private one for a stateful format and shares one for a stateless format. Two speakers through one ADPCM decoder interleave their predictors and both come out as noise.

Godot exposes no Opus encoder to GDScript. `DotVoiceCodec.register()` is how a GDExtension codec gets used, and nothing else in the addon names a codec.

## The wire format

`DotVoicePacket` is version 2: the speaker field is 32 bits, because a Godot peer id is 31 ([history](history.md#the-speaker-id-was-16-bits)). The byte offsets are `DotVoicePacket.OFFSET_*`, used by the encoder, the decoder and the suite, because two copies of one list is the family's most repeated bug. A version bump makes an old build refuse a new packet rather than misread it.

## The jitter buffer is where voice is won or lost

- **Ordering.** UDP reorders. Playing in arrival order is worse than dropping the late frame, because a syllable in the wrong place is a different word.
- **The wrap.** Sequence numbers are 16 bits. `DotVoicePacket.sequence_delta` is the only place that arithmetic happens; frame 0 after frame 65535 is one frame later, not 65535 earlier.
- **Growth.** A sender arriving faster than real time adds delay for ever. Past `max_frames` the **oldest** go, because the newest are the ones somebody is waiting for.
- **Gaps.** A missing frame is filled by fading the previous one, not by silence. A hard cut to zero is a step edge and clicks; repeating the frame unchanged buzzes.

**Starting takes `target_frames`; continuing takes one.** A buffer that re-applied the start condition every frame would stall for the whole target on every late packet.

**The talk-spurt flag is load-bearing.** A speaker who pauses and resumes lands in a buffer still holding their old sequence numbers, so every new frame looks impossibly late and is discarded. Without `starts_talk_spurt` they are inaudible until the sequence wraps, which at 50 frames a second is twenty-two minutes.

**Playback is driven by an accumulator, not the frame rate.** A 144 Hz client would drain a 50-frames-a-second stream almost three times too fast, empty the buffer and stutter for ever. `DotVoiceManager._pump_playback` advances in real time regardless of the display, the same reason dot-net counts ticks.

## What the server decides, and why it has to be the server

A client asking another client not to play a muted player is not muting anybody, because the muted player's own client would have to cooperate. `DotVoiceRouter` runs on the server:

- **The speaker id is stamped from the transport**, never read from the packet. A client that could name its own speaker id could put words in anyone's mouth.
- **Mute is checked before relaying**, and a muted speaker is **not told**: telling them is spam fifty times a second, and it tells them exactly when a moderator acted. Mutes come from whatever is registered as `dot_mute_source` (dot-moderation publishes it); anything with `is_voice_muted(speaker) -> bool` answers.
- **The rate limit is the amplifier control.** One speaker is relayed to every listener, so a client sending ten times the expected rate costs ten times that multiplied by the player count.
- **A team channel with no `team_fn` reaches nobody, not everybody.** A team channel that leaks to the other team sounds exactly like working, so nobody reports it.
- **A range is not a room.** `can_hear_fn(listener, speaker, listener_at, speaker_at) -> bool` is asked on `PROXIMITY` after the squared-distance test, only about listeners in range, with the positions `position_fn` produced. The host's level decides what blocks sound; this addon knows positions and must not learn walls. It has dot-chat's `DotChatRouter.can_hear_fn` signature on purpose, so one function answers both and nobody reads a line from somebody they cannot hear. The suite's "the server decides who hears whom" section is armed: with the call disabled, both of its checks fail.
- **Never back to the speaker.** Hearing yourself at a round trip's delay is the most disorienting thing a voice system can do.

**A moderator's mute and a player's own mute list are different features.** `DotVoiceRouter` enforces the first on the server; `DotVoiceManager.local_mutes` applies the second on the listener's machine. Conflating them gives a punishment the punished player can decline.

## The server's switch

`DotVoiceRouter.enabled` is the operator's `sv_voice_enable` and `forced_channel` their `sv_voice_mode` (0 the game decides, 1 everybody, 2 team, 3 nearby). `bind_cvars(add, flags)` registers both through a module's `add_cvar`, in dot-combat's duck-typed shape, and reads back a value set before it ran (argv, the deploy's `content.yml`). **Off is enforced on the router**: a client told voice is off stops capturing and hides its key, but a modified client keeps sending, and only the relay can make "off" mean off. A refused frame is counted (`refused_disabled`) and the speaker is not told, as with a mute. Registered with dot-server's `FLAG_REPLICATED`, the value reaches every client's `DotClientLink`, and `DotVoiceManager.follow_cvars(link)` turns it into `server_enabled` and `server_enabled_changed`.

**The game's channel is the router's, not the packet's.** `default_channel` is what every packet is relayed on, and the mode overrides it. The packet's channel field is written by the client, so a team-only game that trusted it was team-only for every player who did not change one byte; `honour_packet_channel` is for a game that gives players a team key and an all key.

## Privacy

**Nothing opens a microphone on its own**: not on ready, not because an exported default was true. `start_capture()` is an explicit call the host makes after the player has agreed, and it returns a `DotResult` the host can show. A game that records people because a node entered the tree records people who did not ask.

**The first press of the talk key is the agreement.** A client calls `DotVoiceManager.update_talk(held)` every frame (`is_talk_held()` reads the `dot_voice_talk` action, V when nothing bound it); the first press opens the microphone and later presses gate it. In a browser that is also when the permission prompt appears, attached to the key the player just pressed rather than to a page load, and a key press is the user gesture a browser wants before it starts audio. Open-mic mode (`set_open_mic`) opens on the same first press and then stays open. A refusal is returned on the first frame of a press and not on the rest of it. The microphone stays open once opened: reopening it per press costs the driver's start-up on every word.

## Deliberately not here

- **Opus, echo cancellation, noise suppression.** All three are GDExtension work. The codec interface exists for the first; push-to-talk is why the other two are survivable.
- **A transport.** `send_fn` takes bytes.
- **A voice UI.** The signals a HUD needs are there.
- **Recording to disk.** A `DotVoiceSink` subclass is four methods.

## Proximity and gagging

The router computes a gain per listener (`DotVoiceProximity.gain`: full inside `sv_voice_proximity_min`, zero at `sv_voice_proximity_range`, linear, inverse or quadratic between) and sends a packet only to listeners above zero, which is the bandwidth saving. The gain rides in bits 1..7 of the flags byte, so the wire version is unchanged and an older client plays at full volume. A wall between two players multiplies it by `sv_voice_proximity_occlusion_gain` when `sv_voice_proximity_occlusion` is on and the game set `occlusion_fn` (`DotVoiceProximity.ray_occluder` is one ray per listener in range). With `honour_packet_channel` and proximity as the game's mode, the team and everybody channels are exempt only when their bypass cvar says so.

`DotVoiceLookMute` is the client half: the host gives it `target_fn` (who is looked at; `pick_by_angle` is a ready one), a tap on `voice_gag` gags, a second tap inside `double_tap_ms` reverts the gag and toggles a mute (voice, plus chat through `chat_mute_fn`), or `separate_keys` gives each its own action. The server only says whether it is allowed and whether everybody starts gagged. Playback positional attenuation of the engine's player stacks with the server gain; a game using both should leave `positional_playback` for panning only.

## Snippets

Plugging in a codec (an Opus GDExtension, say): subclass and register; nothing else in the addon names a codec except through `DotVoiceCodec.for_id`.

```gdscript
class MyOpusCodec extends DotVoiceCodec:
    func id() -> StringName: return &"opus"
    func encode(samples: PackedFloat32Array) -> PackedByteArray: ...
    func decode(bytes: PackedByteArray, count: int) -> PackedFloat32Array: ...

DotVoiceCodec.register(MyOpusCodec.new())
```

Adding the manager to a game (nothing opens a microphone until `start_capture`):

```gdscript
var voice := DotVoiceManager.new()
voice.config = my_config
voice.send_fn = func(bytes: PackedByteArray) -> void: link.send_voice(bytes)
add_child(voice)

await voice.start_capture()          # only once the player has agreed
voice.set_talking(Input.is_action_pressed("voice"))
```

Packet header (`DotVoicePacket`, version 2): byte 0 version, 1 flags (bit 0 start of spurt, bits 1..7 gain), 2-5 speaker (u32), 6-7 sequence (u16, wraps), 8-9 sample count, 10 channel, 11 codec index (255 then a length-prefixed name), then the payload. The speaker is there because a relayed packet's transport sender is the server; sequence because UDP reorders; sample count because a decoder that guesses plays at the wrong speed; channel to pick the gain; codec because a mismatch is silent noise.
