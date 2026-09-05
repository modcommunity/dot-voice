# dot-voice

Voice chat for Godot 4.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first. This file
is only what is specific to voice.

**Only dot-core is a dependency.** dot-moderation and dot-server are both optional and
neither is named anywhere in the source.

## The decision everything else follows from

**The audio devices are behind an interface, and that is why there is a test suite.**

A voice addon whose only input is a real microphone can be exercised by a person wearing
headphones and by nothing else: no headless suite, no bot, no regression test, and every
bug found the way this family's bugs get found, which is expensively and late. So:

```
DotVoiceSource  -> DotVoiceSourceMicrophone   AudioEffectCapture on its own bus
                -> DotVoiceSourceBuffer       samples a test wrote

DotVoiceSink    -> DotVoiceSinkPlayer         AudioStreamGenerator, flat or positional
                -> DotVoiceSinkBuffer         keeps what a listener would have heard
```

`examples/voice_selftest.tscn` runs 99 checks with **no audio device in the process**,
and everything between the two ends is the code a player runs. It already found a bug in
this addon's own capability check, described below.

Same shape and same reasoning as `DotFpsSampler`: input devices, bots and demo playback
behind one interface.

## The device layer is not covered, and that is said out loud

`DotVoiceSourceMicrophone` and `DotVoiceSinkPlayer` need an audio device, so a headless
run cannot exercise them and a test that required one would fail on the machine it is
meant to protect. The suite's last section prints that rather than leaving somebody to
assume otherwise.

**This family's own rule applies:** a code path only one deployment shape reaches is a
code path nothing has run. Put on a headset before trusting either class.

### `AudioServer` lies about having a sound card

The first version of `DotVoiceSourceMicrophone.is_supported()` checked the mix rate and
the input device list, and **passed in a headless run**. Measured:

| | headless |
| --- | --- |
| `get_mix_rate()` | 44100.0 |
| `get_input_device_list()` | `["Default"]` |
| `get_output_latency()` | 0.0 |
| `get_driver_name()` | **`"Dummy"`** |

Everything except the driver name looks exactly like a working sound card. A check built
on any of the others passes on a machine with no audio at all, and the symptom is a
capture that returns silence for ever with nothing anywhere reporting a problem. The
driver name is the only reliable tell, and it is a capability question rather than a
platform one: it is equally true of CI, of a dedicated server, and of a desktop started
with `--audio-driver Dummy`.

## Format, and the fingerprint

Sample rate, frame length and codec must match on both ends. A mismatch is **not an
error**: a decoder reading ADPCM as PCM produces noise, and reading a 20 ms frame as a
40 ms one produces speech at half speed. Neither errors, and both read as a broken
microphone.

`DotVoiceConfig.format_fingerprint()` is one number to exchange at handshake, so all of
that becomes one refusal.

`frame_samples()` is the only place `rate * ms / 1000` is computed. Two places doing it
differently is a decoder reading one frame's worth of samples out of a packet holding
another's.

## Codecs

| | Bytes per 480-sample frame | |
| --- | --- | --- |
| `pcm16` | 960 | Exact, stateless. The reference every other codec is checked against, and the right choice on a LAN. |
| `adpcm` | 244 | Four bits a sample. **The default**, because at 24 kHz PCM is 48 kB/s per speaker and a twenty-slot server with four people talking is 3.6 MB/s of upstream against 900 kB/s. |

**ADPCM carries its own starting state in a four-byte preamble.** Without it one lost
packet desynchronises the decoder until the speaker stops talking. Four bytes on a
244-byte frame buys recovery on the very next packet.

**Every speaker needs their own decoder instance.** `DotVoiceCodec.instance_for()` hands
out a private one for a stateful format and shares one for a stateless format. Two
speakers through one ADPCM decoder interleave their predictors and both come out as
noise, not as "slightly wrong".

Godot exposes no Opus encoder to GDScript. `DotVoiceCodec.register()` is how a
GDExtension gets used, and nothing else in the addon names a codec.

## The jitter buffer is where voice is won or lost

Four things, each a way voice breaks in practice:

- **Ordering.** UDP reorders. Playing in arrival order is worse than dropping the late
  frame, because a syllable in the wrong place is a different word.
- **The wrap.** Sequence numbers are 16 bits. `DotVoicePacket.sequence_delta` is the only
  place that arithmetic happens; frame 0 after frame 65535 is one frame later, not 65535
  earlier, and getting it wrong discards a speaker for eleven minutes once every twenty.
- **Growth.** A sender arriving faster than real time adds delay for ever. Past
  `max_frames` the **oldest** go, because the newest are the ones somebody is waiting for.
- **Gaps.** A missing frame is filled by fading the previous one, not by silence. A hard
  cut to zero is a step edge and clicks, which is more noticeable than the lost syllable.

**Starting takes `target_frames`; continuing takes one.** A buffer that re-applied the
start condition every frame would stall for the whole target on every late packet, so one
dropped packet becomes sixty milliseconds of silence.

**The talk-spurt flag is load-bearing.** A speaker who pauses and resumes lands in a
buffer still holding their old sequence numbers, so every new frame looks impossibly late
and is discarded. Without the flag they are inaudible until the sequence wraps, which at
50 frames a second is twenty-two minutes.

## Playback is driven by an accumulator, not by the frame rate

A 144 Hz client would drain a 50-frames-a-second stream almost three times too fast, empty
the jitter buffer, and stutter for ever. `DotVoiceManager._pump_playback` advances in real
time regardless of the display, which is the same reason dot-net counts ticks.

## What the server decides, and why it has to be the server

A client asking another client not to play a muted player is not muting anybody, because
the muted player's own client would have to cooperate.

- **The speaker id is stamped from the transport**, never read from the packet. A client
  that could name its own speaker id could put words in any other player's mouth, and the
  only symptom is confusion.
- **Mute is checked before relaying**, and a muted speaker is **not told**. Telling them
  on every frame is spam fifty times a second, and it also tells them exactly when a
  moderator acted.
- **The rate limit is the amplifier control.** One speaker is relayed to every listener,
  so a client sending ten times the expected rate costs the server ten times that
  multiplied by the player count.
- **A team channel with no `team_fn` reaches nobody, not everybody.** A team channel that
  leaks to the other team is a competitive game broken in a way nobody reports, because it
  sounds exactly like working.
- **Never back to the speaker.** Hearing yourself at a round trip's delay is the single
  most disorienting thing a voice system can do.

**A moderator's mute and a player's own mute list are different features.**
`DotVoiceRouter` enforces the first on the server; `DotVoiceManager.local_mutes` applies
the second on the listener's machine. Conflating them gives you a punishment the punished
player can decline.

## Privacy

**Nothing opens a microphone on its own.** Not on ready, not because an exported default
was true. `start_capture()` is an explicit call the host makes after the player has
agreed, and it returns a failure the host can show. A game that records people because a
node entered the tree is a game that records people who did not ask.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/voice_selftest.tscn   # 99 checks
```

## Things deliberately not here

- **Opus, echo cancellation, noise suppression.** All three are GDExtension work. The
  codec interface exists for the first; push-to-talk is why the other two are survivable.
- **A transport.** `send_fn` takes bytes.
- **A voice UI.** The signals a HUD needs are there.
- **Recording to disk.** A `DotVoiceSink` subclass is four methods.
- **Anything that opens a microphone without being asked.**
