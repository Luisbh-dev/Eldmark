extends SceneTree
## Genera las escenas y los materiales de los efectos de golpe (ART-09) en [code]res://scenes/vfx/[/code].
##
## Cada efecto se monta con código (nodos, materiales de partículas, rampas de color y curvas) y se
## guarda como [code].tscn[/code] / [code].tres[/code] de texto, así que todos los números de abajo son los
## que hay que tocar para afinar un efecto y volver a generarlo; nada se retoca a mano en los .tscn.
## [br][br]
## Orden completo (desde la raíz del proyecto, con el editor cerrado):
## [codeblock]
## python tools/vfx/make_vfx_textures.py
## godot --headless --path . --import
## godot --headless --path . -s res://tools/vfx/build_vfx_scenes.gd
## godot --headless --path . --import
## [/codeblock]
## Escenas: [code]hit_metal_spark[/code], [code]hit_flesh[/code], [code]hit_block_wood[/code],
## [code]parry_flash[/code], [code]dust_kick[/code], [code]weapon_trail[/code] y [code]charge_aura[/code].
## Convenciones de orientación y metadatos de los hijos: ver [VfxEffect].

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
const SHAPE_ADD: String = "vfx_shape_add"
const SHAPE_MIX: String = "vfx_shape_mix"
const TRAIL: String = "vfx_trail"
const AURA: String = "vfx_aura"

const ALIGN_VELOCITY: int = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
## Cuánto tapan el fondo los materiales de luz (0 = aditivo puro, 1 = mezcla normal). Con un cielo claro un
## brillo aditivo se lava; un poco de cobertura le da color y contraste (ver vfx_particle_add.gdshader).
const COVER: Dictionary = {
	"shape_flash_metal": 0.15, "shape_flash_soft": 0.2, "shape_flash_wood": 0.2, "shape_flash_parry": 0.15,
	"shape_flash_aura": 0.2, "shape_flash_release": 0.2, "shape_ring_block": 0.4, "shape_ring_parry_a": 0.3,
	"shape_ring_parry_b": 0.4, "shape_ring_aura": 0.4, "shape_ring_release": 0.4, "shape_rays_parry": 0.3,
	"shape_core_parry": 0.15, "shape_rune": 0.45, "wisp_glow": 0.5, "mote_streak": 0.2, "glint_star": 0.15,
	"spark_streak": 0.1, "spark_streak_small": 0.1, "spark_streak_parry": 0.1, "spark_streak_aura": 0.15,
}

const SHAPE_FLASH: int = 0
const SHAPE_RING: int = 1
const SHAPE_RAYS: int = 2
const SHAPE_GLOW: int = 3
const SHAPE_RUNE: int = 4


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCENES_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MATERIALS_DIR))
	_build_metal_spark()
	_build_flesh()
	_build_block_wood()
	_build_parry()
	_build_dust()
	_build_trail()
	_build_aura()
	print("[vfx] Escenas generadas en %s" % SCENES_DIR)
	quit(0)


# --- Efectos ------------------------------------------------------------------------------------

# Chispa de metal: destello con puntas, lluvia de chispas con cola, esquirlas que caen y un hilo de humo.
func _build_metal_spark() -> void:
	var root: VfxEffect = _effect("HitMetalSpark", 1.2)

	var flash: MeshInstance3D = _shape(root, "Flash", 0.9, _mat("shape_flash_metal", SHAPE_ADD, {
		"mode": SHAPE_FLASH, "tex": _tex("flare_star"), "intensity": 3.0, "start_scale": 0.35,
		"end_scale": 1.25, "spin": 0.7, "fade_power": 2.2, "attack": 0.06,
	}), Vector2(0.0, 0.16), Color(1.0, 0.84, 0.55), 0.25)
	flash.position = Vector3(0.0, 0.0, 0.04)

	var sparks_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0, 1), "spread": 58.0, "initial_velocity_min": 4.5,
		"initial_velocity_max": 13.5, "damping_min": 1.4, "damping_max": 4.5,
		"gravity": Vector3(0, -12.0, 0), "scale_min": 0.55, "scale_max": 1.2,
		"scale_curve": _curve([[0.0, 1.0], [0.55, 0.85], [1.0, 0.22]]),
		"color_ramp": _ramp([[0.0, Color(1, 0.97, 0.8, 1)], [0.14, Color(1, 0.74, 0.3, 1)],
				[0.5, Color(1, 0.4, 0.08, 0.95)], [1.0, Color(0.7, 0.12, 0.02, 0.0)]]),
	})
	_particles(root, "Sparks", 36, 0.55, sparks_proc, _quad(Vector2(0.045, 0.34),
			_mat("spark_streak", PARTICLE_ADD, {"tex": _tex("spark_streak"), "aligned_by_engine": true,
			"intensity": 2.7, "fade_in": 0.02, "fade_out_start": 0.5})), {
		"transform_align": ALIGN_VELOCITY, "explosiveness": 0.97, "randomness": 0.55,
		"lifetime_randomness": 0.35,
	})

	var shards_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0.3, 1), "spread": 70.0, "initial_velocity_min": 2.2,
		"initial_velocity_max": 6.6, "damping_min": 0.3, "damping_max": 1.0,
		"gravity": Vector3(0, -16.0, 0), "angle_min": 0.0, "angle_max": 360.0,
		"angular_velocity_min": -900.0, "angular_velocity_max": 900.0, "scale_min": 0.5,
		"scale_max": 1.2, "anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [0.7, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 0)]]),
	})
	_particles(root, "Shards", 11, 0.95, shards_proc, _quad(Vector2(0.11, 0.11),
			_mat("shard_metal", PARTICLE_MIX, {"tex": _tex("shards"), "h_frames": 2, "v_frames": 2,
			"brightness": 1.0, "shade_contrast": 1.0, "hot_color": Color(1.0, 0.55, 0.18, 2.4),
			"hot_decay": 6.5, "fade_in": 0.02, "fade_out_start": 0.7})), {
		"explosiveness": 1.0, "randomness": 0.4, "lifetime_randomness": 0.3,
		"meta_tint": Color(0.74, 0.78, 0.86), "tint_weight": 0.15,
	})

	var smoke_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0.4, 1), "spread": 40.0, "initial_velocity_min": 0.2,
		"initial_velocity_max": 0.9, "damping_min": 0.6, "damping_max": 1.2,
		"gravity": Vector3(0, 0.5, 0), "angle_min": 0.0, "angle_max": 360.0,
		"angular_velocity_min": -40.0, "angular_velocity_max": 40.0, "scale_min": 0.6,
		"scale_max": 1.0, "scale_curve": _curve([[0.0, 0.35], [1.0, 1.5]], 2.0),
		"anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 0.0)], [0.12, Color(1, 1, 1, 0.55)],
				[1.0, Color(1, 1, 1, 0.0)]]),
	})
	_particles(root, "Smoke", 3, 0.75, smoke_proc, _quad(Vector2(0.2, 0.2),
			_mat("puff_smoke", PARTICLE_MIX, {"tex": _tex("puffs"), "h_frames": 2, "v_frames": 2,
			"brightness": 0.85, "soft_distance": 0.2, "fade_in": 0.05, "fade_out_start": 0.45})), {
		"explosiveness": 0.9, "draw_order": GPUParticles3D.DRAW_ORDER_VIEW_DEPTH,
		"meta_tint": Color(0.5, 0.5, 0.52), "tint_weight": 0.0,
	})
	_save(root, "hit_metal_spark")


# Impacto en carne o tela: salpicadura de tinta que se deshace, gotas estilizadas y una bocanada pálida.
# El color del conjunto es [member VfxEffect.tint]: rojo cálido para carne, beige para tela.
func _build_flesh() -> void:
	var root: VfxEffect = _effect("HitFlesh", 0.8)
	root.tint = Color(0.82, 0.14, 0.11)

	_shape(root, "Pop", 0.55, _mat("shape_flash_soft", SHAPE_ADD, {
		"mode": SHAPE_GLOW, "tex": _tex("soft_dot"), "intensity": 2.6, "start_scale": 0.45,
		"end_scale": 1.0, "fade_power": 2.2, "attack": 0.08,
	}), Vector2(0.0, 0.11), Color(1.0, 0.86, 0.78), 0.3)

	var splat: MeshInstance3D = _shape(root, "Splat", 0.68, _mat("shape_splat", SHAPE_MIX, {
		"mode": 0, "tex": _tex("splat"), "noise_tex": _tex("noise"), "start_scale": 0.5,
		"end_scale": 1.0, "grow_speed": 6.0, "hold": 0.38, "erosion": 0.6, "spin": 0.3,
		"brightness": 1.0, "shade_contrast": 0.9, "opacity": 0.94,
	}), Vector2(0.0, 0.42), Color.WHITE, 1.0)
	splat.position = Vector3(0.0, 0.0, 0.05)

	var drops_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0, 1), "spread": 66.0, "initial_velocity_min": 1.4,
		"initial_velocity_max": 5.2, "damping_min": 0.2, "damping_max": 0.7,
		"gravity": Vector3(0, -13.0, 0), "scale_min": 0.6, "scale_max": 1.2,
		"scale_curve": _curve([[0.0, 1.0], [0.6, 0.85], [1.0, 0.35]]),
		"anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [0.7, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 0)]]),
	})
	_particles(root, "Drops", 16, 0.6, drops_proc, _quad(Vector2(0.07, 0.07),
			_mat("droplet", PARTICLE_MIX, {"tex": _tex("droplets"), "h_frames": 2, "v_frames": 2,
			"aligned_by_engine": true, "brightness": 1.0, "fade_in": 0.02, "fade_out_start": 0.7})), {
		"transform_align": ALIGN_VELOCITY, "explosiveness": 1.0, "randomness": 0.5,
		"lifetime_randomness": 0.3,
	})

	var puff_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0.3, 1), "spread": 50.0, "initial_velocity_min": 0.4,
		"initial_velocity_max": 1.4, "damping_min": 1.5, "damping_max": 2.5,
		"angle_min": 0.0, "angle_max": 360.0, "angular_velocity_min": -60.0,
		"angular_velocity_max": 60.0, "scale_min": 0.6, "scale_max": 1.0,
		"scale_curve": _curve([[0.0, 0.5], [1.0, 1.45]], 2.0), "anim_offset_min": 0.0,
		"anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 0.0)], [0.1, Color(1, 1, 1, 0.34)],
				[1.0, Color(1, 1, 1, 0.0)]]),
	})
	_particles(root, "Puff", 4, 0.36, puff_proc, _quad(Vector2(0.4, 0.4),
			_mat("puff_pale", PARTICLE_MIX, {"tex": _tex("puffs"), "h_frames": 2, "v_frames": 2,
			"brightness": 1.0, "soft_distance": 0.15, "fade_in": 0.05, "fade_out_start": 0.4})), {
		"explosiveness": 1.0, "draw_order": GPUParticles3D.DRAW_ORDER_VIEW_DEPTH,
		"meta_tint": Color(0.92, 0.86, 0.82), "tint_weight": 0.25,
	})
	_save(root, "hit_flesh")


# Impacto bloqueado en un escudo de madera: anillo de choque ámbar, astillas que giran y caen, motas de
# serrín y un destello cálido.
func _build_block_wood() -> void:
	var root: VfxEffect = _effect("HitBlockWood", 1.0)

	_shape(root, "Flash", 0.7, _mat("shape_flash_wood", SHAPE_ADD, {
		"mode": SHAPE_FLASH, "tex": _tex("flare_star"), "intensity": 2.4, "start_scale": 0.3,
		"end_scale": 0.85, "spin": 0.4, "fade_power": 2.4, "attack": 0.06,
	}), Vector2(0.0, 0.12), Color(1.0, 0.84, 0.52), 0.4)

	_shape(root, "Ring", 1.15, _mat("shape_ring_block", SHAPE_ADD, {
		"mode": SHAPE_RING, "noise_tex": _tex("noise"), "intensity": 2.6, "ring_start_radius": 0.12,
		"ring_width_start": 0.08, "ring_width_end": 0.022, "fade_power": 1.3, "attack": 0.03,
	}), Vector2(0.0, 0.32), Color(1.0, 0.82, 0.5), 0.5)

	var splinters_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0.25, 1), "spread": 64.0, "initial_velocity_min": 2.0,
		"initial_velocity_max": 6.6, "damping_min": 0.4, "damping_max": 1.2,
		"gravity": Vector3(0, -15.0, 0), "angle_min": 0.0, "angle_max": 360.0,
		"angular_velocity_min": -720.0, "angular_velocity_max": 720.0, "scale_min": 0.55,
		"scale_max": 1.25, "scale_curve": _curve([[0.0, 1.0], [0.7, 1.0], [1.0, 0.55]]),
		"anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [0.72, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 0)]]),
	})
	_particles(root, "Splinters", 15, 0.85, splinters_proc, _quad(Vector2(0.17, 0.17),
			_mat("splinter", PARTICLE_MIX, {"tex": _tex("splinters"), "h_frames": 2, "v_frames": 2,
			"brightness": 1.0, "shade_contrast": 1.0, "fade_in": 0.02, "fade_out_start": 0.72})), {
		"explosiveness": 1.0, "randomness": 0.45, "lifetime_randomness": 0.3,
		"meta_tint": Color(0.8, 0.62, 0.42), "tint_weight": 0.2,
	})

	var specks_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0.1, 1), "spread": 75.0, "initial_velocity_min": 3.0,
		"initial_velocity_max": 8.0, "damping_min": 2.0, "damping_max": 5.0,
		"gravity": Vector3(0, -9.0, 0), "scale_min": 0.5, "scale_max": 1.0,
		"scale_curve": _curve([[0.0, 1.0], [1.0, 0.2]]),
		"color_ramp": _ramp([[0.0, Color(1, 0.95, 0.75, 1)], [0.5, Color(1, 0.72, 0.38, 0.9)],
				[1.0, Color(0.8, 0.4, 0.15, 0)]]),
	})
	_particles(root, "Specks", 12, 0.38, specks_proc, _quad(Vector2(0.022, 0.14),
			_mat("spark_streak_small", PARTICLE_ADD, {"tex": _tex("spark_streak"),
			"aligned_by_engine": true, "intensity": 2.6, "fade_in": 0.02, "fade_out_start": 0.5})), {
		"transform_align": ALIGN_VELOCITY, "explosiveness": 1.0, "randomness": 0.5,
		"meta_tint": Color(1.0, 0.86, 0.6), "tint_weight": 0.0,
	})

	var dust_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0.3, 1), "spread": 55.0, "initial_velocity_min": 0.5,
		"initial_velocity_max": 1.6, "damping_min": 1.5, "damping_max": 2.6,
		"angle_min": 0.0, "angle_max": 360.0, "angular_velocity_min": -50.0,
		"angular_velocity_max": 50.0, "scale_min": 0.6, "scale_max": 1.0,
		"scale_curve": _curve([[0.0, 0.5], [1.0, 1.4]], 2.0), "anim_offset_min": 0.0,
		"anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 0.0)], [0.1, Color(1, 1, 1, 0.36)],
				[1.0, Color(1, 1, 1, 0.0)]]),
	})
	_particles(root, "Dust", 3, 0.5, dust_proc, _quad(Vector2(0.42, 0.42),
			_mat("puff_wood_dust", PARTICLE_MIX, {"tex": _tex("puffs"), "h_frames": 2, "v_frames": 2,
			"brightness": 1.0, "soft_distance": 0.2, "fade_in": 0.05, "fade_out_start": 0.4})), {
		"explosiveness": 1.0, "draw_order": GPUParticles3D.DRAW_ORDER_VIEW_DEPTH,
		"meta_tint": Color(0.78, 0.62, 0.44), "tint_weight": 0.0,
	})
	_save(root, "hit_block_wood")


# Parada perfecta: destello grande blanco con rayos que giran, dos anillos (blanco y oro) escalonados,
# chispas radiales y titileos. Es más grande, más blanca y más limpia que el bloqueo.
func _build_parry() -> void:
	var root: VfxEffect = _effect("ParryFlash", 0.9)
	root.tint = Color(1.0, 0.97, 0.9)

	_shape(root, "Rays", 2.4, _mat("shape_rays_parry", SHAPE_ADD, {
		"mode": SHAPE_RAYS, "tex": _tex("rays"), "intensity": 3.2, "start_scale": 0.3,
		"end_scale": 1.0, "spin": 0.7, "fade_power": 1.7, "attack": 0.05,
	}), Vector2(0.0, 0.3), Color(1.0, 0.95, 0.82), 0.6)

	_shape(root, "Flash", 1.7, _mat("shape_flash_parry", SHAPE_ADD, {
		"mode": SHAPE_FLASH, "tex": _tex("flare_star"), "intensity": 3.6, "start_scale": 0.4,
		"end_scale": 1.0, "spin": -0.5, "fade_power": 1.6, "attack": 0.04,
	}), Vector2(0.0, 0.24), Color(0.96, 0.98, 1.0), 0.4)

	_shape(root, "Core", 0.7, _mat("shape_core_parry", SHAPE_ADD, {
		"mode": SHAPE_GLOW, "tex": _tex("soft_dot"), "intensity": 2.2, "start_scale": 0.5,
		"end_scale": 1.0, "fade_power": 1.4, "attack": 0.06,
	}), Vector2(0.0, 0.2), Color(1.0, 1.0, 1.0), 0.0)

	_shape(root, "RingWhite", 2.4, _mat("shape_ring_parry_a", SHAPE_ADD, {
		"mode": SHAPE_RING, "noise_tex": _tex("noise"), "intensity": 3.4, "ring_start_radius": 0.18,
		"ring_width_start": 0.1, "ring_width_end": 0.02, "fade_power": 1.3, "attack": 0.02,
	}), Vector2(0.0, 0.34), Color(1.0, 0.99, 0.95), 0.3)

	_shape(root, "RingGold", 1.6, _mat("shape_ring_parry_b", SHAPE_ADD, {
		"mode": SHAPE_RING, "noise_tex": _tex("noise"), "intensity": 3.0, "ring_start_radius": 0.12,
		"ring_width_start": 0.13, "ring_width_end": 0.03, "fade_power": 1.4, "attack": 0.02,
	}), Vector2(0.07, 0.32), Color(1.0, 0.8, 0.38), 0.5)

	var sparks_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0, 1), "spread": 150.0, "initial_velocity_min": 5.0,
		"initial_velocity_max": 12.0, "damping_min": 3.0, "damping_max": 6.0,
		"gravity": Vector3(0, -3.5, 0), "scale_min": 0.6, "scale_max": 1.2,
		"scale_curve": _curve([[0.0, 1.0], [1.0, 0.2]]),
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [0.35, Color(1, 0.92, 0.6, 1)],
				[1.0, Color(1, 0.6, 0.2, 0)]]),
	})
	_particles(root, "Sparks", 28, 0.5, sparks_proc, _quad(Vector2(0.03, 0.3),
			_mat("spark_streak_parry", PARTICLE_ADD, {"tex": _tex("spark_streak"),
			"aligned_by_engine": true, "intensity": 4.2, "fade_in": 0.02, "fade_out_start": 0.5})), {
		"transform_align": ALIGN_VELOCITY, "explosiveness": 1.0, "randomness": 0.5,
		"lifetime_randomness": 0.3, "meta_tint": Color(1.0, 0.96, 0.85), "tint_weight": 0.3,
	})

	var glints_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0, 1), "spread": 120.0, "initial_velocity_min": 0.6,
		"initial_velocity_max": 2.2, "damping_min": 1.0, "damping_max": 2.0,
		"angle_min": -20.0, "angle_max": 20.0, "scale_min": 0.5, "scale_max": 1.0,
		"scale_curve": _curve([[0.0, 0.0], [0.25, 1.0], [0.6, 0.4], [1.0, 0.0]]),
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [1.0, Color(1, 0.9, 0.6, 1)]]),
	})
	_particles(root, "Glints", 9, 0.55, glints_proc, _quad(Vector2(0.28, 0.28),
			_mat("glint_star", PARTICLE_ADD, {"tex": _tex("flare_star"), "intensity": 3.5,
			"fade_in": 0.02, "fade_out_start": 0.5})), {
		"explosiveness": 0.8, "randomness": 0.6, "meta_tint": Color(1.0, 0.95, 0.8),
		"tint_weight": 0.3,
	})
	_save(root, "parry_flash")


# Polvo al esquivar o aterrizar: bocanadas que salen en anillo, anillo de polvo en el suelo y piedrecitas.
# El eje +Z del efecto es el suelo hacia arriba. El aviso [code]dodge[/code] suma la estela de polvo hacia
# atrás (el eje +Y local es la dirección contraria al movimiento; ver DustKick).
func _build_dust() -> void:
	var root: VfxEffect = _effect("DustKick", 1.2, DUST_SCRIPT)
	root.tint = Color(0.78, 0.74, 0.66)

	var ring: MeshInstance3D = _shape(root, "Ring", 2.2, _mat("shape_ring_dust", SHAPE_MIX, {
		"mode": 1, "billboard": false, "tex": _tex("ring_dust"), "noise_tex": _tex("noise"),
		"start_scale": 0.3, "end_scale": 1.0, "grow_speed": 2.6, "hold": 0.18, "erosion": 0.5,
		"brightness": 0.92, "shade_contrast": 0.7, "soft_distance": 0.12, "opacity": 0.5,
	}), Vector2(0.0, 0.65), Color.WHITE, 1.0)
	ring.position = Vector3(0.0, 0.0, 0.03)

	var puffs_proc: ParticleProcessMaterial = _proc({
		"emission_shape": ParticleProcessMaterial.EMISSION_SHAPE_RING,
		"emission_ring_axis": Vector3(0, 0, 1), "emission_ring_radius": 0.34,
		"emission_ring_inner_radius": 0.12, "emission_ring_height": 0.04,
		"direction": Vector3(0, 0, 1), "spread": 12.0, "initial_velocity_min": 0.25,
		"initial_velocity_max": 0.8, "radial_velocity_min": 1.5, "radial_velocity_max": 3.3,
		"damping_min": 2.2, "damping_max": 3.6, "gravity": Vector3(0, 0.5, 0),
		"angle_min": 0.0, "angle_max": 360.0, "angular_velocity_min": -40.0,
		"angular_velocity_max": 40.0, "scale_min": 0.5, "scale_max": 1.0,
		"scale_curve": _curve([[0.0, 0.35], [0.4, 1.0], [1.0, 1.35]], 2.0),
		"anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 0.0)], [0.14, Color(1, 1, 1, 0.62)],
				[0.55, Color(1, 1, 1, 0.4)], [1.0, Color(1, 1, 1, 0.0)]]),
	})
	var puffs: GPUParticles3D = _particles(root, "Puffs", 14, 0.95, puffs_proc, _quad(Vector2(0.55, 0.55),
			_mat("puff_dust", PARTICLE_MIX, {"tex": _tex("puffs"), "h_frames": 2, "v_frames": 2,
			"brightness": 1.0, "shade_contrast": 1.0, "soft_distance": 0.35, "fade_in": 0.04,
			"fade_out_start": 0.5})), {
		"explosiveness": 1.0, "randomness": 0.4, "lifetime_randomness": 0.3,
		"draw_order": GPUParticles3D.DRAW_ORDER_VIEW_DEPTH,
	})

	var grit_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 0, 1), "spread": 62.0, "initial_velocity_min": 1.4,
		"initial_velocity_max": 4.6, "damping_min": 0.2, "damping_max": 0.6,
		"gravity": Vector3(0, -14.0, 0), "scale_min": 0.6, "scale_max": 1.4,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [0.7, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 0)]]),
	})
	_particles(root, "Grit", 9, 0.55, grit_proc, _quad(Vector2(0.03, 0.03),
			_mat("grit", PARTICLE_MIX, {"tex": _tex("soft_dot"), "brightness": 0.9,
			"fade_in": 0.02, "fade_out_start": 0.75})), {
		"explosiveness": 1.0, "randomness": 0.5, "meta_tint": Color(0.36, 0.31, 0.26),
		"tint_weight": 0.35,
	})

	var spray_proc: ParticleProcessMaterial = _proc({
		"direction": Vector3(0, 1, 0.22), "spread": 24.0, "initial_velocity_min": 2.0,
		"initial_velocity_max": 4.8, "damping_min": 2.4, "damping_max": 3.6,
		"gravity": Vector3(0, 0.4, 0), "angle_min": 0.0, "angle_max": 360.0,
		"angular_velocity_min": -50.0, "angular_velocity_max": 50.0, "scale_min": 0.6,
		"scale_max": 1.1, "scale_curve": _curve([[0.0, 0.4], [0.45, 1.0], [1.0, 1.4]], 2.0),
		"anim_offset_min": 0.0, "anim_offset_max": 1.0,
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 0.0)], [0.1, Color(1, 1, 1, 0.7)],
				[1.0, Color(1, 1, 1, 0.0)]]),
	})
	_particles(root, "Spray", 8, 0.8, spray_proc, puffs.draw_pass_1, {
		"explosiveness": 0.8, "randomness": 0.4, "draw_order": GPUParticles3D.DRAW_ORDER_VIEW_DEPTH,
		"cue": &"dodge",
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


# Aura de carga del golpe fuerte: cáscara de energía, motas que convergen, lenguas que suben, runa en el
# suelo y los estallidos del pulso (carga completa) y de la suelta.
func _build_aura() -> void:
	var root: VfxEffect = _effect("ChargeAura", 0.5, AURA_SCRIPT)
	root.looping = true

	var shell: MeshInstance3D = MeshInstance3D.new()
	shell.name = "Shell"
	var capsule: CapsuleMesh = CapsuleMesh.new()
	capsule.radius = 0.5
	capsule.height = 2.0
	capsule.radial_segments = 24
	capsule.rings = 10
	shell.mesh = capsule
	shell.material_override = _mat("aura_shell", AURA, {"noise_tex": _tex("noise")})
	shell.position = Vector3(0.0, 0.95, 0.0)
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shell.set_meta(&"vfx_charge", &"charge")
	root.add_child(shell)

	var rune: MeshInstance3D = _flat_quad(root, "Rune", 2.6, _mat("shape_rune", SHAPE_ADD, {
		"mode": SHAPE_RUNE, "billboard": false, "intensity": 2.4, "runes": 14.0,
	}))
	rune.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	rune.position = Vector3(0.0, 0.04, 0.0)
	rune.set_meta(&"vfx_charge", &"progress")

	var motes_proc: ParticleProcessMaterial = _proc({
		"emission_shape": ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE,
		"emission_sphere_radius": 1.45, "emission_shape_offset": Vector3(0, 0.95, 0),
		"direction": Vector3(0, 0, 0), "spread": 0.0, "initial_velocity_min": 0.0,
		"initial_velocity_max": 0.0, "radial_velocity_min": -2.4, "radial_velocity_max": -1.7,
		"scale_min": 0.5, "scale_max": 1.1,
		"scale_curve": _curve([[0.0, 0.5], [0.6, 1.0], [1.0, 0.6]]),
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 0.0)], [0.25, Color(1, 1, 1, 0.8)],
				[0.9, Color(1, 1, 1, 1)], [1.0, Color(1, 1, 1, 0.0)]]),
	})
	var motes: GPUParticles3D = _particles(root, "Motes", 46, 0.7, motes_proc, _quad(Vector2(0.04, 0.42),
			_mat("mote_streak", PARTICLE_ADD, {"tex": _tex("spark_streak"), "aligned_by_engine": true,
			"intensity": 3.6, "fade_in": 0.02, "fade_out_start": 0.8})), {
		"transform_align": ALIGN_VELOCITY, "one_shot": false, "explosiveness": 0.0,
		"randomness": 1.0, "local_coords": true,
	})
	motes.set_meta(&"vfx_charge_amount", true)

	var wisps_proc: ParticleProcessMaterial = _proc({
		"emission_shape": ParticleProcessMaterial.EMISSION_SHAPE_RING,
		"emission_ring_axis": Vector3(0, 1, 0), "emission_ring_radius": 0.5,
		"emission_ring_inner_radius": 0.3, "emission_ring_height": 0.05,
		"direction": Vector3(0, 1, 0), "spread": 6.0, "initial_velocity_min": 1.1,
		"initial_velocity_max": 2.0, "scale_min": 0.6, "scale_max": 1.1,
		"scale_curve": _curve([[0.0, 0.5], [0.35, 1.0], [1.0, 0.7]]),
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 0.0)], [0.2, Color(1, 1, 1, 0.9)],
				[0.7, Color(1, 1, 1, 0.5)], [1.0, Color(1, 1, 1, 0.0)]]),
	})
	var wisps: GPUParticles3D = _particles(root, "Wisps", 24, 1.1, wisps_proc, _quad(Vector2(0.3, 1.0),
			_mat("wisp_glow", PARTICLE_ADD, {"tex": _tex("wisp"), "intensity": 3.4, "fade_in": 0.05,
			"fade_out_start": 0.55})), {
		"one_shot": false, "explosiveness": 0.0, "randomness": 1.0, "local_coords": true,
	})
	wisps.position = Vector3(0.0, 0.05, 0.0)
	wisps.set_meta(&"vfx_charge_amount", true)

	var pulse_flash: MeshInstance3D = _shape(root, "PulseFlash", 1.4, _mat("shape_flash_aura", SHAPE_ADD, {
		"mode": SHAPE_FLASH, "tex": _tex("flare_star"), "intensity": 4.0, "start_scale": 0.4,
		"end_scale": 1.0, "spin": 0.6, "fade_power": 2.0, "attack": 0.05,
	}), Vector2(0.0, 0.22), Color.WHITE, 0.85)
	pulse_flash.position = Vector3(0.0, 1.1, 0.0)
	pulse_flash.set_meta(&"vfx_cue", &"pulse")
	var pulse_ring: MeshInstance3D = _shape(root, "PulseRing", 2.1, _mat("shape_ring_aura", SHAPE_ADD, {
		"mode": SHAPE_RING, "noise_tex": _tex("noise"), "intensity": 3.0, "ring_start_radius": 0.2,
		"ring_width_start": 0.09, "ring_width_end": 0.02, "fade_power": 1.4, "attack": 0.03,
		"ring_fill": 0.16,
	}), Vector2(0.0, 0.42), Color.WHITE, 0.9)
	pulse_ring.position = Vector3(0.0, 1.0, 0.0)
	pulse_ring.set_meta(&"vfx_cue", &"pulse")

	var release_flash: MeshInstance3D = _shape(root, "ReleaseFlash", 2.2, _mat("shape_flash_release", SHAPE_ADD, {
		"mode": SHAPE_FLASH, "tex": _tex("flare_star"), "intensity": 5.0, "start_scale": 0.4,
		"end_scale": 1.0, "spin": 0.5, "fade_power": 1.8, "attack": 0.04,
	}), Vector2(0.0, 0.26), Color.WHITE, 0.7)
	release_flash.position = Vector3(0.0, 1.1, 0.0)
	release_flash.set_meta(&"vfx_cue", &"release")
	var release_ring: MeshInstance3D = _shape(root, "ReleaseRing", 3.0, _mat("shape_ring_release", SHAPE_ADD, {
		"mode": SHAPE_RING, "noise_tex": _tex("noise"), "intensity": 3.4, "ring_start_radius": 0.15,
		"ring_width_start": 0.1, "ring_width_end": 0.02, "fade_power": 1.3, "attack": 0.02,
		"ring_fill": 0.16,
	}), Vector2(0.0, 0.4), Color.WHITE, 0.8)
	release_ring.position = Vector3(0.0, 1.0, 0.0)
	release_ring.set_meta(&"vfx_cue", &"release")

	var burst_proc: ParticleProcessMaterial = _proc({
		"emission_shape": ParticleProcessMaterial.EMISSION_SHAPE_SPHERE,
		"emission_sphere_radius": 0.25, "direction": Vector3(0, 0, 1), "spread": 180.0,
		"initial_velocity_min": 4.0, "initial_velocity_max": 10.0, "damping_min": 2.5,
		"damping_max": 5.0, "scale_min": 0.6, "scale_max": 1.2,
		"scale_curve": _curve([[0.0, 1.0], [1.0, 0.2]]),
		"color_ramp": _ramp([[0.0, Color(1, 1, 1, 1)], [0.4, Color(1, 1, 1, 0.9)],
				[1.0, Color(1, 1, 1, 0)]]),
	})
	var burst: GPUParticles3D = _particles(root, "ReleaseSparks", 28, 0.5, burst_proc,
			_quad(Vector2(0.03, 0.3), _mat("spark_streak_aura", PARTICLE_ADD, {
			"tex": _tex("spark_streak"), "aligned_by_engine": true, "intensity": 3.6,
			"fade_in": 0.02, "fade_out_start": 0.5})), {
		"transform_align": ALIGN_VELOCITY, "explosiveness": 1.0, "randomness": 0.5,
		"cue": &"release",
	})
	burst.position = Vector3(0.0, 1.1, 0.0)
	_save(root, "charge_aura")


# --- Utilidades de montaje ------------------------------------------------------------------------

func _effect(node_name: String, duration: float, script_path: String = EFFECT_SCRIPT) -> VfxEffect:
	var root: Node3D = Node3D.new()
	root.set_script(load(script_path))
	root.name = node_name
	var effect: VfxEffect = root as VfxEffect
	effect.duration = duration
	return effect


# Una malla con sombreador de forma (quad de 1 x 1 por [param size] metros) que anima [VfxEffect].
func _shape(root: Node3D, node_name: String, size: float, material: ShaderMaterial, timing: Vector2,
		base_tint: Color, tint_weight: float) -> MeshInstance3D:
	var instance: MeshInstance3D = _flat_quad(root, node_name, size, material)
	instance.set_meta(VfxEffect.META_TIME, timing)
	instance.set_meta(VfxEffect.META_TINT, base_tint)
	instance.set_meta(VfxEffect.META_TINT_WEIGHT, tint_weight)
	return instance


func _flat_quad(root: Node3D, node_name: String, size: float, material: ShaderMaterial) -> MeshInstance3D:
	var instance: MeshInstance3D = MeshInstance3D.new()
	instance.name = node_name
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(size, size)
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
