@tool
class_name BakedMultiMesh
extends MultiMeshInstance3D
## MultiMesh cuyas transformaciones se guardan en la escena como texto.
##
## Un [MultiMesh] guarda sus instancias en el RenderingServer; en modo headless (generadores de
## escenas, servidor dedicado) ese servidor es ficticio y el búfer se pierde al guardar. Este nodo
## guarda la malla y las transformaciones en propiedades exportadas y monta el MultiMesh al entrar
## en el árbol (también en el editor). El MultiMesh generado no se guarda en la escena.
## [br][br]
## Se usa para piezas repetidas que solo son visuales (troncos de la empalizada, hiladas de las
## murallas): su colisión va aparte, en cuerpos estáticos simples.

## Valores por instancia en [member instance_transforms]: base (3 x 3, por columnas) y origen.
const FLOATS_PER_INSTANCE: int = 12

## Malla que se repite.
@export var source_mesh: Mesh:
	set(value):
		source_mesh = value
		_rebuild()
## Transformaciones locales, [constant FLOATS_PER_INSTANCE] números por instancia
## (ver [method pack_transforms]).
@export var instance_transforms: PackedFloat32Array = PackedFloat32Array():
	set(value):
		instance_transforms = value
		_rebuild()


## Convierte una lista de transformaciones al formato de [member instance_transforms].
static func pack_transforms(transforms: Array[Transform3D]) -> PackedFloat32Array:
	var data: PackedFloat32Array = PackedFloat32Array()
	data.resize(transforms.size() * FLOATS_PER_INSTANCE)
	for i: int in transforms.size():
		var t: Transform3D = transforms[i]
		var k: int = i * FLOATS_PER_INSTANCE
		for c: int in 3:
			data[k + c * 3] = t.basis[c].x
			data[k + c * 3 + 1] = t.basis[c].y
			data[k + c * 3 + 2] = t.basis[c].z
		data[k + 9] = t.origin.x
		data[k + 10] = t.origin.y
		data[k + 11] = t.origin.z
	return data


## Número de instancias guardadas.
func get_instance_count() -> int:
	return instance_transforms.size() / FLOATS_PER_INSTANCE


func _ready() -> void:
	_rebuild()


func _validate_property(property: Dictionary) -> void:
	if property.name == "multimesh":
		property.usage &= ~PROPERTY_USAGE_STORAGE


func _rebuild() -> void:
	if not is_inside_tree():
		return
	var count: int = get_instance_count()
	if source_mesh == null or count == 0:
		multimesh = null
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = source_mesh
	mm.instance_count = count
	var d: PackedFloat32Array = instance_transforms
	for i: int in count:
		var k: int = i * FLOATS_PER_INSTANCE
		var basis := Basis(Vector3(d[k], d[k + 1], d[k + 2]), Vector3(d[k + 3], d[k + 4], d[k + 5]),
				Vector3(d[k + 6], d[k + 7], d[k + 8]))
		mm.set_instance_transform(i, Transform3D(basis, Vector3(d[k + 9], d[k + 10], d[k + 11])))
	multimesh = mm
