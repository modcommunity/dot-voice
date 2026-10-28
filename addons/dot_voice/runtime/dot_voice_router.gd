@tool
class_name DotVoiceRouter
extends Node

## The server's half: who is allowed to talk, and who hears them. Every decision is made here, because a client cannot be trusted to mute another.
##
## Mute is checked before relaying (distinct from [member DotVoiceManager.local_mutes], a preference), the rate limit stops voice being a bandwidth amplifier, and the speaker id is stamped from the transport's sender so nobody can impersonate. Muting is duck-typed through [DotRegistry] ([code]is_voice_muted(speaker) -> bool[/code]), so no dot-server or dot-moderation dependency.

const CHANNEL := "voice.router"
const SERVICE := &"dot_voice_router"

## Registry name of whatever decides mutes. dot-moderation publishes this.
const MUTE_SERVICE := &"dot_mute_source"

## How far a packet travels.
enum Channel {
	## Everybody on the server.
	ALL = 0,
	## Everybody on the speaker's team.
	TEAM = 1,
	## Everybody within [member DotVoiceConfig.proximity_range].
	PROXIMITY = 2,
	## Nobody but the listeners a game names itself, through [member listener_filter].
	CUSTOM = 3,
}

## The server's cvar that turns voice on and off: 1 relays, 0 relays nothing.
const CVAR_ENABLE := "sv_voice_enable"

## The server's cvar that decides how far speech carries, over whatever the game and the
## client asked for: 0 the game's own choice, 1 everybody, 2 the speaker's team, 3 the
## players within [member proximity_range]. See [member forced_channel].
const CVAR_MODE := "sv_voice_mode"

## [constant CVAR_MODE]'s values, in order. Index 0 is "the game decides".
const MODES: Array[int] = [-1, Channel.ALL, Channel.TEAM, Channel.PROXIMITY]

## Proximity cvars. Range in metres; minimum distance is the full-volume radius; falloff is a [enum DotVoiceProximity.Falloff];
## occlusion quiets a wall ([member occlusion_gain]); the bypasses exempt team or global channels (needs [member honour_packet_channel]).
const CVAR_PROX_RANGE := "sv_voice_proximity_range"
const CVAR_PROX_MIN := "sv_voice_proximity_min"
const CVAR_PROX_FALLOFF := "sv_voice_proximity_falloff"
const CVAR_PROX_OCCLUSION := "sv_voice_proximity_occlusion"
const CVAR_PROX_OCCLUSION_GAIN := "sv_voice_proximity_occlusion_gain"
const CVAR_PROX_TEAM_BYPASS := "sv_voice_proximity_team_bypass"
const CVAR_PROX_GLOBAL_BYPASS := "sv_voice_proximity_global_bypass"

## A packet was refused. [param reason] is one of `muted`, `rate`, `unknown`, `format`,
## `disabled`.
signal speech_refused(speaker: int, reason: String)

## A packet was relayed to this many listeners.
signal speech_relayed(speaker: int, listeners: int)

@export_group("Routing")

## Whether anything is relayed at all ([constant CVAR_ENABLE]).
##
## Enforced here: a modified client keeps sending. Off, packets are dropped before parsing, counted in [member refused_disabled], and the speaker is not told.
@export var enabled: bool = true

## A channel every packet is sent on regardless of the one it names, or -1 to honour the packet's ([constant CVAR_MODE]).
##
## The channel is client-written, so trusting it makes team-only voice optional. Proximity with no [member position_fn] reaches nobody, as team with no [member team_fn] does.
@export var forced_channel: int = -1

## The channel every packet is relayed on: the game's choice (team voice, proximity voice).
##
## Every packet names a channel (ALL unless the host changed it), so only a router that overrides it enforces a game's rule. See [member honour_packet_channel].
@export var default_channel: Channel = Channel.ALL

## Use the channel each packet names instead of [member default_channel]. For a game that
## gives players a key for "team" and one for "everybody"; the router still enforces what
## each channel reaches, and [member forced_channel] still wins.
@export var honour_packet_channel: bool = false

## Metres a proximity packet carries. Mirrors [member DotVoiceConfig.proximity_range].
@export_range(0.0, 500.0, 1.0) var proximity_range: float = 40.0

@export_group("Proximity")

## Metres inside which a proximity voice is at full volume.
@export_range(0.0, 100.0, 0.5) var proximity_min_distance: float = 2.0

## How loudness falls between the minimum distance and [member proximity_range].
@export var proximity_falloff: DotVoiceProximity.Falloff = DotVoiceProximity.Falloff.INVERSE

## Whether [member occlusion_fn] is asked. Off by default: it is a ray per listener in range.
@export var proximity_occlusion: bool = false

## What an occluded voice is multiplied by. 0 is a wall that blocks speech entirely.
@export_range(0.0, 1.0, 0.05) var occlusion_gain: float = 0.35

## Whether a packet on the team channel is exempt from proximity (team radio). Only
## reachable with [member honour_packet_channel] and proximity as [member default_channel].
@export var team_bypasses_proximity: bool = true

## Whether a packet on the everybody channel is exempt from proximity (a global shout key).
## Off: with proximity as the game's mode, the everybody channel is proximity too, which is
## what a client that never chose a channel (it sends ALL) must get.
@export var global_bypasses_proximity: bool = false

@export_group("Limits")

## Bytes per second one speaker may put on the wire. 0 disables the limit.
@export_range(0, 65536, 256) var max_bytes_per_second: int = 4096

## Seconds the rate window covers.
##
## Longer tolerates a burst (a talk spurt starts with queued frames), shorter reacts faster; one second.
@export_range(0.25, 10.0, 0.25) var rate_window_sec: float = 1.0

## Config, so the router knows the expected frame format.
var config: DotVoiceConfig = null

## Sends one packet's bytes to one peer. Set by the host, exactly like dot-net's.
##
## One peer, never a broadcast address.
var send_fn: Callable = Callable()

## Returns the team of a speaker, for [constant Channel.TEAM]. Optional.
var team_fn: Callable = Callable()

## Returns the world position of a speaker, for [constant Channel.PROXIMITY]. Optional.
var position_fn: Callable = Callable()

## Whether a listener inside [member proximity_range] can hear the speaker, for [constant Channel.PROXIMITY]; optional:
## [code]func(listener: int, speaker: int, listener_at: Vector3, speaker_at: Vector3) -> bool[/code].
## A range is not a room and this addon knows no level, so the host is asked after the distance test, with the same signature as dot-chat's router. Unset, range decides.
var can_hear_fn: Callable = Callable()

## Returns the listeners a [constant Channel.CUSTOM] packet goes to. Optional.
var listener_filter: Callable = Callable()

## Whether a wall is between two points, for [member proximity_occlusion]: [code]func(listener_at: Vector3, speaker_at: Vector3) -> bool[/code].
## Softer than [member can_hear_fn]: it only turns the voice down. [method DotVoiceProximity.ray_occluder] makes one.
var occlusion_fn: Callable = Callable()

## listener -> gain for the packet being relayed. Rebuilt per packet; empty means full.
var _gains: Dictionary = {}

## Diagnostics.
var relayed_packets: int = 0
var relayed_bytes: int = 0
var refused_muted: int = 0
var refused_rate: int = 0
var refused_format: int = 0
var refused_disabled: int = 0

## Peers that can hear and be heard, in the order they were added.
var peers: PackedInt64Array = PackedInt64Array()

## peer -> {bytes: int, window_start_ms: int}
var _rates: Dictionary = {}
## peer -> next sequence to stamp
var _sequences: Dictionary = {}
## Locally held mutes, for a deployment with no moderation addon installed.
var _muted: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	DotRegistry.register(SERVICE, self)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)



func add_peer(peer_id: int) -> void:
	if not peers.has(peer_id):
		peers.append(peer_id)


func remove_peer(peer_id: int) -> void:
	var index := peers.find(peer_id)
	if index >= 0:
		peers.remove_at(index)
	_rates.erase(peer_id)
	_sequences.erase(peer_id)



## Mutes a speaker on this server, when no moderation addon is installed.
##
## A fallback: it is gone on reconnect. A deployment wanting a lasting mute registers a [code]dot_mute_source[/code] (dot-moderation is one).
func set_muted(speaker: int, muted: bool) -> void:
	if muted:
		_muted[speaker] = true
	else:
		_muted.erase(speaker)


## Whether a speaker may be heard.
##
## Asks the registered mute source first, then the local set.
func is_muted(speaker: int) -> bool:
	var source := DotRegistry.get_service(MUTE_SERVICE)

	if source != null and source.has_method("is_voice_muted"):
		return bool(source.call("is_voice_muted", speaker))

	return _muted.has(speaker)



## Takes a packet from [param from_peer] and relays it to whoever should hear it.
##
## [param from_peer] is the transport's sender, never the packet's claim. Returns the listener count, or a failure.
func relay(from_peer: int, bytes: PackedByteArray) -> DotResult:
	if not enabled:
		refused_disabled += 1
		speech_refused.emit(from_peer, "disabled")
		return DotResult.success(0)

	var max_samples := config.frame_samples() * 4 if config != null else 4096
	var parsed := DotVoicePacket.from_bytes(bytes, max_samples)

	if not parsed.ok:
		refused_format += 1
		speech_refused.emit(from_peer, "format")
		return parsed

	var packet: DotVoicePacket = parsed.value

	# [b]Stamped, not trusted.[/b] Whatever the client put in the speaker field is
	# discarded and replaced with who actually sent it. Without this any client can put
	# words in any other player's mouth, and the only symptom is confusion.
	packet.speaker = from_peer
	# The gain is the server's to set. A client's own packet carrying gain bits would
	# otherwise be relayed with them, letting a talker choose how loud they are to others.
	packet.gain = 1.0
	_gains.clear()

	# The server's channel, not the client's. See default_channel for the bug this was.
	if forced_channel >= 0:
		packet.channel = forced_channel
	elif not honour_packet_channel:
		packet.channel = default_channel

	# Proximity is the game's mode, and a team or global channel may opt out of it.
	if forced_channel < 0 and default_channel == Channel.PROXIMITY and honour_packet_channel:
		if (packet.channel == Channel.TEAM and not team_bypasses_proximity) \
				or (packet.channel == Channel.ALL and not global_bypasses_proximity):
			packet.channel = Channel.PROXIMITY

	if config != null and packet.sample_count != config.frame_samples():
		refused_format += 1
		speech_refused.emit(from_peer, "format")
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A voice packet is not this server's frame length.",
			"%d samples, expected %d" % [packet.sample_count, config.frame_samples()]
		)

	if is_muted(from_peer):
		refused_muted += 1
		speech_refused.emit(from_peer, "muted")
		# Not an error the sender is told about. A muted player who is told they are
		# muted on every frame is a player being spammed fifty times a second, and a
		# muted player who can measure the refusal knows exactly when a moderator acted.
		return DotResult.success(0)

	if not _within_rate(from_peer, bytes.size()):
		refused_rate += 1
		speech_refused.emit(from_peer, "rate")
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"A client is sending voice faster than the server relays it.",
			"peer %d" % from_peer
		)

	# Re-sequenced by the server so the numbering a listener sees is contiguous per
	# speaker regardless of what the sender did with its own counter.
	var sequence: int = int(_sequences.get(from_peer, 0))
	_sequences[from_peer] = (sequence + 1) & 0xFFFF
	packet.sequence = sequence

	var listeners := _listeners_for(packet)
	var payload := packet.to_bytes()

	if send_fn.is_valid():
		var flags_at := DotVoicePacket.OFFSET_FLAGS
		for listener in listeners:
			var gain: float = float(_gains.get(int(listener), 1.0))
			if gain >= 1.0:
				send_fn.call(int(listener), payload)
			else:
				# Patched in a copy rather than re-encoding the frame per listener.
				var quiet := payload.duplicate()
				quiet.encode_u8(flags_at, quiet.decode_u8(flags_at) | DotVoicePacket.gain_bits(gain))
				send_fn.call(int(listener), quiet)

	relayed_packets += 1
	relayed_bytes += payload.size() * listeners.size()
	speech_relayed.emit(from_peer, listeners.size())

	return DotResult.success(listeners.size())


func _listeners_for(packet: DotVoicePacket) -> PackedInt64Array:
	var out := PackedInt64Array()

	match packet.channel:
		Channel.CUSTOM:
			if listener_filter.is_valid():
				var named: Variant = listener_filter.call(packet.speaker)
				if named is PackedInt64Array:
					return named as PackedInt64Array
				if named is Array:
					for peer in (named as Array):
						out.append(int(peer))
			return out

		Channel.TEAM:
			if not team_fn.is_valid():
				# No way to tell teams apart: reach nobody rather than leak a team channel to the
				# other team, which sounds exactly like working.
				DotLog.warn(CHANNEL, "a team packet arrived with no team_fn set")
				return out

			var speaker_team: Variant = team_fn.call(packet.speaker)
			for peer in peers:
				if int(peer) == packet.speaker:
					continue
				if team_fn.call(int(peer)) == speaker_team:
					out.append(peer)
			return out

		Channel.PROXIMITY:
			if not position_fn.is_valid():
				DotLog.warn(CHANNEL, "a proximity packet arrived with no position_fn set")
				return out

			var origin: Variant = position_fn.call(packet.speaker)
			if not (origin is Vector3):
				return out

			var range_squared := proximity_range * proximity_range
			var ask_occlusion := proximity_occlusion and occlusion_fn.is_valid()

			for peer in peers:
				if int(peer) == packet.speaker:
					continue
				var at: Variant = position_fn.call(int(peer))
				if not (at is Vector3):
					continue
				# Squared, so no square root runs per listener per frame. At fifty
				# frames a second times a full server this is the hottest loop here.
				if (at as Vector3).distance_squared_to(origin as Vector3) > range_squared:
					continue
				if can_hear_fn.is_valid() and not bool(
					can_hear_fn.call(int(peer), packet.speaker, at, origin)
				):
					continue
				var level := DotVoiceProximity.gain(
					(at as Vector3).distance_to(origin as Vector3), proximity_range,
					proximity_min_distance, proximity_falloff
				)
				if ask_occlusion and bool(occlusion_fn.call(at, origin)):
					level *= occlusion_gain
				# Silent after falloff or a wall: not sent, which is the bandwidth saving.
				if level <= 0.0:
					continue
				if level < 1.0:
					_gains[int(peer)] = level
				out.append(peer)
			return out

		_:
			for peer in peers:
				# Never back to the speaker. Hearing yourself at a round trip's delay is
				# the single most disorienting thing a voice system can do.
				if int(peer) != packet.speaker:
					out.append(peer)
			return out


## Whether this peer is within its byte budget, counting this packet.
func _within_rate(peer: int, size: int) -> bool:
	if max_bytes_per_second <= 0:
		return true

	var now := Time.get_ticks_msec()
	var window: Dictionary = _rates.get(peer, {"bytes": 0, "start": now})

	if now - int(window["start"]) >= int(rate_window_sec * 1000.0):
		window = {"bytes": 0, "start": now}

	var budget := int(float(max_bytes_per_second) * rate_window_sec)
	var used := int(window["bytes"]) + size

	window["bytes"] = used
	_rates[peer] = window

	return used <= budget



## The cvars [method bind_cvars] registers, as data, for a host that registers them its own way.
func cvar_specs() -> Array[Dictionary]:
	var mode := maxi(MODES.find(forced_channel), 0)
	var out: Array[Dictionary] = [
		{
			"name": CVAR_ENABLE,
			"value": "1" if enabled else "0",
			"description": "Voice chat: 1 on, 0 off. Off relays nothing, and clients hide the push-to-talk key",
			"min": 0.0,
			"max": 1.0,
		},
		{
			"name": CVAR_MODE,
			"value": str(mode),
			"description": "Who hears a speaker: 0 the game decides, 1 everybody, 2 the speaker's team, 3 players nearby",
			"min": 0.0,
			"max": float(MODES.size() - 1),
		},
		{
			"name": CVAR_PROX_RANGE, "value": str(proximity_range),
			"description": "Proximity voice: metres a voice carries",
			"min": 1.0, "max": 500.0,
		},
		{
			"name": CVAR_PROX_MIN, "value": str(proximity_min_distance),
			"description": "Proximity voice: metres inside which a voice is at full volume",
			"min": 0.0, "max": 100.0,
		},
		{
			"name": CVAR_PROX_FALLOFF, "value": str(int(proximity_falloff)),
			"description": "Proximity voice falloff: 0 linear, 1 inverse distance, 2 quadratic",
			"min": 0.0, "max": 2.0,
		},
		{
			"name": CVAR_PROX_OCCLUSION, "value": "1" if proximity_occlusion else "0",
			"description": "Proximity voice: 1 turns a voice down through walls (needs the game's occlusion_fn)",
			"min": 0.0, "max": 1.0,
		},
		{
			"name": CVAR_PROX_OCCLUSION_GAIN, "value": str(occlusion_gain),
			"description": "Proximity voice: volume through a wall, 0 silent to 1 unchanged",
			"min": 0.0, "max": 1.0,
		},
		{
			"name": CVAR_PROX_TEAM_BYPASS, "value": "1" if team_bypasses_proximity else "0",
			"description": "Proximity voice: 1 lets the team channel ignore distance",
			"min": 0.0, "max": 1.0,
		},
		{
			"name": CVAR_PROX_GLOBAL_BYPASS, "value": "1" if global_bypasses_proximity else "0",
			"description": "Proximity voice: 1 lets the everybody channel ignore distance",
			"min": 0.0, "max": 1.0,
		},
	]
	return out


## Registers [constant CVAR_ENABLE] and [constant CVAR_MODE] through [param add] (a server module's [code]add_cvar[/code], or anything with [code](name, default, description, flags) -> cvar[/code]) and keeps this router on them.
##
## Pass dot-server's FLAG_REPLICATED so clients hide the key when voice is off ([method DotVoiceManager.follow_cvars]). Duck-typed; the value is read back, as argv or content.yml may already hold the operator's choice.
func bind_cvars(add: Callable, flags: int = 0) -> Array:
	var made: Array = []

	for spec in cvar_specs():
		var cvar_name: String = spec["name"]
		var made_cvar: Variant = add.call(cvar_name, String(spec["value"]), String(spec["description"]), flags)

		if not (made_cvar is Object) or made_cvar == null:
			continue

		var cv := made_cvar as Object

		if cv.has_method(&"with_range"):
			cv.call(&"with_range", float(spec["min"]), float(spec["max"]))

		if cv.has_signal(&"changed"):
			cv.connect(&"changed", _on_cvar_changed.bind(cvar_name))

		if cv.has_method(&"get_string"):
			var _applied := set_cvar(cvar_name, String(cv.call(&"get_string")))

		made.append(cv)

	return made


## Applies one of [method cvar_specs]' cvars by name. False for a name that is not this
## router's or a value that is not a number.
func set_cvar(cvar_name: String, value: String) -> bool:
	var text := value.strip_edges()

	var known := [
		CVAR_ENABLE, CVAR_MODE, CVAR_PROX_RANGE, CVAR_PROX_MIN, CVAR_PROX_FALLOFF,
		CVAR_PROX_OCCLUSION, CVAR_PROX_OCCLUSION_GAIN, CVAR_PROX_TEAM_BYPASS,
		CVAR_PROX_GLOBAL_BYPASS,
	]
	if not known.has(cvar_name):
		return false

	if not text.is_valid_float():
		DotLog.warn(CHANNEL, "cvar is not a number; left as it was", {"cvar": cvar_name, "value": value})
		return false

	if cvar_name == CVAR_ENABLE:
		var on := text.to_float() != 0.0
		if on != enabled:
			DotLog.info(CHANNEL, "voice chat %s" % ("on" if on else "off"))
		enabled = on
		return true

	var number := text.to_float()
	match cvar_name:
		CVAR_PROX_RANGE:
			proximity_range = clampf(number, 1.0, 500.0)
			return true
		CVAR_PROX_MIN:
			proximity_min_distance = clampf(number, 0.0, 100.0)
			return true
		CVAR_PROX_FALLOFF:
			proximity_falloff = clampi(roundi(number), 0, 2) as DotVoiceProximity.Falloff
			return true
		CVAR_PROX_OCCLUSION:
			proximity_occlusion = number != 0.0
			return true
		CVAR_PROX_OCCLUSION_GAIN:
			occlusion_gain = clampf(number, 0.0, 1.0)
			return true
		CVAR_PROX_TEAM_BYPASS:
			team_bypasses_proximity = number != 0.0
			return true
		CVAR_PROX_GLOBAL_BYPASS:
			global_bypasses_proximity = number != 0.0
			return true

	var index := clampi(roundi(number), 0, MODES.size() - 1)
	forced_channel = MODES[index]
	DotLog.debug(CHANNEL, "voice mode set", {"mode": index, "channel": forced_channel})
	return true


func _on_cvar_changed(_old: String, new_value: String, cvar_name: String) -> void:
	var _applied := set_cvar(cvar_name, new_value)


func describe() -> Dictionary:
	return {
		"enabled": enabled,
		"forced_channel": forced_channel,
		"refused_disabled": refused_disabled,
		"peers": peers.size(),
		"relayed": relayed_packets,
		"relayed_bytes": relayed_bytes,
		"refused_muted": refused_muted,
		"refused_rate": refused_rate,
		"refused_format": refused_format,
		"muted": _muted.size(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("voice     %s%s" % ["on" if enabled else "OFF", "" if forced_channel < 0 else ", channel %d forced" % forced_channel])
	out.append("peers     %d" % peers.size())
	out.append("relayed   %d packets, %s" % [
		relayed_packets, DotPaths.format_bytes(relayed_bytes)
	])
	out.append("refused   %d muted, %d over rate, %d malformed, %d while off" % [
		refused_muted, refused_rate, refused_format, refused_disabled
	])
	return out
