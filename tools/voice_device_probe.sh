#!/usr/bin/env bash
# The voice device layer on a real audio device: capture bus, resampling, the player sink.
#
#   tools/voice_device_probe.sh
#
# xvfb-run, because `--headless` has the Dummy audio driver and the question never comes up.
# A tone is played into the capture bus instead of a microphone (see the probe's header).
#
# Exit codes: 0 heard, 1 silent or wrong, 2 no audio device on this machine.
set -euo pipefail
cd "$(dirname "$0")/.."
exec timeout 60 xvfb-run -a godot --path . res://examples/voice_device_probe.tscn
