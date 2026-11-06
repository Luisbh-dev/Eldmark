extends SceneTree
## Prints the build id of this checkout as a single [code]BUILD_ID=<id>[/code] line, for the export scripts
## ([code]tools/export.sh[/code], [code]tools/export.ps1[/code]) and the CI. It uses [BuildInfo], so the text is
## byte for byte what the client, the zone report and the F3 panel show.
## Run: [code]godot --headless --path . -s res://tools/print_build_id.gd[/code]


func _init() -> void:
	print("BUILD_ID=" + BuildInfo.build_id())
	quit()
