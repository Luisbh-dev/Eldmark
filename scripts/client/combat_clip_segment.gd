class_name CombatClipSegment
extends Resource
## A segment of an animation clip: from [member from_s] to [member to_s] seconds of the clip
## [member animation]. The combat layer ([CombatAnimationLayer]) plays it stretched or shrunk
## so that it fills exactly the phase of the action it is assigned to (anticipation, active hit or
## recovery), so the playback speed comes from the phase duration in the combat data,
## not from the original clip.

## Clip as "library/name", for example [code]ual2/Sword_Regular_A[/code]. The libraries
## are declared by [member CombatClipSet.libraries].
@export var animation: StringName = &""
## Second of the clip where the segment starts.
@export var from_s: float = 0.0
## Second of the clip where the segment ends.
@export var to_s: float = 0.0


## Duration (s) of the segment in the original clip.
func length_s() -> float:
	return to_s - from_s
