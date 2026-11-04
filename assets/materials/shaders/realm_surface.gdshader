// Realm surface for single-sided pieces (planes of the Castle Wall Kit and the Village MegaKit):
// no back-face culling. The body is in realm_surface.gdshaderinc (see the description there);
// realm_surface_closed.gdshader is the variant for closed meshes.
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

#include "res://assets/materials/shaders/realm_surface.gdshaderinc"
