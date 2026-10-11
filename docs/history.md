# History

Bugs worth recognising if they come back. The lessons that still apply are rules in [CLAUDE.md](../CLAUDE.md) and [design.md](design.md).

## `is_supported()` passed with no sound card

The first `DotVoiceSourceMicrophone.is_supported()` trusted the mix rate and the input device list, both of which look healthy in a headless run. The suite found it; the check now reads the driver name. The measurements are in [design.md](design.md#audioserver-lies-about-having-a-sound-card).

## The speaker id was 16 bits

A Godot peer id is 31 bits, and version 1 of `DotVoicePacket` wrote `speaker & 0xFFFF`. A listener receiving a relayed frame got a number that matched nobody, so a host could not draw "who is talking" and `active_speakers()` returned ids that were not peer ids. Worse, **two players whose ids differ only above bit 16 were one speaker to every listener**: their frames went into one jitter buffer with interleaved sequence numbers, through one stateful ADPCM decoder (which `_ensure_speaker` gives each speaker separately for exactly this reason), and both came out as noise. Sixty-four players against a 16-bit space is about a 3% chance per server: a bug that happens to somebody every week and is unexplainable when it does. Nothing errored on either end.

The suite could not see it: every check drove the router and jitter buffer with speaker numbers like 2 and 7, all of which fit in 16 bits, the shape the family keeps naming (a suite that cannot tell "agrees" from "was never asked to disagree"). It was found by the first suite in the family to relay a frame between two real clients over real sockets and ask a listener **who** was talking. The suite now round-trips a full-width id. Fixing it also broke three checks with hand-written byte offsets that would have passed for the wrong reason; the offsets are now `DotVoicePacket.OFFSET_*`, shared by the encoder, decoder and suite.

## Every game chose a channel, and every game got everybody

`DotVoiceRouter.default_channel` was documented as "the channel used when a packet does not name one", and every packet names one: the client's `DotVoiceManager.channel`, ALL unless a host changes it, and no game did. So the property was never read. Team voice in the side-against-side games, proximity voice in the arena and the sandbox: all of them relayed every word to every player, and every suite passed, because the router's own checks named each packet's channel by hand. Found 2026-10-11 by reading each game's `_voice_default_channel` against the router. The router now relays on `default_channel` and ignores the packet's field unless `honour_packet_channel`; the suite's "the server's switch" section sends ALL to a TEAM game and expects only the team.

## Every voice at the world's origin

`DotGameChatClient` turned on positional playback for nine games and none of them ever called `set_speaker_position`, so every remote voice was an `AudioStreamPlayer3D` standing at (0, 0, 0) with inverse-distance falloff over 40 metres: loud for a player standing at the origin, from the wrong side for one nearby, and silent for anybody further away. Positional playback now needs `speaker_position_fn`; without it voices are flat.

## No project could open a microphone

`DotVoiceSourceMicrophone.start()` refuses when `audio/driver/enable_input` is false, and that setting is read when the driver starts, so only a project's `project.godot` can set it. In October 2026 only this repository's had it: no game and not the client shell, so every game's "no microphone on this machine" line was true of every machine. The chat client also called `start_capture()` as it attached to its bridge, which would have asked a browser for the microphone on page load; it now opens on the first press of the talk key.
