# History

Bugs worth recognising if they come back. The lessons that still apply are rules in [CLAUDE.md](../CLAUDE.md) and [design.md](design.md).

## `is_supported()` passed with no sound card

The first `DotVoiceSourceMicrophone.is_supported()` trusted the mix rate and the input device list, both of which look healthy in a headless run. The suite found it; the check now reads the driver name. The measurements are in [design.md](design.md#audioserver-lies-about-having-a-sound-card).

## The speaker id was 16 bits

A Godot peer id is 31 bits, and version 1 of `DotVoicePacket` wrote `speaker & 0xFFFF`. A listener receiving a relayed frame got a number that matched nobody, so a host could not draw "who is talking" and `active_speakers()` returned ids that were not peer ids. Worse, **two players whose ids differ only above bit 16 were one speaker to every listener**: their frames went into one jitter buffer with interleaved sequence numbers, through one stateful ADPCM decoder (which `_ensure_speaker` gives each speaker separately for exactly this reason), and both came out as noise. Sixty-four players against a 16-bit space is about a 3% chance per server: a bug that happens to somebody every week and is unexplainable when it does. Nothing errored on either end.

The suite could not see it: every check drove the router and jitter buffer with speaker numbers like 2 and 7, all of which fit in 16 bits, the shape the family keeps naming (a suite that cannot tell "agrees" from "was never asked to disagree"). It was found by the first suite in the family to relay a frame between two real clients over real sockets and ask a listener **who** was talking. The suite now round-trips a full-width id. Fixing it also broke three checks with hand-written byte offsets that would have passed for the wrong reason; the offsets are now `DotVoicePacket.OFFSET_*`, shared by the encoder, decoder and suite.
