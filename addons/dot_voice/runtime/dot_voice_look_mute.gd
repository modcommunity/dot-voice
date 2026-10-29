@tool
class_name DotVoiceLookMute
extends Node

## Look at a player and press a key to stop hearing them: tap gags (voice), double-tap mutes (voice and chat via [member chat_mute_fn]).
##
## The first tap acts at once and the second reverts the gag and toggles the mute, so no gag waits out the window. Client-local; the cvars ([constant CVAR_GAG_ALLOWED], [constant CVAR_MUTE_ALLOWED], [constant CVAR_GAG_DEFAULT]) only gate it. The host supplies [member target_fn]; [method pick_by_angle] is a ready answer.

const CHANNEL := "voice.look_mute"

const CVAR_GAG_ALLOWED := "sv_voice_gag_allowed"
const CVAR_MUTE_ALLOWED := "sv_voice_mute_allowed"
const CVAR_GAG_DEFAULT := "sv_voice_gag_default"

const GAG_ACTION := &"voice_gag"
const MUTE_ACTION := &"voice_mute"
const DEFAULT_GAG_KEY := KEY_G
const DEFAULT_MUTE_KEY := KEY_H

## A listener gagged or un-gagged this speaker. [param muted]: the mute (voice and chat).
signal gag_changed(speaker: int, gagged: bool)
signal mute_changed(speaker: int, muted: bool)

## The voice manager whose [member DotVoiceManager.gagged] this drives.
var manager: DotVoiceManager = null

## The peer id being looked at, or 0 for nobody: `func() -> int`. Required for the key to do anything.
var target_fn: Callable = Callable()

## Mutes chat for a peer: `func(peer: int, muted: bool)`. Optional; unset, a mute is voice only.
var chat_mute_fn: Callable = Callable()

## Gag and mute on their own keys; off, [member gag_action] taps gag and double-taps mute.
var separate_keys: bool = false
var gag_action: StringName = GAG_ACTION
var mute_action: StringName = MUTE_ACTION

## Milliseconds between two taps that make a double-tap.
@export_range(100, 1000, 10) var double_tap_ms: int = 300

## The server's switches, followed from its replicated cvars.
var gag_allowed: bool = true
var mute_allowed: bool = true

## Muted speakers (voice and chat). Gags live on the manager.
var muted: Dictionary = {}

var _last_target: int = 0
var _last_tap_ms: int = -100000
var _last_tap_gagged_it: bool = false
var _armed: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	ensure_actions()


## Creates the two actions on G and H if nothing has; a key table that bound them first wins.
static func ensure_actions() -> void:
	for pair in [[GAG_ACTION, DEFAULT_GAG_KEY], [MUTE_ACTION, DEFAULT_MUTE_KEY]]:
		if InputMap.has_action(pair[0]):
			continue
		InputMap.add_action(pair[0])
		var key := InputEventKey.new()
		key.physical_keycode = pair[1]
		InputMap.action_add_event(pair[0], key)


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event.is_action_pressed(gag_action, false, true):
		tap(Time.get_ticks_msec(), false)
	elif separate_keys and event.is_action_pressed(mute_action, false, true):
		tap(Time.get_ticks_msec(), true)


## One key press at [param now_ms], on whoever [member target_fn] names. [param is_mute_key]
## is the dedicated mute key of [member separate_keys]. Public so a test or a controller
## binding drives it without synthesising events.
func tap(now_ms: int, is_mute_key: bool = false) -> void:
	if not target_fn.is_valid():
		return
	var target := int(target_fn.call())
	if target <= 0:
		_last_target = 0
		return

	if is_mute_key:
		if mute_allowed:
			set_muted(target, not muted.has(target))
		return

	var is_second := separate_keys == false and target == _last_target \
		and now_ms - _last_tap_ms <= double_tap_ms and _armed

	_last_target = target
	_last_tap_ms = now_ms

	if is_second and mute_allowed:
		# Back out the gag the first tap made, then mute. A muted speaker is silent anyway.
		if _last_tap_gagged_it:
			set_gag(target, not is_gagged(target))
		set_muted(target, not muted.has(target))
		_armed = false
		_last_tap_gagged_it = false
		return

	_armed = true
	_last_tap_gagged_it = gag_allowed
	if gag_allowed:
		set_gag(target, not is_gagged(target))


func is_gagged(speaker: int) -> bool:
	return manager != null and manager.is_gagged(speaker)


func is_muted(speaker: int) -> bool:
	return muted.has(speaker)


func set_gag(speaker: int, on: bool) -> void:
	DotLog.debug(CHANNEL, "gag", {"speaker": speaker, "on": on})
	if manager != null:
		manager.set_gag(speaker, on)
	gag_changed.emit(speaker, on)


## Voice and chat. Voice goes through the manager's [member DotVoiceManager.local_mutes],
## which is what `sm` uses too, so the two features agree on who is muted.
func set_muted(speaker: int, on: bool) -> void:
	DotLog.debug(CHANNEL, "mute", {"speaker": speaker, "on": on})
	if on:
		muted[speaker] = true
	else:
		muted.erase(speaker)
	if manager != null:
		manager.set_local_mute(speaker, on)
	if chat_mute_fn.is_valid():
		chat_mute_fn.call(speaker, on)
	mute_changed.emit(speaker, on)


## Picks the peer nearest the view axis inside [param max_angle_deg] and [param max_distance]; 0 for nobody.
## [param positions] is peer -> Vector3 (excluding the viewer). A physics game can assign its own ray to [member target_fn].
static func pick_by_angle(
		eye: Transform3D, positions: Dictionary, max_distance: float = 30.0, max_angle_deg: float = 6.0
) -> int:
	var forward := -eye.basis.z
	var best := 0
	var best_angle := deg_to_rad(max_angle_deg)
	for peer in positions:
		var to: Vector3 = (positions[peer] as Vector3) - eye.origin
		var d := to.length()
		if d < 0.01 or d > max_distance:
			continue
		var angle := forward.angle_to(to / d)
		if angle < best_angle:
			best_angle = angle
			best = int(peer)
	return best


## Applies one of the server's cvars by name. False for a name that is not this node's.
func set_cvar(cvar_name: String, value: String) -> bool:
	var text := value.strip_edges()
	if not text.is_valid_float():
		return false
	var on := text.to_float() != 0.0
	match cvar_name:
		CVAR_GAG_ALLOWED:
			gag_allowed = on
		CVAR_MUTE_ALLOWED:
			mute_allowed = on
		CVAR_GAG_DEFAULT:
			if manager != null:
				manager.gag_default = on
		_:
			return false
	return true


## The cvars as data, for a host that registers them its own way; `bind_cvars` below uses it.
static func cvar_specs() -> Array[Dictionary]:
	return [
		{"name": CVAR_GAG_ALLOWED, "value": "1", "description": "Players may gag a player they look at (stop hearing them): 1 yes, 0 no"},
		{"name": CVAR_MUTE_ALLOWED, "value": "1", "description": "Players may mute a player they look at (voice and chat): 1 yes, 0 no"},
		{"name": CVAR_GAG_DEFAULT, "value": "0", "description": "1: every player starts gagged for a listener until they un-gag them"},
	]


## Registers the cvars through [param add] (a server module's `add_cvar`, or the same
## signature) and keeps this node on them. Pass FLAG_REPLICATED so clients can follow them.
func bind_cvars(add: Callable, flags: int = 0) -> void:
	for spec in cvar_specs():
		var made: Variant = add.call(String(spec["name"]), String(spec["value"]), String(spec["description"]), flags)
		if not (made is Object) or made == null:
			continue
		var cv := made as Object
		if cv.has_signal(&"changed"):
			cv.connect(&"changed", func(_old: String, new_value: String, n := String(spec["name"])) -> void:
				var _a := set_cvar(n, new_value))
		if cv.has_method(&"get_string"):
			var _b := set_cvar(String(spec["name"]), String(cv.call(&"get_string")))


## Follows the same cvars as the server replicates them, from a client link
## (`replicated_cvar(name, fallback)` and `replicated_cvar_changed`). True when following.
func follow_cvars(source: Object) -> bool:
	if source == null or not source.has_method(&"replicated_cvar") \
			or not source.has_signal(&"replicated_cvar_changed"):
		return false
	for spec in cvar_specs():
		var held := String(source.call(&"replicated_cvar", String(spec["name"]), ""))
		if held != "":
			var _a := set_cvar(String(spec["name"]), held)
	if not source.is_connected(&"replicated_cvar_changed", _on_replicated):
		source.connect(&"replicated_cvar_changed", _on_replicated)
	return true


func _on_replicated(cvar_name: String, value: String) -> void:
	var _a := set_cvar(cvar_name, value)


func describe() -> Dictionary:
	return {
		"gag_allowed": gag_allowed, "mute_allowed": mute_allowed, "separate_keys": separate_keys,
		"gagged": manager.gagged.size() if manager != null else 0, "muted": muted.size(),
	}
