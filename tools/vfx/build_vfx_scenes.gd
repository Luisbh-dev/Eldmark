extends SceneTree
## Genera las escenas y los materiales de los efectos de golpe (ART-09) en [code]res://scenes/vfx/[/code].
##
## Cada efecto se monta con código (nodos, materiales de partículas, rampas de color y curvas) y se
## guarda como [code].tscn[/code] / [code].tres[/code] de texto, así que todos los números de abajo son los
## que hay que tocar para afinar un efecto y volver a generarlo; nada se retoca a mano en los .tscn.
## Los materiales de la carpeta se borran y se vuelven a escribir en cada ejecución: lo que ya no se usa no
## se queda.
## [br][br]
## Orden completo (desde la raíz del proyecto, con el editor cerrado):
## [codeblock]
## python tools/vfx/make_vfx_textures.py
## godot --headless --path . --import
## godot --headless --path . -s res://tools/vfx/build_vfx_scenes.gd
## godot --headless --path . --import
## [/codeblock]
## Escenas: [code]hit_metal_spark[/code], [code]hit_flesh[/code], [code]hit_cloth[/code],
## [code]hit_block_wood[/code], [code]parry_flash[/code], [code]dust_kick[/code], [code]weapon_trail[/code] y
## [code]charge_aura[/code]. Convenciones de orientación y metadatos de los hijos: ver [VfxEffect].
##
## [b]Tamaños[/b]: están pensados para la cámara del juego (campo de visión de 72 grados, por encima del
## hombro, a 3,5 m del personaje y 5 a 6 m del rival): a esa distancia un metro son unos 140 a 210 píxeles
## de una pantalla de 1080. Lo que se mide en metros aquí es lo que se ve.

const SCENES_DIR: String = "res://scenes/vfx/"
const MATERIALS_DIR: String = "res://scenes/vfx/materials/"
const SHADERS_DIR: String = "res://scenes/vfx/shaders/"
const TEXTURES_DIR: String = "res://scenes/vfx/textures/"

const EFFECT_SCRIPT: String = "res://scripts/client/vfx/vfx_effect.gd"
const TRAIL_SCRIPT: String = "res://scripts/client/vfx/weapon_trail.gd"
const AURA_SCRIPT: String = "res://scripts/client/vfx/charge_aura.gd"
const DUST_SCRIPT: String = "res://scripts/client/vfx/dust_kick.gd"

const PARTICLE_ADD: String = "vfx_particle_add"
const PARTICLE_MIX: String = "vfx_particle_mix"
const PARTICLE_LIT: String = "vfx_particle_lit"
const SHAPE_ADD: String = "vfx_shape_add"
const SHAPE_MIX: String = "vfx_shape_mix"
const GROUND_MIX: String = "vfx_ground_mix"
const TRAIL: String = "vfx_trail"
const BLADE_GLOW: String = "vfx_blade_glow"
const HEAT: String = "vfx_heat"

const ALIGN_VELOCITY: int = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
## Cuánto tapan el fondo los materiales de luz (0 = aditivo puro, 1 = mezcla normal). Con un cielo claro un
## brillo aditivo se lava; un poco de cobertura le da color y contraste (ver vfx_particle_add.gdshader).
const COVER: Dictionary = {
	"shape_flash_metal": 0.15, "shape_glow_metal": 0.25, "shape_flash_wood": 0.15, "shape_ring_block": 0.35,
	"shape_flash_parry": 0.15, "shape_rays_parry": 0.3, "shape_lens_parry": 0.25, "shape_core_parry": 0.2,
	"shape_ring_parry": 0.4, "shape_flash_aura": 0.2, "shape_flash_release": 0.2, "shape_wave_aura": 0.4,
	"shape_wave_release": 0.4, "shape_rune": 0.45, "mote_streak": 0.2, "ember_glow": 0.3, "glint_star": 0.15,
	"spark_streak": 0.1, "spark_streak_parry": 0.1, "spark_streak_aura": 0.15,
}

const SHAPE_FLASH: int = 0
const SHAPE_RING: int = 1
const SHAPE_RAYS: int = 2
const SHAPE_GLOW: int = 3
const SHAPE_RUNE: int = 4
const SHAPE_LENS: int = 5

## Longitud de la hoja (m) sobre la que se monta el brillo del aura: de la empuñadura a la punta de la
## espada provisional (ver WeaponProps). El eje +X del nodo Blade es la hoja.
const BLADE_BASE: float = 0.12
const BLADE_TIP: float = 1.12


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCENES_DIR))
	# Con --solo-habilidades solo se genera lo que añadió la oleada 4 (el muro de escudos), sin borrar ni reescribir
	# los materiales de los demás efectos (los .tres conservan su uid).
	if OS.get_cmdline_user_args().has("--solo-habilidades"):
		_build_shield_wall()
		print("[vfx] Escena del muro de escudos generada en %s" % SCENES_DIR)
		quit(0)
		return
	_clean_materials()
	_build_metal_spark()
	_build_flesh()
	_build_cloth()
	_build_block_wood()
	_build_parry()
	_build_dust()
	_build_trail()
	_build_aura()
	_build_shield_wall()
	print("[vfx] Escenas generadas en %s" % SCENES_DIR)
	quit(0)


# Borra los materiales de la carpeta: se vuelven a escribir los que usan las escenas de esta ejecución.
func _clean_materials() -> void:
	var directory: String = ProjectSettings.globalize_path(MATERIALS_DIR)
	DirAccess.make_dir_recursive_absolute(directory)
	for file: String in DirAccess.get_files_at(directory):
		if file.ends_with(".tres"):
			DirAccess.remove_absolute(directory.path_join(file))


# --- Efectos ------------------------------------------------------------------------------------

# Chispa de metal: punto incandescente de contacto, destello con puntas, chispas con cola que salen en un
# cono desviado en el sentido del tajo, esquirlas al rojo que caen y un hilo de humo.
func _build_metal_spark() -> void:
	var root: VfxEffect = _effect("HitMetalSpark", 0.9)
	# Las chispas de un tajo salen desviadas hacia donde iba el filo.
	root.direction_bias = 0.8

	var glow: MeshInstance3D = _shape(root, "ContactGlow", Vector2.ONE * 0.34, _mat("shape_glow_metal", SHAPE_ADD, {
		"mode": SHAPE_GLOW, "tex": _tex("soft_dot"), "intensity": 5.5, "start_scale": 0.45,
		"end_scale": 1.0, "fade_power": 1.6, "attack": 0.1, "push": 0.05,
	}), Vector2(0.0, 0.06), Color(1.0, 0.93, 0.72), 0.25)
	glow.position = Vector3(0.0, 0.0, 0.03)

	var flash: MeshInstance3D = _shape(root, "Flash", Vector2.ONE * 0.8, _mat("shape_flash_metal", SHAPE_ADD, {
		"mode": SHAPE_FLASH, "tex": _tex("flare_star"), "intensity": 3.0, "start_scale": 0.35,
		"end_scale": 1.2, "spin": 0.7, "fade_power": 2.2, "attack": 0.06, "push": 0.08,
	}), Vector2(0.0, 0.14), Color(1.0, 0.84, 0.55), 0.25)
	flash.position = Vector3(0.0, 0.0, 0.04)

	# Cono estrecho, con frenazo fuerte: ninguna chispa pasa de metro y medio ni sube por encima de la cabeza.
	var sparks_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0, 1), "spread": 36.0, "initial_velocity_min": 2.6,
		"initial_velocity_max": 5.8, "damping_min": 9.0, "damping_max": 14.0,
		"gravity": Vector3(0, -10.0, 0), "scale_min": 0.6, "scale_max": 1.2,
		"scale_curve": _curve([[0.0, 1.0], [0.55, 0.85], [1.0, 0.25]]),
		"color_ramp": _ramp([[0.0, Color(1, 0.97, 0.8, 1)], [0.14, Color(1, 0.74, 0.3, 1)],
				[0.5, Color(1, 0.4, 0.08, 0.95)], [1.0, Color(0.7, 0.12, 0.02, 0.0)]]),
	})
	_particles(root, "Sparks", 30, 0.4, sparks_proc, _quad(Vector2(0.04, 0.26),
			_mat("spark_streak", PARTICLE_ADD, {"tex": _tex("spark_streak"), "aligned_by_engine": true,
			"intensity": 2.8, "fade_in": 0.02, "fade_out_start": 0.5})), {
		"transform_align": ALIGN_VELOCITY, "explosiveness": 0.97, "randomness": 0.55,
		"lifetime_randomness": 0.3,
	})

	var shards_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0.2, 1), "spread": 50.0, "initial_velocity_min": 1.6,
		"initial_velocity_max": 4.2, "damping_min": 1.5, "damping_max": 3.0,
		"gravity": Vector3(0, -14.0, 0), "angle_min": 0.0, "angle_max": 360.0,
		"angular_velocity_min": -900.0, "angular_velocity_max": 900.0, "scale_min": 0.5,
		"scale_max": 1.1, "anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [0.7, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 0)]]),
	})
	_particles(root, "Shards", 9, 0.7, shards_proc, _quad(Vector2(0.09, 0.09),
			_mat("shard_metal", PARTICLE_MIX, {"tex": _tex("shards"), "h_frames": 2, "v_frames": 2,
			"brightness": 1.0, "shade_contrast": 1.0, "hot_color": Color(1.0, 0.55, 0.18, 2.4),
			"hot_decay": 6.5, "fade_in": 0.02, "fade_out_start": 0.7})), {
		"explosiveness": 1.0, "randomness": 0.4, "lifetime_randomness": 0.3,
		"meta_tint": Color(0.74, 0.78, 0.86), "tint_weight": 0.15,
	})

	var smoke_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0.5, 1), "spread": 40.0, "initial_velocity_min": 0.15,
		"initial_velocity_max": 0.6, "damping_min": 0.6, "damping_max": 1.2,
		"gravity": Vector3(0, 0.5, 0), "angle_min": 0.0, "angle_max": 360.0,
		"angular_velocity_min": -40.0, "angular_velocity_max": 40.0, "scale_min": 0.6,
		"scale_max": 1.0, "scale_curve": _curve([[0.0, 0.4], [1.0, 1.5]], 2.0),
		"anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 1)]]),
	})
	_particles(root, "Smoke", 2, 0.7, smoke_proc, _quad(Vector2(0.2, 0.2),
			_mat("puff_smoke", PARTICLE_LIT, {"tex": _tex("puffs"), "opacity": 0.5, "soft_distance": 0.2,
			"erode_end": 0.85})), {
		"explosiveness": 0.9, "draw_order": GPUParticles3D.DRAW_ORDER_VIEW_DEPTH,
		"meta_tint": Color(0.55, 0.55, 0.57), "tint_weight": 0.0,
	})
	_save(root, "hit_metal_spark")


# Impacto en carne: dos chorros de salpicadura, en una secuencia corta de cinco fotogramas y de menos de 0,4 m,
# orientados en la dirección del golpe (el +X del efecto), y unas gotas que no van más lejos que ellos.
# Rojo oscuro y poco saturado, con brillo. El color del conjunto es [member VfxEffect.tint].
func _build_flesh() -> void:
	var root: VfxEffect = _effect("HitFlesh", 0.4)
	root.tint = Color(0.4, 0.12, 0.12)

	var jet_mat: ShaderMaterial = _mat("shape_jet", SHAPE_MIX, {
		"tex": _tex("splat_jets"), "frames": 5, "variants": 4, "pivot": Vector2(0.17, 0.0),
		"brightness": 0.85, "spec_strength": 0.7, "fade_start": 0.65, "opacity": 0.95,
	})
	var main_jet: MeshInstance3D = _shape(root, "Jet", Vector2.ONE * 0.46, jet_mat, Vector2(0.0, 0.2),
			Color.WHITE, 1.0)
	main_jet.set_meta(VfxEffect.META_VARIANTS, 4)
	main_jet.position = Vector3(0.0, 0.0, 0.03)
	# Un segundo chorro más corto, girado, que sale un poco después: no es una estrella simétrica.
	var side_jet: MeshInstance3D = _shape(root, "JetSide", Vector2.ONE * 0.3, jet_mat, Vector2(0.04, 0.18),
			Color(1.0, 0.92, 0.9), 1.0)
	side_jet.set_meta(VfxEffect.META_VARIANTS, 4)
	side_jet.set_meta(VfxEffect.META_VARIANT_OFFSET, 2)
	side_jet.rotation_degrees = Vector3(0.0, 0.0, -32.0)
	side_jet.position = Vector3(0.0, 0.0, 0.035)

	var drops_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(1, 0, 0.35), "spread": 32.0, "initial_velocity_min": 0.8,
		"initial_velocity_max": 1.6, "damping_min": 2.0, "damping_max": 4.0,
		"gravity": Vector3(0, -9.0, 0), "scale_min": 0.6, "scale_max": 1.2,
		"scale_curve": _curve([[0.0, 1.0], [0.6, 0.85], [1.0, 0.35]]),
		"anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [0.7, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 0)]]),
	})
	_particles(root, "Drops", 9, 0.3, drops_proc, _quad(Vector2(0.04, 0.04),
			_mat("droplet", PARTICLE_MIX, {"tex": _tex("droplets"), "h_frames": 2, "v_frames": 2,
			"aligned_by_engine": true, "brightness": 0.9, "fade_in": 0.02, "fade_out_start": 0.7})), {
		"transform_align": ALIGN_VELOCITY, "explosiveness": 1.0, "randomness": 0.5,
		"lifetime_randomness": 0.25,
	})
	_save(root, "hit_flesh")


# Impacto en tela: una bocanada de polvo claro (con luz) y unas hilachas que se sueltan y caen despacio.
func _build_cloth() -> void:
	var root: VfxEffect = _effect("HitCloth", 0.65)
	root.tint = Color(0.82, 0.77, 0.68)

	var puff_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0.2, 1), "spread": 50.0, "initial_velocity_min": 0.4,
		"initial_velocity_max": 1.1, "damping_min": 1.6, "damping_max": 2.6, "angle_min": 0.0,
		"angle_max": 360.0, "angular_velocity_min": -50.0, "angular_velocity_max": 50.0,
		"scale_min": 0.6, "scale_max": 1.0, "scale_curve": _curve([[0.0, 0.45], [1.0, 1.4]], 2.0),
		"anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 1)]]),
	})
	_particles(root, "Puff", 4, 0.55, puff_proc, _quad(Vector2(0.34, 0.34),
			_mat("puff_cloth", PARTICLE_LIT, {"tex": _tex("puffs"), "opacity": 0.6, "soft_distance": 0.15,
			"erode_end": 0.85})), {
		"explosiveness": 1.0, "draw_order": GPUParticles3D.DRAW_ORDER_VIEW_DEPTH,
	})

	var fibers_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0.15, 1), "spread": 62.0, "initial_velocity_min": 0.9,
		"initial_velocity_max": 2.3, "damping_min": 1.6, "damping_max": 2.8,
		"gravity": Vector3(0, -2.0, 0), "angle_min": 0.0, "angle_max": 360.0,
		"angular_velocity_min": -220.0, "angular_velocity_max": 220.0, "scale_min": 0.6,
		"scale_max": 1.2, "anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [0.7, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 0)]]),
	})
	_particles(root, "Fibers", 9, 0.6, fibers_proc, _quad(Vector2(0.14, 0.14),
			_mat("fibers", PARTICLE_MIX, {"tex": _tex("fibers"), "h_frames": 2, "v_frames": 2,
			"brightness": 1.0, "shade_contrast": 0.8, "fade_in": 0.02, "fade_out_start": 0.65})), {
		"explosiveness": 1.0, "randomness": 0.5, "lifetime_randomness": 0.3,
	})
	_save(root, "hit_cloth")


# Impacto bloqueado en un escudo de madera: un golpe sordo. Destello apagado y adelantado hacia la cámara
# (no lo corta el escudo), medio anillo aplanado sobre la cara del escudo, tablillas planas de dos tonos
# que saltan y un poco de polvo de madera pardo.
func _build_block_wood() -> void:
	var root: VfxEffect = _effect("HitBlockWood", 0.6)

	_shape(root, "Flash", Vector2.ONE * 0.55, _mat("shape_flash_wood", SHAPE_ADD, {
		"mode": SHAPE_FLASH, "tex": _tex("flare_star"), "intensity": 1.9, "start_scale": 0.4,
		"end_scale": 0.85, "spin": 0.3, "fade_power": 2.4, "attack": 0.06, "push": 0.2,
	}), Vector2(0.0, 0.1), Color(1.0, 0.82, 0.55), 0.4)

	# Medio anillo (la mitad de arriba), aplanado, sobre el plano del escudo: la normal del impacto.
	var ring: MeshInstance3D = _shape(root, "HalfRing", Vector2.ONE * 0.92, _mat("shape_ring_block", SHAPE_ADD, {
		"mode": SHAPE_RING, "billboard": false, "noise_tex": _tex("noise"), "intensity": 1.8,
		"ring_start_radius": 0.25, "ring_width_start": 0.1, "ring_width_end": 0.04, "ring_line": 0.04,
		"ring_tail": 0.3, "ring_arc": 0.52, "ring_squash": 0.62, "fade_power": 1.4, "attack": 0.04,
		"push": 0.02,
	}), Vector2(0.0, 0.18), Color(1.0, 0.84, 0.58), 0.5)
	ring.position = Vector3(0.0, -0.02, 0.03)

	var splinters_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0.2, 1), "spread": 58.0, "initial_velocity_min": 1.2,
		"initial_velocity_max": 3.2, "damping_min": 2.0, "damping_max": 4.0,
		"gravity": Vector3(0, -12.0, 0), "angle_min": 0.0, "angle_max": 360.0,
		"angular_velocity_min": -420.0, "angular_velocity_max": 420.0, "scale_min": 0.6,
		"scale_max": 1.2, "scale_curve": _curve([[0.0, 1.0], [0.75, 1.0], [1.0, 0.6]]),
		"anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [0.72, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 0)]]),
	})
	_particles(root, "Splinters", 10, 0.5, splinters_proc, _quad(Vector2(0.15, 0.15),
			_mat("splinter", PARTICLE_MIX, {"tex": _tex("planks"), "h_frames": 2, "v_frames": 2,
			"brightness": 1.0, "shade_contrast": 1.0, "accent": Color(0.9, 0.72, 0.46),
			"accent_amount": 1.0, "fade_in": 0.02, "fade_out_start": 0.7})), {
		"explosiveness": 1.0, "randomness": 0.45, "lifetime_randomness": 0.3,
		"meta_tint": Color(0.62, 0.4, 0.22), "tint_weight": 0.2,
	})

	var dust_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0.25, 1), "spread": 55.0, "initial_velocity_min": 0.4,
		"initial_velocity_max": 1.2, "damping_min": 1.6, "damping_max": 2.6, "angle_min": 0.0,
		"angle_max": 360.0, "angular_velocity_min": -50.0, "angular_velocity_max": 50.0,
		"scale_min": 0.6, "scale_max": 1.0, "scale_curve": _curve([[0.0, 0.5], [1.0, 1.4]], 2.0),
		"anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 1)]]),
	})
	_particles(root, "Dust", 3, 0.5, dust_proc, _quad(Vector2(0.32, 0.32),
			_mat("puff_wood_dust", PARTICLE_LIT, {"tex": _tex("puffs"), "opacity": 0.7, "soft_distance": 0.2,
			"erode_end": 0.85})), {
		"explosiveness": 1.0, "draw_order": GPUParticles3D.DRAW_ORDER_VIEW_DEPTH,
		"meta_tint": Color(0.62, 0.46, 0.3), "tint_weight": 0.0,
	})
	_save(root, "hit_block_wood")


# Parada perfecta: estrella blanca con rayos y una raya horizontal de lente, una onda de choque fina y
# rápida sobre el plano del impacto, chispas radiales y titileos. Nada de relleno: el rival se ve. En menos
# de un cuarto de segundo.
func _build_parry() -> void:
	var root: VfxEffect = _effect("ParryFlash", 0.25)
	root.tint = Color(1.0, 0.97, 0.9)

	_shape(root, "Rays", Vector2.ONE * 1.5, _mat("shape_rays_parry", SHAPE_ADD, {
		"mode": SHAPE_RAYS, "tex": _tex("rays"), "intensity": 3.0, "start_scale": 0.3,
		"end_scale": 1.0, "spin": 0.6, "fade_power": 1.6, "attack": 0.05, "push": 0.12,
	}), Vector2(0.0, 0.2), Color(1.0, 0.95, 0.82), 0.6)

	_shape(root, "Flash", Vector2.ONE * 1.0, _mat("shape_flash_parry", SHAPE_ADD, {
		"mode": SHAPE_FLASH, "tex": _tex("flare_star"), "intensity": 3.4, "start_scale": 0.4,
		"end_scale": 1.0, "spin": -0.5, "fade_power": 1.6, "attack": 0.04, "push": 0.15,
	}), Vector2(0.0, 0.17), Color(0.96, 0.98, 1.0), 0.4)

	_shape(root, "Lens", Vector2(2.4, 0.36), _mat("shape_lens_parry", SHAPE_ADD, {
		"mode": SHAPE_LENS, "intensity": 3.4, "start_scale": 0.3, "end_scale": 1.0, "fade_power": 1.5,
		"attack": 0.04, "lens_thick_start": 0.24, "lens_thick_end": 0.05, "push": 0.14,
	}), Vector2(0.0, 0.2), Color(0.92, 0.96, 1.0), 0.35)

	# Un núcleo pequeño y corto, solo para el punto de choque: nada que tape la cara del rival.
	_shape(root, "Core", Vector2.ONE * 0.4, _mat("shape_core_parry", SHAPE_ADD, {
		"mode": SHAPE_GLOW, "tex": _tex("soft_dot"), "intensity": 3.0, "start_scale": 0.5,
		"end_scale": 1.0, "fade_power": 1.4, "attack": 0.08, "push": 0.15,
	}), Vector2(0.0, 0.07), Color(1.0, 1.0, 1.0), 0.0)

	# Onda de choque: un filo fino que se abre rápido sobre el plano del impacto (no mira a la cámara).
	_shape(root, "Shockwave", Vector2.ONE * 1.5, _mat("shape_ring_parry", SHAPE_ADD, {
		"mode": SHAPE_RING, "billboard": false, "noise_tex": _tex("noise"), "intensity": 3.4,
		"ring_start_radius": 0.2, "ring_width_start": 0.08, "ring_width_end": 0.025, "ring_line": 0.026,
		"ring_tail": 0.4, "fade_power": 1.2, "attack": 0.02, "push": 0.03,
	}), Vector2(0.0, 0.18), Color(1.0, 0.99, 0.95), 0.3)

	var sparks_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0, 1), "spread": 150.0, "initial_velocity_min": 3.0,
		"initial_velocity_max": 7.0, "damping_min": 11.0, "damping_max": 17.0,
		"gravity": Vector3(0, -3.5, 0), "scale_min": 0.6, "scale_max": 1.2,
		"scale_curve": _curve([[0.0, 1.0], [1.0, 0.2]]),
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [0.35, Color(1, 0.92, 0.6, 1)],
				[1.0, Color(1, 0.6, 0.2, 0)]]),
	})
	_particles(root, "Sparks", 24, 0.25, sparks_proc, _quad(Vector2(0.03, 0.24),
			_mat("spark_streak_parry", PARTICLE_ADD, {"tex": _tex("spark_streak"),
			"aligned_by_engine": true, "intensity": 4.0, "fade_in": 0.02, "fade_out_start": 0.5})), {
		"transform_align": ALIGN_VELOCITY, "explosiveness": 1.0, "randomness": 0.5,
		"lifetime_randomness": 0.25, "meta_tint": Color(1.0, 0.96, 0.85), "tint_weight": 0.3,
	})

	var glints_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0, 1), "spread": 120.0, "initial_velocity_min": 0.6,
		"initial_velocity_max": 2.0, "damping_min": 4.0, "damping_max": 8.0, "angle_min": -20.0,
		"angle_max": 20.0, "scale_min": 0.5, "scale_max": 1.0,
		"scale_curve": _curve([[0.0, 0.0], [0.25, 1.0], [0.6, 0.4], [1.0, 0.0]]),
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [1.0, Color(1, 0.9, 0.6, 1)]]),
	})
	_particles(root, "Glints", 7, 0.25, glints_proc, _quad(Vector2(0.24, 0.24),
			_mat("glint_star", PARTICLE_ADD, {"tex": _tex("flare_star"), "intensity": 3.4,
			"fade_in": 0.02, "fade_out_start": 0.5})), {
		"explosiveness": 0.8, "randomness": 0.6, "meta_tint": Color(1.0, 0.95, 0.8),
		"tint_weight": 0.3,
	})
	_save(root, "parry_flash")


# Muro de escudos (habilidad de espada y escudo): un arco de luz de frente a quien se acerca, con el borde del color
# del reino (tinte completo), un relleno tenue, un destello al levantarlo y motas que suben. El eje +Z es hacia
# donde mira el portador; el arco es la mitad alta de un aro que se queda de pie delante del escudo.
func _build_shield_wall() -> void:
	var root: VfxEffect = _effect("ShieldWall", 0.9)
	root.tint = Color(0.8, 0.88, 1.0)

	_shape(root, "Arch", Vector2.ONE * 2.6, _mat("shape_arch_wall", SHAPE_ADD, {
		"mode": SHAPE_RING, "billboard": false, "noise_tex": _tex("noise"), "intensity": 2.4,
		"ring_start_radius": 0.62, "ring_width_start": 0.10, "ring_width_end": 0.07, "ring_line": 0.055,
		"ring_tail": 0.5, "ring_fill": 0.28, "ring_arc": 0.5, "ring_squash": 0.78, "fade_power": 0.9,
		"attack": 0.08, "push": 0.0, "start_scale": 0.9, "end_scale": 1.0,
	}), Vector2(0.0, 0.85), Color(1.0, 1.0, 1.0), 1.0)

	_shape(root, "ArchInner", Vector2.ONE * 2.0, _mat("shape_arch_wall_inner", SHAPE_ADD, {
		"mode": SHAPE_RING, "billboard": false, "noise_tex": _tex("noise"), "intensity": 1.6,
		"ring_start_radius": 0.62, "ring_width_start": 0.05, "ring_width_end": 0.03, "ring_line": 0.03,
		"ring_tail": 0.0, "ring_fill": 0.0, "ring_arc": 0.5, "ring_squash": 0.78, "fade_power": 1.2,
		"attack": 0.1, "push": 0.0, "start_scale": 0.9, "end_scale": 1.0,
	}), Vector2(0.05, 0.7), Color(1.0, 1.0, 1.0), 0.8)

	_shape(root, "Flash", Vector2.ONE * 1.3, _mat("shape_flash_wall", SHAPE_ADD, {
		"mode": SHAPE_FLASH, "tex": _tex("flare_star"), "intensity": 3.0, "start_scale": 0.4,
		"end_scale": 1.0, "spin": 0.4, "fade_power": 1.6, "attack": 0.05, "push": 0.1,
	}), Vector2(0.0, 0.22), Color(1.0, 0.97, 0.9), 0.35)

	var motes_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 1, 0), "spread": 40.0, "initial_velocity_min": 0.5,
		"initial_velocity_max": 1.4, "damping_min": 1.0, "damping_max": 2.0,
		"gravity": Vector3(0, 0.3, 0), "scale_min": 0.5, "scale_max": 1.0,
		"scale_curve": _curve([[0.0, 0.0], [0.2, 1.0], [1.0, 0.0]]),
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 0)]]),
	})
	_particles(root, "Motes", 18, 0.7, motes_proc, _quad(Vector2(0.09, 0.09),
			_mat("mote_wall", PARTICLE_ADD, {"tex": _tex("soft_dot"), "intensity": 3.2,
			"fade_in": 0.05, "fade_out_start": 0.4})), {
		"explosiveness": 0.6, "randomness": 0.6, "meta_tint": Color(1.0, 1.0, 1.0), "tint_weight": 0.9,
	})
	_save(root, "shield_wall")


# Polvo al esquivar o aterrizar. El eje +Z del efecto es el suelo hacia arriba y el +Y, hacia atrás (contrario
# al movimiento, en la esquiva). Aterrizaje (aviso [code]landing[/code]): bocanadas bajas en anillo y, solo si
# la caída es fuerte, un anillo bajo de 1,2 m. Esquiva (aviso [code]dodge[/code]): una media luna pegada al
# suelo y una rociada de bocanadas hacia atrás, sin anillo. Las bocanadas tienen luz y sombra.
func _build_dust() -> void:
	var root: VfxEffect = _effect("DustKick", 0.9, DUST_SCRIPT)
	root.tint = VfxPalette.ground(&"dirt")

	var ring: MeshInstance3D = _shape(root, "Ring", Vector2.ONE * 1.2, _mat("shape_ring_dust", GROUND_MIX, {
		"mode": 0, "tex": _tex("ring_dust"), "noise_tex": _tex("noise"), "start_scale": 0.35,
		"end_scale": 1.0, "grow_speed": 3.0, "hold": 0.12, "erosion": 0.7, "soft_distance": 0.12,
		"opacity": 0.3, "brightness": 1.3,
	}), Vector2(0.0, 0.55), Color.WHITE, 1.0)
	ring.position = Vector3(0.0, 0.0, 0.03)
	ring.set_meta(VfxEffect.META_CUE, &"landing")

	var puffs_proc: ParticleProcessMaterial = _proc({
		"emission_shape": ParticleProcessMaterial.EMISSION_SHAPE_RING,
		"emission_ring_axis": Vector3(0, 0, 1), "emission_ring_radius": 0.3,
		"emission_ring_inner_radius": 0.1, "emission_ring_height": 0.03,
		"direction": Vector3(0, 0, 1), "spread": 8.0, "initial_velocity_min": 0.08,
		"initial_velocity_max": 0.3, "radial_velocity_min": 0.8, "radial_velocity_max": 1.9,
		"damping_min": 1.0, "damping_max": 2.0, "gravity": Vector3(0, 0.15, 0),
		"angle_min": 0.0, "angle_max": 360.0, "angular_velocity_min": -35.0,
		"angular_velocity_max": 35.0, "scale_min": 0.55, "scale_max": 1.0,
		"scale_curve": _curve([[0.0, 0.4], [0.35, 1.0], [1.0, 1.3]], 2.0),
		"anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 1)]]),
	})
	var puff_mat: ShaderMaterial = _mat("puff_dust", PARTICLE_LIT, {"tex": _tex("puffs"), "opacity": 0.7,
			"soft_distance": 0.3, "hold": 0.2, "erode_end": 0.84})
	_particles(root, "Puffs", 9, 0.9, puffs_proc, _quad(Vector2(0.5, 0.5), puff_mat), {
		"explosiveness": 1.0, "randomness": 0.4, "lifetime_randomness": 0.3,
		"draw_order": GPUParticles3D.DRAW_ORDER_VIEW_DEPTH, "cue": &"landing",
	})

	var grit_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0, 1), "spread": 62.0, "initial_velocity_min": 0.8,
		"initial_velocity_max": 2.4, "damping_min": 0.4, "damping_max": 1.0,
		"gravity": Vector3(0, -12.0, 0), "scale_min": 0.6, "scale_max": 1.3,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [0.7, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 0)]]),
	})
	_particles(root, "Grit", 7, 0.45, grit_proc, _quad(Vector2(0.03, 0.03),
			_mat("grit", PARTICLE_MIX, {"tex": _tex("soft_dot"), "brightness": 0.9,
			"fade_in": 0.02, "fade_out_start": 0.75})), {
		"explosiveness": 1.0, "randomness": 0.5, "meta_tint": Color(0.36, 0.31, 0.26),
		"tint_weight": 0.35, "cue": &"landing",
	})

	# Esquiva: media luna de polvo pegada al suelo, gruesa por detrás del cuerpo.
	var crescent: MeshInstance3D = _shape(root, "Crescent", Vector2.ONE * 1.5, _mat("shape_crescent", GROUND_MIX, {
		"mode": 1, "noise_tex": _tex("noise"), "start_scale": 0.35, "end_scale": 1.0, "grow_speed": 2.6,
		"hold": 0.15, "erosion": 0.8, "soft_distance": 0.1, "opacity": 0.42, "brightness": 0.85, "drift": 0.3,
	}), Vector2(0.0, 0.5), Color.WHITE, 1.0)
	crescent.position = Vector3(0.0, 0.1, 0.04)
	crescent.set_meta(VfxEffect.META_CUE, &"dodge")

	var spray_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 1, 0.18), "spread": 22.0, "initial_velocity_min": 1.2,
		"initial_velocity_max": 3.0, "damping_min": 2.4, "damping_max": 4.0,
		"gravity": Vector3(0, 0.25, 0), "angle_min": 0.0, "angle_max": 360.0,
		"angular_velocity_min": -45.0, "angular_velocity_max": 45.0, "scale_min": 0.5,
		"scale_max": 1.0, "scale_curve": _curve([[0.0, 0.4], [0.4, 1.0], [1.0, 1.35]], 2.0),
		"anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 1)]]),
	})
	_particles(root, "Spray", 7, 0.75, spray_proc, _quad(Vector2(0.44, 0.44), puff_mat), {
		"explosiveness": 0.7, "randomness": 0.4, "draw_order": GPUParticles3D.DRAW_ORDER_VIEW_DEPTH,
		"cue": &"dodge",
	})
	var kicked_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0.8, 0.5), "spread": 40.0, "initial_velocity_min": 0.8,
		"initial_velocity_max": 2.4, "damping_min": 0.4, "damping_max": 1.0,
		"gravity": Vector3(0, -10.0, 0.0), "scale_min": 0.6, "scale_max": 1.3,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [0.7, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 0)]]),
	})
	_particles(root, "KickedGrit", 5, 0.4, kicked_proc, _quad(Vector2(0.03, 0.03),
			_mat("grit", PARTICLE_MIX, {"tex": _tex("soft_dot"), "brightness": 0.9,
			"fade_in": 0.02, "fade_out_start": 0.75})), {
		"explosiveness": 1.0, "randomness": 0.5, "meta_tint": Color(0.36, 0.31, 0.26),
		"tint_weight": 0.35, "cue": &"dodge",
	})
	_save(root, "dust_kick")


# Estela del arma: la malla la rellena WeaponTrail cada fotograma; aquí solo van el material y el script.
func _build_trail() -> void:
	var root: MeshInstance3D = MeshInstance3D.new()
	root.name = "WeaponTrail"
	root.set_script(load(TRAIL_SCRIPT))
	root.material_override = _mat("weapon_trail", TRAIL, {"noise_tex": _tex("noise")})
	root.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_save(root, "weapon_trail")


# Aura de carga del golpe fuerte, concentrada en el arma: una franja de luz a lo largo de la hoja que crece con
# la carga, motas y brasas que la hoja absorbe y una distorsión de calor con casi toda la carga; en el suelo, la
# runa que se cierra. A carga completa, destello en la hoja y una onda plana en el suelo; al soltar, estallido.
# Lo que va en la hoja cuelga de [code]Blade[/code] (su +X es la hoja), que ChargeAura cuelga del arma.
func _build_aura() -> void:
	var root: VfxEffect = _effect("ChargeAura", 0.5, AURA_SCRIPT)
	root.looping = true

	var rune: MeshInstance3D = _flat_quad(root, "Rune", Vector2.ONE * 2.4, _mat("shape_rune", SHAPE_ADD, {
		"mode": SHAPE_RUNE, "billboard": false, "intensity": 2.4, "runes": 14.0,
	}))
	rune.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	rune.position = Vector3(0.0, 0.04, 0.0)
	rune.set_meta(&"vfx_charge", &"progress")

	var blade: Node3D = Node3D.new()
	blade.name = "Blade"
	root.add_child(blade)
	var middle: float = (BLADE_BASE + BLADE_TIP) * 0.5
	var length: float = BLADE_TIP - BLADE_BASE

	var glow: MeshInstance3D = _flat_quad(blade, "BladeGlow", Vector2(length, 0.6), _mat("blade_glow", BLADE_GLOW, {
		"noise_tex": _tex("noise"), "intensity": 3.2, "cover": 0.4,
	}))
	glow.position = Vector3(middle, 0.0, 0.0)
	glow.set_meta(&"vfx_charge", &"charge")

	var heat: MeshInstance3D = _flat_quad(blade, "Heat", Vector2.ONE * 1.5, _mat("heat_haze", HEAT, {
		"noise_tex": _tex("noise"), "strength": 0.014, "start_charge": 0.6,
	}))
	heat.position = Vector3(BLADE_TIP * 0.8, 0.0, 0.0)
	heat.set_meta(&"vfx_charge", &"charge")
	heat.set_meta(VfxEffect.META_NO_TINT, true)

	# Motas: nacen en una esfera alrededor de la hoja y la hoja las absorbe (velocidad radial negativa).
	var motes_proc: ParticleProcessMaterial = _proc({
		"emission_shape": ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE,
		"emission_sphere_radius": 1.05, "direction": Vector3(0, 0, 0), "spread": 0.0,
		"initial_velocity_min": 0.0, "initial_velocity_max": 0.0, "radial_velocity_min": -2.9,
		"radial_velocity_max": -2.0, "scale_min": 0.5, "scale_max": 1.1,
		"scale_curve": _curve([[0.0, 0.5], [0.6, 1.0], [1.0, 0.5]]),
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 0.0)], [0.25, Color(1, 1, 1, 0.8)],
				[0.9, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 0.0)]]),
	})
	var motes: GPUParticles3D = _particles(blade, "Motes", 40, 0.5, motes_proc, _quad(Vector2(0.035, 0.36),
			_mat("mote_streak", PARTICLE_ADD, {"tex": _tex("spark_streak"), "aligned_by_engine": true,
			"intensity": 3.6, "fade_in": 0.02, "fade_out_start": 0.8})), {
		"transform_align": ALIGN_VELOCITY, "one_shot": false, "explosiveness": 0.0,
		"randomness": 1.0,
	})
	motes.position = Vector3(middle, 0.0, 0.0)
	motes.set_meta(&"vfx_charge_amount", true)

	# Brasas que se sueltan de la hoja y suben.
	var embers_proc: ParticleProcessMaterial = _proc({
		"emission_shape": ParticleProcessMaterial.EMISSION_SHAPE_BOX,
		"emission_box_extents": Vector3(length * 0.5, 0.03, 0.03), "direction": Vector3(0, 1, 0),
		"spread": 28.0, "initial_velocity_min": 0.3, "initial_velocity_max": 0.9,
		"gravity": Vector3(0, 0.5, 0), "scale_min": 0.5, "scale_max": 1.1,
		"scale_curve": _curve([[0.0, 0.7], [0.5, 1.0], [1.0, 0.2]]),
		"color_ramp": _ramp([[0.0, Color(1, 0.95, 0.8, 1)], [0.4, Color(1, 0.62, 0.25, 0.9)],
				[1.0, Color(0.9, 0.25, 0.08, 0)]]),
	})
	var embers: GPUParticles3D = _particles(blade, "Embers", 18, 0.9, embers_proc, _quad(Vector2(0.045, 0.045),
			_mat("ember_glow", PARTICLE_ADD, {"tex": _tex("soft_dot"), "intensity": 3.4, "fade_in": 0.05,
			"fade_out_start": 0.55})), {
		"one_shot": false, "explosiveness": 0.0, "randomness": 1.0, "meta_tint": Color(1.0, 0.7, 0.4),
		"tint_weight": 0.5,
	})
	embers.position = Vector3(middle, 0.0, 0.0)
	embers.set_meta(&"vfx_charge_amount", true)

	var pulse_flash: MeshInstance3D = _shape(blade, "PulseFlash", Vector2.ONE * 0.95, _mat("shape_flash_aura", SHAPE_ADD, {
		"mode": SHAPE_FLASH, "tex": _tex("flare_star"), "intensity": 3.6, "start_scale": 0.4,
		"end_scale": 1.0, "spin": 0.6, "fade_power": 2.0, "attack": 0.05, "push": 0.1,
	}), Vector2(0.0, 0.22), Color.WHITE, 0.85)
	pulse_flash.position = Vector3(BLADE_TIP * 0.85, 0.0, 0.0)
	pulse_flash.set_meta(&"vfx_cue", &"pulse")

	var release_flash: MeshInstance3D = _shape(blade, "ReleaseFlash", Vector2.ONE * 1.7, _mat("shape_flash_release", SHAPE_ADD, {
		"mode": SHAPE_FLASH, "tex": _tex("flare_star"), "intensity": 4.6, "start_scale": 0.4,
		"end_scale": 1.0, "spin": 0.5, "fade_power": 1.8, "attack": 0.04, "push": 0.12,
	}), Vector2(0.0, 0.26), Color.WHITE, 0.7)
	release_flash.position = Vector3(BLADE_TIP * 0.7, 0.0, 0.0)
	release_flash.set_meta(&"vfx_cue", &"release")

	var burst_proc: ParticleProcessMaterial = _proc({
		"emission_shape": ParticleProcessMaterial.EMISSION_SHAPE_BOX,
		"emission_box_extents": Vector3(length * 0.5, 0.03, 0.03), "direction": Vector3(0, 0, 1),
		"spread": 180.0, "initial_velocity_min": 2.5, "initial_velocity_max": 6.0, "damping_min": 8.0,
		"damping_max": 12.0, "scale_min": 0.6, "scale_max": 1.2,
		"scale_curve": _curve([[0.0, 1.0], [1.0, 0.2]]),
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [0.4, Color(1, 1, 1, 0.9)],
				[1.0, Color(1, 1, 1, 0)]]),
	})
	var burst: GPUParticles3D = _particles(blade, "ReleaseSparks", 24, 0.45, burst_proc,
			_quad(Vector2(0.03, 0.26), _mat("spark_streak_aura", PARTICLE_ADD, {
			"tex": _tex("spark_streak"), "aligned_by_engine": true, "intensity": 3.6,
			"fade_in": 0.02, "fade_out_start": 0.5})), {
		"transform_align": ALIGN_VELOCITY, "explosiveness": 1.0, "randomness": 0.5,
		"cue": &"release",
	})
	burst.position = Vector3(middle, 0.0, 0.0)

	# En el suelo: una onda plana al llegar a carga completa y otra, mayor, al soltar.
	var pulse_wave: MeshInstance3D = _shape(root, "PulseWave", Vector2.ONE * 2.6, _mat("shape_wave_aura", SHAPE_ADD, {
		"mode": SHAPE_RING, "billboard": false, "noise_tex": _tex("noise"), "intensity": 2.6,
		"ring_start_radius": 0.2, "ring_width_start": 0.1, "ring_width_end": 0.03, "ring_line": 0.022,
		"ring_tail": 0.5, "fade_power": 1.3, "attack": 0.03,
	}), Vector2(0.0, 0.45), Color.WHITE, 0.9)
	pulse_wave.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	pulse_wave.position = Vector3(0.0, 0.06, 0.0)
	pulse_wave.set_meta(&"vfx_cue", &"pulse")
	var release_wave: MeshInstance3D = _shape(root, "ReleaseWave", Vector2.ONE * 3.8, _mat("shape_wave_release", SHAPE_ADD, {
		"mode": SHAPE_RING, "billboard": false, "noise_tex": _tex("noise"), "intensity": 3.0,
		"ring_start_radius": 0.15, "ring_width_start": 0.12, "ring_width_end": 0.03, "ring_line": 0.02,
		"ring_tail": 0.5, "fade_power": 1.3, "attack": 0.02,
	}), Vector2(0.0, 0.5), Color.WHITE, 0.8)
	release_wave.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	release_wave.position = Vector3(0.0, 0.06, 0.0)
	release_wave.set_meta(&"vfx_cue", &"release")
	_save(root, "charge_aura")


# --- Utilidades de montaje ------------------------------------------------------------------------

func _effect(node_name: String, duration: float, script_path: String = EFFECT_SCRIPT) -> VfxEffect:
	var root: Node3D = Node3D.new()
	root.set_script(load(script_path))
	root.name = node_name
	var effect: VfxEffect = root as VfxEffect
	effect.duration = duration
	return effect


# Una malla con sombreador de forma (quad de [param size] metros) que anima [VfxEffect].
func _shape(root: Node3D, node_name: String, size: Vector2, material: ShaderMaterial, timing: Vector2,
		base_tint: Color, tint_weight: float) -> MeshInstance3D:
	var instance: MeshInstance3D = _flat_quad(root, node_name, size, material)
	instance.set_meta(VfxEffect.META_TIME, timing)
	instance.set_meta(VfxEffect.META_TINT, base_tint)
	instance.set_meta(VfxEffect.META_TINT_WEIGHT, tint_weight)
	return instance


func _flat_quad(root: Node3D, node_name: String, size: Vector2, material: ShaderMaterial) -> MeshInstance3D:
	var instance: MeshInstance3D = MeshInstance3D.new()
	instance.name = node_name
	var quad: QuadMesh = QuadMesh.new()
	quad.size = size
	instance.mesh = quad
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(instance)
	return instance


func _quad(size: Vector2, material: ShaderMaterial) -> QuadMesh:
	var quad: QuadMesh = QuadMesh.new()
	quad.size = size
	quad.material = material
	return quad


# Partículas de un disparo (por defecto). [param extra]: [code]transform_align[/code], [code]explosiveness[/code],
# [code]randomness[/code], [code]lifetime_randomness[/code], [code]one_shot[/code], [code]local_coords[/code],
# [code]draw_order[/code], [code]cue[/code] (aviso que las lanza), [code]meta_tint[/code] y [code]tint_weight[/code].
func _particles(root: Node3D, node_name: String, amount: int, lifetime: float,
		process: ParticleProcessMaterial, mesh: Mesh, extra: Dictionary = {}) -> GPUParticles3D:
	var particles: GPUParticles3D = GPUParticles3D.new()
	particles.name = node_name
	particles.amount = amount
	particles.lifetime = lifetime
	particles.one_shot = bool(extra.get("one_shot", true))
	particles.explosiveness = float(extra.get("explosiveness", 1.0))
	particles.randomness = float(extra.get("randomness", 0.3))
	process.lifetime_randomness = float(extra.get("lifetime_randomness", 0.0))
	particles.local_coords = bool(extra.get("local_coords", false))
	particles.transform_align = int(extra.get("transform_align", GPUParticles3D.TRANSFORM_ALIGN_DISABLED))
	particles.draw_order = int(extra.get("draw_order", GPUParticles3D.DRAW_ORDER_INDEX))
	particles.process_material = process
	particles.draw_pass_1 = mesh
	particles.fixed_fps = 60
	particles.interpolate = true
	particles.visibility_aabb = AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.emitting = false
	if extra.has("cue"):
		particles.set_meta(VfxEffect.META_CUE, extra["cue"])
	if extra.has("meta_tint"):
		particles.set_meta(VfxEffect.META_TINT, extra["meta_tint"])
		particles.set_meta(VfxEffect.META_TINT_WEIGHT, float(extra.get("tint_weight", 1.0)))
	root.add_child(particles)
	return particles


func _proc(values: Dictionary) -> ParticleProcessMaterial:
	var material: ParticleProcessMaterial = ParticleProcessMaterial.new()
	for key: String in values:
		material.set(key, values[key])
	return material


# Material de sombreador de [param shader_name] (en SHADERS_DIR) guardado como recurso de texto: se
# comparte entre las copias de un efecto, porque lo que varía por copia va en parámetros de instancia.
func _mat(material_name: String, shader_name: String, params: Dictionary) -> ShaderMaterial:
	var path: String = MATERIALS_DIR + material_name + ".tres"
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = load(SHADERS_DIR + shader_name + ".gdshader") as Shader
	if COVER.has(material_name) and not params.has("cover"):
		material.set_shader_parameter("cover", float(COVER[material_name]))
	for key: String in params:
		material.set_shader_parameter(key, params[key])
	var error: Error = ResourceSaver.save(material, path)
	if error != OK:
		push_error("[vfx] No se pudo guardar %s (%d)" % [path, error])
	material.take_over_path(path)
	return material


func _tex(texture_name: String) -> Texture2D:
	var texture: Texture2D = load(TEXTURES_DIR + texture_name + ".png") as Texture2D
	if texture == null:
		push_error("[vfx] Falta la textura %s (¿se importó?)" % texture_name)
	return texture


# Rampa de color a lo largo de la vida: [[desplazamiento, color], ...].
func _ramp(stops: Array) -> GradientTexture1D:
	var gradient: Gradient = Gradient.new()
	var offsets: PackedFloat32Array = PackedFloat32Array()
	var colors: PackedColorArray = PackedColorArray()
	for stop: Array in stops:
		offsets.append(float(stop[0]))
		colors.append(stop[1] as Color)
	gradient.offsets = offsets
	gradient.colors = colors
	var texture: GradientTexture1D = GradientTexture1D.new()
	texture.gradient = gradient
	texture.width = 128
	return texture


# Curva de escala a lo largo de la vida: [[x, y], ...], con [param max_value] de tope.
func _curve(points: Array, max_value: float = 1.0) -> CurveTexture:
	var curve: Curve = Curve.new()
	curve.min_value = 0.0
	curve.max_value = max_value
	for point: Array in points:
		curve.add_point(Vector2(float(point[0]), float(point[1])))
	var texture: CurveTexture = CurveTexture.new()
	texture.curve = curve
	texture.width = 128
	return texture


func _save(root: Node, file_name: String) -> void:
	_set_owner(root, root)
	var packed: PackedScene = PackedScene.new()
	var error: Error = packed.pack(root)
	if error != OK:
		push_error("[vfx] No se pudo empaquetar %s (%d)" % [file_name, error])
		return
	var path: String = SCENES_DIR + file_name + ".tscn"
	error = ResourceSaver.save(packed, path)
	if error != OK:
		push_error("[vfx] No se pudo guardar %s (%d)" % [path, error])
	else:
		print("[vfx] %s" % path)
	root.free()


func _set_owner(node: Node, owner_node: Node) -> void:
	for child: Node in node.get_children():
		child.owner = owner_node
		_set_owner(child, owner_node)
