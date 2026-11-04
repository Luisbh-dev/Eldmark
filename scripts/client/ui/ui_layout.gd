class_name UILayout
extends RefCounted
## Placement of the HUD elements that are centered at the top (UI-49): the compass, the fort panel and the
## knocked-down notice.
## [br][br]
## [b]Why it exists.[/b] [code]set_anchors_and_offsets_preset(PRESET_CENTER_TOP, PRESET_MODE_MINSIZE)[/code]
## measures the control's minimum size when called and, if it does not have one yet (a control freshly
## created inside [code]_ready[/code]), leaves both margins at 0: the control grows only to the right and
## ends up with its left edge at the center of the screen. [method anchor_top_center] fixes the width with
## symmetric margins and lets it grow on both sides, so the center stays at the center of its parent at any
## time and with any height. Client only.


## Anchors [param control] at the top center of its parent with [param width] px of width, [param top] px
## from the top edge, horizontally centered and growing downward and to both sides.
static func anchor_top_center(control: Control, width: float, top: float) -> void:
	control.anchor_left = 0.5
	control.anchor_right = 0.5
	control.anchor_top = 0.0
	control.anchor_bottom = 0.0
	control.offset_left = -width * 0.5
	control.offset_right = width * 0.5
	control.offset_top = top
	control.offset_bottom = top
	control.grow_horizontal = Control.GROW_DIRECTION_BOTH
	control.grow_vertical = Control.GROW_DIRECTION_END
