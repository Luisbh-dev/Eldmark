// Superficie de reino para mallas cerradas (troncos de la empalizada, lonas de las tiendas,
// brasas): se descartan las caras traseras, que nunca se ven y en las sombras costaban el doble.
// El cuerpo está en realm_surface.gdshaderinc.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://assets/materials/shaders/realm_surface.gdshaderinc"
