class_name HumanoidVisual
extends Node3D
## Aspecto visual de un humanoide (solo cliente): modelo modular + animación.
##
## Raíz de [code]scenes/characters/visuals/humanoid_visual.tscn[/code]. No simula nada: decora un
## [PlayerCharacter] (cadena esperada: PlayerCharacter > Visual > HumanoidVisual) y su
## [CharacterAnimator] hijo lee el estado del personaje cada fotograma.
## [br][br]
## El modelo base ([code]Pivot/Model[/code]) es un glTF de Quaternius con el esqueleto común UAL ya
## convertido al perfil humanoide de Godot ([code]%GeneralSkeleton[/code], ver
## [code]assets/animations/rig/ual_humanoid_bone_map.tres[/code]). Las piezas de
## [member part_scenes] (cabeza, pelo, barba...) se importan con el mismo BoneMap, así que al
## arrancar sus mallas se pasan a ese esqueleto y comparten la pose: un solo esqueleto anima todo.
## [br][br]
## El modelo mira hacia -Z como el [PlayerCharacter] (los glTF de Quaternius miran hacia +Z y por
## eso [code]Model[/code] va girado 180°). El origen está en los pies y mide unos 1,8 m.
## [br][br]
## [b]Piezas por ranura[/b] (docs/progresion.md §7.4, ART-19): las mallas del modelo base son la ranura
## [code]body[/code] y las de [member part_scenes], las de [member part_slots] ([code]head[/code],
## [code]hair[/code], [code]beard[/code]). [method set_part] y [method clear_part] cambian una ranura sin
## recrear el personaje: el nodo, el esqueleto, el animador y las armas se quedan; solo se quitan las mallas de
## esa ranura y se cuelgan las de la escena nueva (poner la escena que ya está no hace nada). [method set_tint]
## tiñe piel, pelo (también barba y cejas) y ojos por material, también en las piezas que se monten después.
## Antes de [method _ready], los cambios se guardan y se aplican al entrar. Lo usa [AppearanceApplier].

## Escena de este visual (se carga en [method install]; no se precarga para no crear un ciclo
## escena -> script -> escena).
const SCENE_PATH: String = "res://scenes/characters/visuals/humanoid_visual.tscn"
## Nodo del [PlayerCharacter] que agrupa lo visual (la cámara lo oculta cuando se acerca).
const VISUAL_NODE: NodePath = ^"Visual"
## Nombre del esqueleto único que deja el BoneMap al importar (opción "Make Unique").
const SKELETON_NAME: String = "GeneralSkeleton"
## Mallas de capucha (se muestran con [member hood_visible]).
const HOOD_MESH_PREFIX: String = "Male_Ranger_Head_Hood"
## Mallas de pelo largo que se ocultan con capucha (las cejas y la barba se quedan).
const HAIR_MESH_PREFIXES: PackedStringArray = ["Hair_SimpleParted"]
## Mallas pequeñas que no proyectan sombra (en una sombra de 1,8 m no se distinguen y cada una
## cuesta una llamada de dibujo por corte de sombra).
const NO_SHADOW_MESH_PREFIXES: PackedStringArray = [
	"Eyes", "Eyebrows", "Hair_Beard", "Male_Ranger_Body_Belt",
]

## Distancia a la cámara (m) por debajo de la cual un visual ajeno con [member camera_fade] se oculta del
## todo, y distancia a partir de la cual se ve entero. Entre las dos se difumina con tramado (ART-53).
const CAMERA_FADE_HIDDEN: float = 0.5
const CAMERA_FADE_SOLID: float = 1.2
## Altura (m) sobre los pies del punto del que se mide la distancia a la cámara.
const CAMERA_FADE_CHEST_HEIGHT: float = 1.2

## Ranuras de pieza que admite [method set_part].
const PART_SLOTS: Array[StringName] = [&"body", &"head", &"hair", &"beard", &"marks"]
## Canales de tinte de [method set_tint] y el prefijo del nombre de los materiales de Universal Base
## Characters que tiñe cada uno (el material de la piel del cuerpo y de la cabeza, el del pelo, la barba y las
## cejas, y el de los ojos). # TODO(arte): provisional hasta los sombreadores de piel y ojos de ART-20.
## Sin tipar a propósito: en Godot 4.7.2 un [code]const Dictionary[StringName, PackedStringArray][/code] escrito
## con literales de array guarda un [Array] con el tipo de [PackedStringArray] y recorrerlo lee basura o se cae.
const TINT_MATERIAL_PREFIXES: Dictionary = {
	&"skin": ["MI_Regular_", "MI_Superhero_"],
	&"hair": ["MI_Hair"],
	&"eyes": ["MI_Eyes"],
}

## Piezas extra con el mismo esqueleto (escenas glTF importadas con el BoneMap UAL). Sus mallas
## se mueven al esqueleto del modelo base en [method _ready].
@export var part_scenes: Array[PackedScene] = []
## Ranura de cada escena de [member part_scenes], en el mismo orden (las que falten no tienen ranura y no se
## pueden cambiar con [method set_part]).
@export var part_slots: Array[StringName] = [&"head", &"hair", &"beard"]
## Muestra la capucha del traje. Con capucha se oculta el pelo para que no la atraviese.
@export var hood_visible: bool = false:
	set(value):
		hood_visible = value
		if is_node_ready():
			_apply_hood()

## Difumina el visual (transparencia única para todas sus mallas) cuando la cámara está a menos de [constant CAMERA_FADE_SOLID] m, y lo
## oculta a menos de [constant CAMERA_FADE_HIDDEN] (ART-53). Es para los personajes ajenos: no hay colisión
## entre personajes, y un torso o un escudo pegado a la cámara llenaba media pantalla en las refriegas. El
## propio personaje no lo usa (la cámara ya oculta su visual al acercarse). Se aplica con los rangos de
## visibilidad del motor en todas las mallas, también las de las piezas y las armas que se monten después.
@export var camera_fade: bool = false:
	set(value):
		camera_fade = value
		if is_node_ready():
			_apply_camera_fade()

@onready var _model: Node3D = $Pivot/Model

var _skeleton: Skeleton3D = null
# true si los rangos de visibilidad de camera_fade están puestos en las mallas.
var _camera_fade_applied: bool = false
var _fade_meshes: Array[MeshInstance3D] = []
var _fade_value: float = -1.0
# Perfil visual de PNJ puesto (ART-52) o null.
var _profile: NpcVisualProfile = null
# Variante de la espada pedida antes de _ready (vacía = ninguna).
var _pending_sword_variant: StringName = &""
# Ranura -> sus mallas (colgadas del esqueleto) y la ruta de la escena de la que salieron.
var _part_meshes: Dictionary[StringName, Array] = {}
var _part_paths: Dictionary[StringName, String] = {}
# Cambios pedidos antes de _ready (ranura -> escena; null = quitar).
var _pending_parts: Dictionary[StringName, PackedScene] = {}
# Canal -> color de [method set_tint].
var _tints: Dictionary[StringName, Color] = {}
# Material base + color -> material teñido, compartido por todos los visuales (los colores son los del
# catálogo: pocos).
static var _tinted_materials: Dictionary[String, Material] = {}


## Cuelga un HumanoidVisual nuevo bajo el nodo Visual de [param character] y oculta las mallas
## provisionales que ya hubiera ahí (la cápsula y el visor de la fase 1). Pensado para llamarse
## desde el cliente justo después de instanciar el personaje, para que la escena compartida
## [code]player_character.tscn[/code] (que también cargará el servidor) no arrastre modelos ni
## animaciones. Devuelve el visual creado, o null si no se pudo cargar la escena.
static func install(character: PlayerCharacter) -> HumanoidVisual:
	var scene: PackedScene = load(SCENE_PATH) as PackedScene
	if scene == null or character == null:
		push_error("[HumanoidVisual] No se pudo instalar el visual (%s)" % SCENE_PATH)
		return null
	var visual_root: Node3D = character.get_node_or_null(VISUAL_NODE) as Node3D
	if visual_root == null:
		visual_root = Node3D.new()
		visual_root.name = String(VISUAL_NODE)
		character.add_child(visual_root)
	for child: Node in visual_root.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).visible = false
	var visual: HumanoidVisual = scene.instantiate() as HumanoidVisual
	visual_root.add_child(visual)
	visual.attach_to(character)
	return visual


## Igual que [method install], pero además quita del nodo Visual las mallas provisionales (la cápsula
## y el visor de [code]player_character.tscn[/code]), que se quedan ligeras para el servidor. Si el
## visual no carga, devuelve null y la cápsula se queda para que se vea algo. Lo usan el sandbox
## ([ClientMain]), el personaje local de [OnlineMain] y los remotos de [RemoteWorld].
static func install_replacing_placeholder(character: PlayerCharacter) -> HumanoidVisual:
	var visual: HumanoidVisual = install(character)
	if visual == null:
		return null
	var visual_root: Node = visual.get_parent()
	for child: Node in visual_root.get_children():
		if child is MeshInstance3D:
			visual_root.remove_child(child)
			child.queue_free()
	return visual


func _ready() -> void:
	_skeleton = _find_skeleton(_model)
	if _skeleton == null:
		push_error("[HumanoidVisual] El modelo no tiene un Skeleton3D '%s'" % SKELETON_NAME)
		return
	# Las mallas del modelo base son la ranura «body».
	var body_meshes: Array[MeshInstance3D] = []
	for child: Node in _skeleton.get_children():
		if child is MeshInstance3D:
			body_meshes.append(child as MeshInstance3D)
	_part_meshes[&"body"] = body_meshes
	_part_paths[&"body"] = _model.scene_file_path
	for index: int in range(part_scenes.size()):
		var slot: StringName = part_slots[index] if index < part_slots.size() else &""
		if slot != &"" and _pending_parts.has(slot):
			continue
		var meshes: Array[MeshInstance3D] = _attach_part(part_scenes[index])
		if slot != &"" and part_scenes[index] != null:
			_part_meshes[slot] = meshes
			_part_paths[slot] = part_scenes[index].resource_path
	for slot: StringName in _pending_parts:
		if _pending_parts[slot] == null:
			clear_part(slot)
		else:
			set_part(slot, _pending_parts[slot])
	_pending_parts.clear()
	_apply_hood()
	_apply_shadow_casting()
	_apply_tints()
	# Armas provisionales en las manos (ART-06): hasta que lleguen los modelos definitivos. El animador
	# avisa del arma que se lleva (la activa del personaje o la del registro de un remoto) y se enseñan
	# sus accesorios (fase 4: el arco o la espada y el escudo).
	WeaponProps.install(_skeleton)
	if _pending_sword_variant != &"":
		WeaponProps.set_sword_variant(_skeleton, _pending_sword_variant)
	get_animator().weapon_shown.connect(_on_weapon_shown)
	# La estela de la espada sigue la fase activa del golpe, también la de los remotos.
	get_animator().swing_active_changed.connect(_on_swing_active_changed)
	# Postura armada sobre la locomoción (ART-45): el reposo de combate, la capa de brazos y el agarre. Va antes
	# que la pose de combate, que la pisa cuando hay un golpe o una esquiva.
	var stance := ArmedStanceModifier.new()
	stance.name = "ArmedStance"
	_skeleton.add_child(stance)
	get_animator().set_stance_modifier(stance)
	# Pose de combate sobre la locomoción (ART-08). Va antes que el giro de la columna, que se
	# aplica encima.
	var combat := CombatPoseModifier.new()
	combat.name = "CombatPose"
	_skeleton.add_child(combat)
	get_animator().set_combat_modifier(combat)
	# Reacciones procedurales al golpe recibido o bloqueado y escudo a la altura de la cabeza (ART-48, ART-50).
	var reaction := HitReactionModifier.new()
	reaction.name = "HitReaction"
	_skeleton.add_child(reaction)
	get_animator().set_reaction_modifier(reaction)
	# Giro de la columna hacia el punto de mira (lo conduce el animador).
	var spine := SpineTwistModifier.new()
	spine.name = "SpineTwist"
	_skeleton.add_child(spine)
	get_animator().set_spine_modifier(spine)
	# Las armas y los modificadores ya están colgados: los rangos de visibilidad les llegan también.
	_apply_camera_fade()


func _on_weapon_shown(weapon_id: int) -> void:
	WeaponProps.show_weapon(_skeleton, weapon_id)
	# Un PNJ con perfil visual (ART-52) cambia el escudo, el color, los ojos, la escala y la postura.
	apply_profile(NpcVisualProfile.for_weapon_id(weapon_id))
	# El arco se crea la primera vez que hace falta: sus mallas también se difuminan.
	_apply_camera_fade()


## Aplica el perfil visual de un tipo de PNJ ([NpcVisualProfile], ART-52), o lo quita con null: escala visual, color
## de las mallas del cuerpo, brillo de los ojos, escudo y arma de las manos y postura del animador. Es solo visual: la
## cápsula del personaje y las cajas de golpe no cambian.
func apply_profile(profile: NpcVisualProfile) -> void:
	_profile = profile
	scale = Vector3.ONE * (profile.scale if profile != null else 1.0)
	if _skeleton != null:
		_apply_tints()
		_apply_profile_props()
	var animator: CharacterAnimator = get_animator()
	if animator != null:
		animator.set_stance_profile(profile.stance if profile != null else &"shield")


## Perfil visual puesto ahora (null si no hay).
func get_profile() -> NpcVisualProfile:
	return _profile


## El personaje recibe un golpe de [param amount] de daño desde [param attacker_direction] (vector del mundo, de la
## víctima hacia el atacante), o lo bloquea con el escudo si [param blocked]: reacción procedural del cuerpo (ART-48,
## ART-50). Ver [method CharacterAnimator.react_to_hit].
func react_to_hit(attacker_direction: Vector3, amount: float = 0.0, blocked: bool = false) -> void:
	get_animator().react_to_hit(attacker_direction, amount, blocked)


# Escudo y arma de las manos según el perfil: sin escudo en el Hueco y arma mayor en el Capitán.
func _apply_profile_props() -> void:
	var shield_node: Node3D = _skeleton.get_node_or_null(NodePath("%s/%s" % [WeaponProps.SHIELD_ATTACHMENT,
			WeaponProps.SHIELD_MESH])) as Node3D
	var sword_attachment: Node3D = _skeleton.get_node_or_null(NodePath(WeaponProps.SWORD_ATTACHMENT)) as Node3D
	var shown_bow: bool = get_animator().get_shown_weapon() >= 0 \
			and CombatCatalog.weapon(get_animator().get_shown_weapon()) != null \
			and CombatCatalog.weapon(get_animator().get_shown_weapon()).name == WeaponProps.BOW_WEAPON
	if shield_node != null and not shown_bow:
		shield_node.visible = _profile == null or _profile.shield
	if sword_attachment != null:
		sword_attachment.scale = Vector3.ONE * (_profile.weapon_scale if _profile != null else 1.0)


func _on_swing_active_changed(active: bool) -> void:
	WeaponProps.set_swing_active(_skeleton, active)


## Pone la espada del reino [param realm] (código de [enum NetProtocol.Realm]; cualquier otro, la base):
## el modelo y el color de la estela. Antes de [method _ready] se guarda y se aplica al entrar.
func set_realm(realm: int) -> void:
	var variant: StringName = RealmCatalog.id_of_code(realm)
	if not SwordModel.MODELS.has(variant):
		variant = SwordModel.BASE
	if _skeleton == null:
		_pending_sword_variant = variant
		return
	WeaponProps.set_sword_variant(_skeleton, variant)


## Esqueleto que anima todas las mallas (perfil humanoide de Godot: Hips, Head, RightHand...).
## De él cuelgan las armas provisionales ([WeaponProps]) y los modificadores de pose.
func get_skeleton() -> Skeleton3D:
	return _skeleton


## Nodo que gira el animador para orientar el modelo (hijo directo de esta raíz).
func get_pivot() -> Node3D:
	return get_node(^"Pivot") as Node3D


## Animador que conduce el [AnimationTree] a partir del [PlayerCharacter].
func get_animator() -> CharacterAnimator:
	return get_node(^"CharacterAnimator") as CharacterAnimator


## Decora [param character]. Si no se llama, el animador busca el [PlayerCharacter] entre sus
## ancestros al entrar en el árbol. Se puede llamar antes de añadir el visual al árbol.
func attach_to(character: PlayerCharacter) -> void:
	get_animator().set_character(character)


## Pone en la ranura [param slot] (una de [constant PART_SLOTS]) las mallas de [param scene], una pieza glTF
## importada con el BoneMap UAL, y quita las que tenía. No recrea el personaje: el nodo, el esqueleto, el
## animador y las armas se quedan, y si la ranura ya tiene esa escena no hace nada. Con [param scene] null es
## [method clear_part]. La capucha, las sombras y los tintes se aplican también a las mallas nuevas.
func set_part(slot: StringName, scene: PackedScene) -> void:
	if not PART_SLOTS.has(slot):
		push_warning("[HumanoidVisual] Ranura de pieza desconocida: %s" % slot)
		return
	if scene == null:
		clear_part(slot)
		return
	if not is_node_ready():
		_pending_parts[slot] = scene
		return
	if _skeleton == null:
		return
	if _part_paths.get(slot, "") == scene.resource_path and not scene.resource_path.is_empty():
		return
	_free_part(slot)
	_part_meshes[slot] = _attach_part(scene)
	_part_paths[slot] = scene.resource_path
	_apply_hood()
	_apply_shadow_casting()
	_apply_tints()
	_apply_camera_fade()


## Quita las mallas de la ranura [param slot] (sin pelo, sin barba...). No hace nada si ya estaba vacía.
func clear_part(slot: StringName) -> void:
	if not PART_SLOTS.has(slot):
		push_warning("[HumanoidVisual] Ranura de pieza desconocida: %s" % slot)
		return
	if not is_node_ready():
		_pending_parts[slot] = null
		return
	_free_part(slot)


## Las mallas de la ranura [param slot] (vacío si no tiene).
func get_part_meshes(slot: StringName) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for mesh: Variant in _part_meshes.get(slot, []):
		if is_instance_valid(mesh):
			result.append(mesh as MeshInstance3D)
	return result


## Ruta de la escena de la ranura [param slot] (vacía si no tiene ninguna).
func get_part_path(slot: StringName) -> String:
	return _part_paths.get(slot, "")


## Tiñe el canal [param channel] ([code]skin[/code], [code]hair[/code] o [code]eyes[/code], las claves de
## [constant TINT_MATERIAL_PREFIXES]) con [param color]: el albedo de sus materiales, multiplicado por su
## textura. Vale también para las piezas que se monten después.
func set_tint(channel: StringName, color: Color) -> void:
	if not TINT_MATERIAL_PREFIXES.has(channel):
		push_warning("[HumanoidVisual] Canal de tinte desconocido: %s" % channel)
		return
	_tints[channel] = color
	_apply_tints()


## Color del canal [param channel], o null si no se ha teñido.
func get_tint(channel: StringName) -> Variant:
	return _tints.get(channel)


## Quita todos los tintes (cada malla vuelve a su material).
func clear_tints() -> void:
	_tints.clear()
	_apply_tints()


## Pasa las mallas de una pieza al esqueleto del modelo base, descarta el resto de la pieza y devuelve las
## mallas colgadas.
func _attach_part(scene: PackedScene) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	if scene == null:
		return meshes
	var part: Node = scene.instantiate()
	_collect_meshes(part, meshes)
	if meshes.is_empty():
		push_warning("[HumanoidVisual] La pieza %s no tiene mallas" % scene.resource_path)
	for mesh: MeshInstance3D in meshes:
		mesh.get_parent().remove_child(mesh)
		mesh.owner = null
		_skeleton.add_child(mesh)
		mesh.transform = Transform3D.IDENTITY
		mesh.skeleton = mesh.get_path_to(_skeleton)
		mesh.reset_physics_interpolation()
	part.free()
	return meshes


func _free_part(slot: StringName) -> void:
	for mesh: Variant in _part_meshes.get(slot, []):
		if is_instance_valid(mesh):
			var node: MeshInstance3D = mesh as MeshInstance3D
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.queue_free()
	_part_meshes.erase(slot)
	_part_paths.erase(slot)


# Los materiales de cada malla del esqueleto según los tintes: el teñido del canal de su material base o, sin
# tinte, el suyo.
func _apply_tints() -> void:
	if _skeleton == null:
		return
	for child: Node in _skeleton.get_children():
		var mesh: MeshInstance3D = child as MeshInstance3D
		if mesh == null or mesh.mesh == null:
			continue
		for surface: int in range(mesh.mesh.get_surface_count()):
			var base: Material = mesh.mesh.surface_get_material(surface)
			var channel: StringName = _tint_channel_of(base)
			var result: Material = null
			if channel != &"" and _tints.has(channel):
				result = _tinted(base, _tints[channel])
			if _profile != null and _profile.changes_look():
				result = _profiled(result if result != null else base, _profile, channel == &"eyes")
			mesh.set_surface_override_material(surface, result)


static func _tint_channel_of(material: Material) -> StringName:
	if material == null or not (material is BaseMaterial3D):
		return &""
	for channel: StringName in TINT_MATERIAL_PREFIXES:
		for prefix: String in TINT_MATERIAL_PREFIXES[channel]:
			if material.resource_name.begins_with(prefix):
				return channel
	return &""


static func _tinted(base: Material, color: Color) -> Material:
	var key: String = "%d|%s" % [base.get_instance_id(), color.to_html()]
	var tinted: Material = _tinted_materials.get(key)
	if tinted == null:
		tinted = base.duplicate()
		(tinted as BaseMaterial3D).albedo_color = color
		_tinted_materials[key] = tinted
	return tinted


# Material de [param base] con el color del perfil de PNJ (ART-52) y, en los ojos, su brillo emisivo. Se comparten
# entre todos los PNJ del mismo perfil.
static func _profiled(base: Material, profile: NpcVisualProfile, is_eye: bool) -> Material:
	if not (base is BaseMaterial3D):
		return base
	var key: String = "p|%d|%s|%s" % [base.get_instance_id(), profile.id, is_eye]
	var made: Material = _tinted_materials.get(key)
	if made != null:
		return made
	var source: BaseMaterial3D = base as BaseMaterial3D
	if is_eye:
		if profile.eye_energy <= 0.0:
			return base
		var glow: BaseMaterial3D = source.duplicate() as BaseMaterial3D
		glow.emission_enabled = true
		glow.emission = profile.eye_glow
		glow.emission_energy_multiplier = profile.eye_energy
		glow.albedo_color = profile.eye_glow
		made = glow
	elif source.albedo_texture != null and (profile.saturation < 1.0 or profile.tint != Color.WHITE):
		# Con textura: desaturada y teñida por el sombreado de recoloreado.
		var shader := Shader.new()
		shader.code = NpcVisualProfile.RECOLOR_SHADER
		var recolored := ShaderMaterial.new()
		recolored.shader = shader
		recolored.set_shader_parameter(&"albedo_tex", source.albedo_texture)
		recolored.set_shader_parameter(&"tint", source.albedo_color * profile.tint)
		recolored.set_shader_parameter(&"saturation", profile.saturation)
		made = recolored
	else:
		var tinted: BaseMaterial3D = source.duplicate() as BaseMaterial3D
		tinted.albedo_color = tinted.albedo_color * profile.tint
		made = tinted
	_tinted_materials[key] = made
	return made


func _apply_hood() -> void:
	if _skeleton == null:
		return
	for child: Node in _skeleton.get_children():
		var mesh: MeshInstance3D = child as MeshInstance3D
		if mesh == null:
			continue
		if mesh.name.begins_with(HOOD_MESH_PREFIX):
			mesh.visible = hood_visible
		else:
			for prefix: String in HAIR_MESH_PREFIXES:
				if mesh.name.begins_with(prefix):
					mesh.visible = not hood_visible


func _apply_shadow_casting() -> void:
	for child: Node in _skeleton.get_children():
		var mesh: MeshInstance3D = child as MeshInstance3D
		if mesh == null:
			continue
		for prefix: String in NO_SHADOW_MESH_PREFIXES:
			if mesh.name.begins_with(prefix):
				mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


# Pone (o quita) el fundido de cámara en las mallas del visual: transparencia única por distancia al pecho.
func _apply_camera_fade() -> void:
	if not camera_fade and not _camera_fade_applied:
		return
	_camera_fade_applied = camera_fade
	_fade_meshes.clear()
	_collect_meshes(self, _fade_meshes)
	set_process(camera_fade)
	# Una sola distancia por visual (de la cámara al pecho): todas las mallas, también las armas, el escudo y las
	# botas, se atenúan por igual (antes, un rango de visibilidad por malla dejaba opacos los pies y el escudo).
	_fade_value = -1.0
	if camera_fade:
		_update_camera_fade()
	else:
		for mesh: MeshInstance3D in _fade_meshes:
			mesh.transparency = 0.0
			mesh.visibility_range_begin = 0.0
			mesh.visibility_range_begin_margin = 0.0
			mesh.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED


func _process(_delta: float) -> void:
	if camera_fade:
		_update_camera_fade()


## Transparencia (0 = opaco, 1 = invisible) de un visual con el pecho a [param distance] m de la cámara.
static func fade_for_distance(distance: float) -> float:
	return clampf(inverse_lerp(CAMERA_FADE_SOLID, CAMERA_FADE_HIDDEN, distance), 0.0, 1.0)


## Transparencia que llevan ahora las mallas por el fundido de cámara (0 si no hay).
func get_camera_fade_value() -> float:
	return maxf(_fade_value, 0.0)


func _update_camera_fade() -> void:
	var camera: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return
	var chest: Vector3 = global_position + Vector3.UP * CAMERA_FADE_CHEST_HEIGHT
	var value: float = fade_for_distance(camera.global_position.distance_to(chest))
	if is_equal_approx(value, _fade_value):
		return
	_fade_value = value
	for mesh: MeshInstance3D in _fade_meshes:
		if is_instance_valid(mesh):
			mesh.transparency = value


static func _find_skeleton(root: Node) -> Skeleton3D:
	var found: Node = root.find_child(SKELETON_NAME, true, false)
	if found is Skeleton3D:
		return found as Skeleton3D
	return null


static func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		_collect_meshes(child, out)
