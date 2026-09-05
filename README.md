This is the **voice** asset for TMC's **Dot** collection. It is how players talk to each other, and it is built so a server decides who is heard rather than asking each client to behave.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Voice Chat for Godot 4

Microphone capture with push-to-talk or voice activation, a pluggable codec, one jitter
buffer per speaker, and routing to everybody, to a team, or to whoever is close enough.

Needs **dot-core** and nothing else. Works with [dot-moderation](../dot-moderation) and
[dot-server](../dot-server) without importing either.

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
godot --headless --path . res://examples/voice_selftest.tscn   # 99 checks
```

### What you get

| | |
| --- | --- |
| **Capture** | Push-to-talk, or voice activation with hysteresis and a hangover so words do not get clipped. |
| **Codecs** | `pcm16` (exact) and `adpcm` (a quarter of the bandwidth). Register your own, including an Opus GDExtension, and nothing else changes. |
| **Wire** | A ten-byte header carrying speaker, sequence, frame length, channel and codec. Every field is bounds-checked, because a voice packet arrives before its sender has done anything trustworthy. |
| **Playback** | A jitter buffer per speaker that reorders, drops duplicates, caps its own growth, and fades over a lost frame rather than cutting to silence. |
| **Routing** | All, team, proximity, or a filter you write. Decided on the server. |
| **Muting** | A moderator's mute is enforced on the server. A player's own mute list is applied on their machine. Those are different features and it matters. |

### Three things worth knowing before you use it

**Nothing opens a microphone on its own.** Not on ready, not because a config flag was
true in an exported default. `start_capture()` is an explicit call you make after the
player has agreed, and it returns a failure you can put on screen.

**The devices are behind an interface, which is why there is a test suite at all.**
`DotVoiceSource` and `DotVoiceSink` have a real implementation and a buffer
implementation. The suite writes samples in one end and reads audio out of the other with
no audio device in the process, so the gate, the codec, the packet, the router and the
jitter buffer all run the code a player runs. Same idea as `DotFpsSampler`.

**Both ends must agree on the format.** Sample rate, frame length and codec.
`DotVoiceConfig.format_fingerprint()` is one number to exchange at handshake, because a
mismatch is not an error, it is noise or speech at the wrong speed.

### Where a game plugs in

| To change | Where |
| --- | --- |
| Where bytes go | `DotVoiceManager.send_fn`, `DotVoiceRouter.send_fn` |
| Where audio comes from | `DotVoiceSource` subclass |
| Where audio goes | `DotVoiceSink` subclass, or `DotVoiceManager.sink_factory` |
| The codec | `DotVoiceCodec` subclass plus `DotVoiceCodec.register` |
| Who hears whom | `DotVoiceRouter.team_fn` / `position_fn` / `listener_filter` |
| Who may be heard at all | Anything with `is_voice_muted(peer)` registered as `dot_mute_source` |
| Feel and bandwidth | `DotVoiceConfig` |

### What is deliberately not here

- **Opus.** Godot exposes no Opus encoder to GDScript. The codec interface exists so a
  GDExtension can be dropped in; the two shipped are what the language can do.
- **Echo cancellation and noise suppression.** Both are real signal processing and belong
  in a GDExtension. Push-to-talk is the reason this is usable without them.
- **A voice UI.** `talking_changed`, `speaker_changed` and `input_level()` are what a HUD
  needs. Drawing it is [dot-ui](../dot-ui)'s or your game's.
- **A transport.** `send_fn` takes bytes. Putting them on a wire is the host's, exactly
  as in [dot-net](../dot-net).
- **Proof that the microphone works.** The device layer needs an audio device, so the
  headless suite cannot cover it and says so in its last section rather than leaving you
  to find out.
