@tool
extends EditorPlugin

## Editor entry point for dot-voice. Registers inspector types only.
##
## No autoloads. Voice is the clearest case for one after the server, and it is still
## wrong: a listen server runs a capture for the host and a playback for every remote
## speaker in one process, and a singleton makes the second of anything impossible.

const _ICON := "res://addons/dot_voice/icon_placeholder.svg"

const _TYPES := [
	["DotVoiceManager", "Node", "res://addons/dot_voice/runtime/dot_voice_manager.gd"],
	["DotVoiceRouter", "Node", "res://addons/dot_voice/runtime/dot_voice_router.gd"],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
