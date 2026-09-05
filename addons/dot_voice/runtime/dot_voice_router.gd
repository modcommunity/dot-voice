@tool
class_name DotVoiceRouter
extends Node

## The server's half: who is allowed to talk, and who hears them.
##
## [b]Every decision here is made on the server, and that is the whole point.[/b] A client
## that asks another client not to play a muted player is not muting anybody, because the
## muted player's own client is the one that would have to cooperate. The three controls
## below are the ones that survive somebody running a modified build:
##
## - [b]Mute[/b] is checked before relaying, so a muted player's audio is not sent. A
##   client-side mute list exists as well ([member DotVoiceManager.local_mutes]) and is a
##   different feature: it is a preference, not a punishment.
## - [b]The rate limit[/b] is what stops voice being a bandwidth amplifier. One speaker is
##   relayed to every listener, so a client sending ten times the expected rate costs the
##   server ten times that multiplied by the player count.
## - [b]The speaker id[/b] is stamped here from the sender the transport reported. A
##   client that could name its own speaker id could impersonate anybody, and the only
##   symptom would be words coming out of the wrong mouth.
##
## Muting is duck-typed through [DotRegistry] so this addon does not depend on dot-server
## or dot-moderation. Anything with [code]is_voice_muted(speaker) -> bool[/code] answers.

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

## A packet was refused. [param reason] is one of `muted`, `rate`, `unknown`, `format`.
signal speech_refused(speaker: int, reason: String)

## A packet was relayed to this many listeners.
signal speech_relayed(speaker: int, listeners: int)

@export_group("Routing")

## Channel used when a packet does not name one.
@export var default_channel: Channel = Channel.ALL

## Metres a proximity packet carries. Mirrors [member DotVoiceConfig.proximity_range].
@export_range(0.0, 500.0, 1.0) var proximity_range: float = 40.0

@export_group("Limits")

## Bytes per second one speaker may put on the wire. 0 disables the limit.
@export_range(0, 65536, 256) var max_bytes_per_second: int = 4096

## Seconds the rate window covers.
##
## Longer tolerates a burst, which is normal: a talk spurt starts with a run of frames
## queued while the gate opened. Shorter reacts faster to abuse. One second is the
## compromise and is what a burst of one frame is measured against.
@export_range(0.25, 10.0, 0.25) var rate_window_sec: float = 1.0

## Config, so the router knows the expected frame format.
var config: DotVoiceConfig = null

## Sends one packet's bytes to one peer. Set by the host, exactly like dot-net's.
##
## One peer, never a broadcast address. `send(bytes, 0)` is how this family last
## delivered a private message to everybody at once.
var send_fn: Callable = Callable()

## Returns the team of a speaker, for [constant Channel.TEAM]. Optional.
var team_fn: Callable = Callable()

## Returns the world position of a speaker, for [constant Channel.PROXIMITY]. Optional.
var position_fn: Callable = Callable()

## Returns the listeners a [constant Channel.CUSTOM] packet goes to. Optional.
var listener_filter: Callable = Callable()

## Diagnostics.
var relayed_packets: int = 0
var relayed_bytes: int = 0
var refused_muted: int = 0
var refused_rate: int = 0
var refused_format: int = 0

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


# --- Peers -----------------------------------------------------------------

func add_peer(peer_id: int) -> void:
	if not peers.has(peer_id):
		peers.append(peer_id)


func remove_peer(peer_id: int) -> void:
	var index := peers.find(peer_id)
	if index >= 0:
		peers.remove_at(index)
	_rates.erase(peer_id)
	_sequences.erase(peer_id)


# --- Muting ----------------------------------------------------------------

## Mutes a speaker on this server, when no moderation addon is installed.
##
## [b]A fallback, not the feature.[/b] It lasts as long as the process and is gone the
## moment the player reconnects, which is the first thing anybody who has been muted
## tries. A deployment that wants a mute to mean something registers a
## [code]dot_mute_source[/code] that persists them; dot-moderation is that.
func set_muted(speaker: int, muted: bool) -> void:
	if muted:
		_muted[speaker] = true
	else:
		_muted.erase(speaker)


## Whether a speaker may be heard.
##
## Asks the registered mute source first and falls back to the local set. Duck-typed, so
## this addon compiles in a project that has neither dot-server nor dot-moderation.
func is_muted(speaker: int) -> bool:
	var source := DotRegistry.get_service(MUTE_SERVICE)

	if source != null and source.has_method("is_voice_muted"):
		return bool(source.call("is_voice_muted", speaker))

	return _muted.has(speaker)


# --- Relaying --------------------------------------------------------------

## Takes a packet from [param from_peer] and relays it to whoever should hear it.
##
## [param from_peer] is the sender the transport reported, never anything the packet
## claimed. Returns how many listeners it went to, or a failure saying why not.
func relay(from_peer: int, bytes: PackedByteArray) -> DotResult:
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
		for listener in listeners:
			send_fn.call(int(listener), payload)

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
				# No way to tell teams apart, so a team channel would reach everybody.
				# Reaching nobody is the safe half of that: a team channel that leaks to
				# the other team is a competitive game broken in a way nobody reports,
				# because it sounds exactly like working.
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

			for peer in peers:
				if int(peer) == packet.speaker:
					continue
				var at: Variant = position_fn.call(int(peer))
				if not (at is Vector3):
					continue
				# Squared, so no square root runs per listener per frame. At fifty
				# frames a second times a full server this is the hottest loop here.
				if (at as Vector3).distance_squared_to(origin as Vector3) <= range_squared:
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


func describe() -> Dictionary:
	return {
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
	out.append("peers     %d" % peers.size())
	out.append("relayed   %d packets, %s" % [
		relayed_packets, DotPaths.format_bytes(relayed_bytes)
	])
	out.append("refused   %d muted, %d over rate, %d malformed" % [
		refused_muted, refused_rate, refused_format
	])
	return out
