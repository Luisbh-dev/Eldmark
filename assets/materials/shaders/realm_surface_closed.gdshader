// Realm surface for closed meshes (palisade logs, tent canvas, embers): back faces are discarded,
// since they are never seen and in shadows they cost double. The body is in
// realm_surface.gdshaderinc.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://assets/materials/shaders/realm_surface.gdshaderinc"
