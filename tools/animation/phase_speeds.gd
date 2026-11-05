extends SceneTree
## Prints, for each clip set in data/animation, the playback speed of each phase of each
## attack, ability and action with a duration (the quality rule is 0.7x to 1.5x; ART-07).
## Usage: godot --headless --path . -s res://tools/animation/phase_speeds.gd


func _initialize() -> void:
	var tick_rate: float = float(Engine.physics_ticks_per_second)
	var dir: DirAccess = DirAccess.open("res://data/animation")
	var files: PackedStringArray = []
	for file: String in dir.get_files():
		if file.ends_with("_clips.tres"):
			files.append(file)
	files.sort()
	for file: String in files:
		var set: CombatClipSet = load("res://data/animation/" + file) as CombatClipSet
		print("== ", file)
		for entry: CombatActionAnim in set.entries:
			var ticks: Array[float] = _phase_ticks(entry)
			var segments: Array[CombatClipSegment] = [entry.windup, entry.active, entry.recovery]
			var line: String = "  %-18s" % entry.key
			for index: int in segments.size():
				var segment: CombatClipSegment = segments[index]
				if segment == null or ticks[index] <= 0.0:
					continue
				var seconds: float = ticks[index] / tick_rate
				line += " | %s %s [%.2f-%.2f] %.2fs -> %.2fx" % ["WAR"[index], String(segment.animation).get_file(),
						segment.from_s, segment.to_s, seconds, segment.length_s() / seconds]
			print(line)
	quit(0)


# Ticks of each phase of the entry, looking up its attack or ability by name; 0 if they are not known.
func _phase_ticks(entry: CombatActionAnim) -> Array[float]:
	var tick_rate: float = float(Engine.physics_ticks_per_second)
	var result: Array[float] = [0.0, 0.0, 0.0]
	var attack: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(entry.key))
	if attack != null and entry.is_attack():
		result = [float(attack.windup_ticks), float(attack.active_ticks), float(attack.recovery_ticks)]
		return result
	var ability: AbilityTicks = null
	var id: int = 1
	while id < 64:
		var candidate: AbilityTicks = CombatCatalog.ability(id)
		if candidate != null and candidate.name == entry.key:
			ability = candidate
			break
		id += 1
	if ability != null:
		if entry.is_attack():
			return [float(ability.cast_ticks), float(ability.active_ticks), float(ability.recovery_ticks)]
		# Without phases (the shield wall, the potions): the planner uses the duration of the resource itself.
		return [entry.duration_s * tick_rate, 0.0, 0.0]
	var tables: CombatTables = CombatCatalog.tables()
	match entry.key:
		&"swap":
			return [float(tables.swap_ticks), 0.0, 0.0]
		&"revive":
			return [float(tables.revive_ticks), 0.0, 0.0]
		&"execute":
			return [float(tables.execute_ticks), 0.0, 0.0]
		&"dodge":
			var dodge: WeaponTicks = CombatCatalog.weapon(CombatCatalog.default_weapon_id())
			return [float(dodge.dodge.duration_ticks), 0.0, 0.0]
	if entry.duration_s > 0.0:
		result[0] = entry.duration_s * float(Engine.physics_ticks_per_second)
	return result
