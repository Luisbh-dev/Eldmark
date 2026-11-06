class_name BuildInfo
extends RefCounted
## The identifier of this build: [code]eldmark-<version>-p<protocol>+<revision>[/code].
## [br][br]
## [code]<version>[/code] is [code]application/config/version[/code], [code]<protocol>[/code] is
## [constant NetProtocol.PROTOCOL_VERSION] and [code]<revision>[/code] is the output of
## [code]git describe --always --dirty[/code] taken when the project was exported. The export scripts
## ([code]tools/export.sh[/code], [code]tools/export.ps1[/code]) write that revision to
## [constant BAKED_PATH], which git ignores and the export filters of the client and the server include.
## [br][br]
## Without that file (the editor, the tests, a checkout run directly) the revision is
## [constant DEV_REVISION] ([code]"dev"[/code]); the id is then still well formed and stable, but it does not
## say which commit it runs. The build id is NOT part of [code]sim_hash[/code]: it identifies the executable, not
## the simulation. Both the client ([code]PlatformApi.build_id()[/code]) and the zone
## ([code]ZonePlatform.build_id()[/code]) delegate here, so they always report the same text.
## It depends on nothing in [code]scripts/client/[/code] or [code]scripts/server/[/code].

## File baked at export time with the revision (a single line). Not committed.
const BAKED_PATH: String = "res://build_id.txt"
## Revision used when no file was baked.
const DEV_REVISION: String = "dev"
## The id is cut to this many characters (the platform's limit for a build id).
const MAX_LENGTH: int = 64


## The full build id.
static func build_id() -> String:
	return compose(str(ProjectSettings.get_setting("application/config/version", "0")),
			NetProtocol.PROTOCOL_VERSION, revision())


## The revision baked into the pack, or [constant DEV_REVISION] when there is none (or it is empty).
static func revision() -> String:
	return read_revision(BAKED_PATH)


## The revision stored in the file [param path], cleaned up; [constant DEV_REVISION] if it does not exist or is empty.
static func read_revision(path: String) -> String:
	if not FileAccess.file_exists(path):
		return DEV_REVISION
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return DEV_REVISION
	var text: String = file.get_as_text()
	file.close()
	return sanitize(text.get_slice("\n", 0))


## Builds an id from its parts: spaces become underscores and the result is limited to [constant MAX_LENGTH].
static func compose(version: String, protocol_version: int, rev: String) -> String:
	return ("eldmark-%s-p%d+%s" % [version, protocol_version, sanitize(rev)]).replace(" ", "_").left(MAX_LENGTH)


## A revision reduced to letters, digits and [code].-_[/code]; [constant DEV_REVISION] if nothing is left.
static func sanitize(text: String) -> String:
	var clean: String = ""
	for character: String in text.strip_edges():
		if (character >= "a" and character <= "z") or (character >= "A" and character <= "Z") \
				or (character >= "0" and character <= "9") or character in ".-_":
			clean += character
	return clean if not clean.is_empty() else DEV_REVISION
