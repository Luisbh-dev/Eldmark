// Superficie de reino para piezas de una cara (planos del Castle Wall Kit y del Village MegaKit):
// sin descarte de caras traseras. El cuerpo está en realm_surface.gdshaderinc (ver allí la
// descripción); realm_surface_closed.gdshader es la variante para mallas cerradas.
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

#include "res://assets/materials/shaders/realm_surface.gdshaderinc"
