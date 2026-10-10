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

`DotVoiceSourceMicrophone` and `DotVoiceSinkPlayer` need an audio device, so a headless run cannot exercise them, and a test that required one would fail on the machine it is meant to protect. The suite's last section (`_test_device_layer_is_not_covered`) prints that rather than leaving somebody to assume otherwise. A code path only one deployment shape reaches is a code path nothing has run: put on a headset before trusting either class.

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

## Privacy

**Nothing opens a microphone on its own**: not on ready, not because an exported default was true. `start_capture()` is an explicit call the host makes after the player has agreed, and it returns a `DotResult` the host can show. A game that records people because a node entered the tree records people who did not ask.

## Deliberately not here

- **Opus, echo cancellation, noise suppression.** All three are GDExtension work. The codec interface exists for the first; push-to-talk is why the other two are survivable.
- **A transport.** `send_fn` takes bytes.
- **A voice UI.** The signals a HUD needs are there.
- **Recording to disk.** A `DotVoiceSink` subclass is four methods.
