class_name ZoneDtls
extends RefCounted
## Certificado y clave DTLS de la zona (docs/plataforma.md §10.2, P9c; TEC-27).
## [br][br]
## [code]ServerMain[/code] lo carga con [method load_files] de [code]--dtls-cert=<pem>[/code] y
## [code]--dtls-key=<pem>[/code] (rutas: en staging y producción, secretos de Docker montados en
## [code]/run/secrets/[/code]) y lo deja en [member ServerConfig.dtls]. De ahí lo usan:
## [br]- [ZoneServer], que abre el puerto con [member server_options] ([method NetTransport.host]).
## [br]- [ZonePlatform], que manda [member certificate_pem] y [member common_name] en el registro (§6): la
## plataforma los da al cliente en [code]enter[/code] por HTTPS y el cliente ancla ese certificado con
## [method TLSOptions.client] y comprueba ese nombre.
## [br][br]
## [b]El nombre.[/b] [X509Certificate] de Godot no da el sujeto, así que el [code]CN[/code] se lee del DER con
## un lector mínimo de ASN.1 ([method certificate_fields]): el primer [code]commonName[/code] (OID 2.5.4.3) del
## sujeto del primer certificado del PEM. Un certificado sin [code]CN[/code] no vale: el cliente lo necesita
## (mbedtls lo compara con el [code]subjectAltName[/code] si lo hay, y si no con el [code]CN[/code]).
## [br][br]
## [b]La clave.[/b] Godot no comprueba que la clave sea la del certificado (con una que no lo es, la zona
## arrancaría y todos los apretones de manos fallarían con un error del motor cada uno). Aquí se compara la clave
## pública de la clave ([method CryptoKey.save_to_string] con [code]public_only[/code]) con la
## [code]subjectPublicKeyInfo[/code] del certificado, byte a byte.
## [br][br]
## El certificado lo ancla el cliente tal cual: autofirmado y uno por zona, sin CA propia (rotarlo es un
## certificado nuevo y un reinicio; el cliente recibe el nuevo en su siguiente [code]enter[/code], §10.3).

## Tamaño máximo del PEM del certificado (el mismo tope que la plataforma, [code]maxCertPEM[/code]).
const MAX_CERT_PEM_BYTES: int = 16 << 10
## Largo máximo del nombre (el mismo que la plataforma, [code]maxDTLSName[/code]).
const MAX_NAME_BYTES: int = 253
## Etiquetas de ASN.1 que usa el lector.
const TAG_SEQUENCE: int = 0x30
const TAG_SET: int = 0x31
const TAG_OID: int = 0x06
const TAG_INTEGER: int = 0x02
const TAG_VERSION: int = 0xA0
const TAG_UTF8_STRING: int = 0x0C
const TAG_PRINTABLE_STRING: int = 0x13
const TAG_TELETEX_STRING: int = 0x14
const TAG_IA5_STRING: int = 0x16
const TAG_BMP_STRING: int = 0x1E
## OID de [code]commonName[/code] (2.5.4.3) ya codificado.
const OID_COMMON_NAME: PackedByteArray = [0x55, 0x04, 0x03]

## PEM del certificado tal como está en el archivo (con su cadena, si la trae): lo que va al registro.
var certificate_pem: String = ""
## El [code]CN[/code] del sujeto del primer certificado: el [code]dtls_name[/code] del registro.
var common_name: String = ""
## [method TLSOptions.server] con la clave y el certificado, para [method NetTransport.host].
var server_options: TLSOptions = null
## Vacío si todo ha ido bien; si no, el motivo en español (y lo demás queda vacío).
var error: String = ""


## Lee el certificado de [param cert_path] y la clave de [param key_path] (PEM). Con cualquier problema
## (falta una de las dos, no se puede leer, el certificado no tiene [code]CN[/code], la clave no es la del
## certificado) devuelve un [ZoneDtls] con [member error] puesto.
static func load_files(cert_path: String, key_path: String) -> ZoneDtls:
	if cert_path.is_empty() or key_path.is_empty():
		return _failed("DTLS necesita a la vez --dtls-cert=<pem> y --dtls-key=<pem>")
	if not FileAccess.file_exists(cert_path):
		return _failed("No existe el certificado DTLS %s" % cert_path)
	if not FileAccess.file_exists(key_path):
		return _failed("No existe la clave DTLS %s" % key_path)
	return from_pem(FileAccess.get_file_as_string(cert_path), FileAccess.get_file_as_string(key_path))


## Como [method load_files], con el texto de los dos PEM.
static func from_pem(cert_pem: String, key_pem: String) -> ZoneDtls:
	if cert_pem.to_utf8_buffer().size() > MAX_CERT_PEM_BYTES:
		return _failed("El certificado DTLS pasa de %d B" % MAX_CERT_PEM_BYTES)
	# Antes de dárselo a Godot, que registra un error del motor con un PEM que no entiende.
	var ders: Array[PackedByteArray] = pem_blocks(cert_pem, "CERTIFICATE")
	if ders.is_empty():
		return _failed("El certificado DTLS no es un PEM válido")
	var fields: Dictionary = certificate_fields(ders[0])
	if fields.is_empty():
		return _failed("No se entiende el certificado DTLS")
	if not key_pem.contains("-----BEGIN") or not key_pem.contains("PRIVATE KEY-----") \
			or key_pem.contains("ENCRYPTED"):
		return _failed("La clave DTLS no es un PEM de clave privada sin contraseña")
	var certificate := X509Certificate.new()
	if certificate.load_from_string(cert_pem) != OK:
		return _failed("El certificado DTLS no es un PEM válido")
	var key := CryptoKey.new()
	if key.load_from_string(key_pem) != OK:
		return _failed("La clave DTLS no es un PEM válido")
	var name: String = String(fields["common_name"])
	if name.is_empty():
		return _failed("El certificado DTLS no tiene CN (commonName): el cliente lo necesita para comprobarlo")
	if name.to_utf8_buffer().size() > MAX_NAME_BYTES:
		return _failed("El CN del certificado DTLS pasa de %d B" % MAX_NAME_BYTES)
	var public_blocks: Array[PackedByteArray] = pem_blocks(key.save_to_string(true), "PUBLIC KEY")
	if public_blocks.is_empty() or public_blocks[0] != (fields["public_key"] as PackedByteArray):
		return _failed("La clave DTLS no es la del certificado")
	var dtls := ZoneDtls.new()
	dtls.certificate_pem = cert_pem
	dtls.common_name = name
	dtls.server_options = TLSOptions.server(key, certificate)
	return dtls


## true si se ha cargado bien.
func is_valid() -> bool:
	return error.is_empty() and server_options != null


## Los bloques [code]-----BEGIN <label>-----[/code] de [param pem], en DER y en orden. Los que no son base64
## válido se saltan.
static func pem_blocks(pem: String, label: String) -> Array[PackedByteArray]:
	var blocks: Array[PackedByteArray] = []
	var begin_marker: String = "-----BEGIN %s-----" % label
	var end_marker: String = "-----END %s-----" % label
	var from: int = 0
	while true:
		var begin: int = pem.find(begin_marker, from)
		if begin < 0:
			break
		var body_start: int = begin + begin_marker.length()
		var end: int = pem.find(end_marker, body_start)
		if end < 0:
			break
		var body: String = pem.substr(body_start, end - body_start)
		var clean: String = ""
		for part: String in body.split("\n"):
			clean += part.strip_edges()
		# Marshalls registra un error del motor con un base64 que no vale: se mira antes.
		var der: PackedByteArray = Marshalls.base64_to_raw(clean) if _is_base64(clean) else PackedByteArray()
		if not der.is_empty():
			blocks.append(der)
		from = end + end_marker.length()
	return blocks


# true si [param text] es base64 estándar con relleno (no vacío, múltiplo de 4, el = solo al final).
static func _is_base64(text: String) -> bool:
	if text.is_empty() or text.length() % 4 != 0:
		return false
	var padding: int = 0
	for i: int in text.length():
		var c: int = text.unicode_at(i)
		if c == 0x3D:
			padding += 1
			continue
		if padding > 0:
			return false
		var valid: bool = (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A) or (c >= 0x30 and c <= 0x39) \
				or c == 0x2B or c == 0x2F
		if not valid:
			return false
	return padding <= 2


## Lee lo que hace falta de un certificado X.509 en DER: [code]{"common_name": String,
## "public_key": PackedByteArray}[/code] (el primer [code]commonName[/code] del sujeto, o vacío si no tiene; y
## la [code]subjectPublicKeyInfo[/code] entera, con su cabecera). Vacío si el DER no tiene la forma de un
## certificado.
static func certificate_fields(der: PackedByteArray) -> Dictionary:
	var certificate: Dictionary = _tlv(der, 0, der.size())
	if certificate.is_empty() or int(certificate["tag"]) != TAG_SEQUENCE:
		return {}
	var tbs: Dictionary = _tlv(der, int(certificate["start"]), int(certificate["end"]))
	if tbs.is_empty() or int(tbs["tag"]) != TAG_SEQUENCE:
		return {}
	# tbsCertificate: [0] version (opcional), serialNumber, signature, issuer, validity, subject,
	# subjectPublicKeyInfo...
	var elements: Array[Dictionary] = _children(der, tbs)
	var index: int = 0
	if index < elements.size() and int(elements[index]["tag"]) == TAG_VERSION:
		index += 1
	if elements.size() < index + 6 or int(elements[index]["tag"]) != TAG_INTEGER:
		return {}
	var subject: Dictionary = elements[index + 4]
	var public_key: Dictionary = elements[index + 5]
	if int(subject["tag"]) != TAG_SEQUENCE or int(public_key["tag"]) != TAG_SEQUENCE:
		return {}
	var common_name: Variant = _common_name(der, subject)
	if common_name == null:
		return {}
	return {
		"common_name": common_name,
		"public_key": der.slice(int(public_key["header"]), int(public_key["end"])),
	}


# El primer commonName de un Name (SEQUENCE OF SET OF SEQUENCE {OID, valor}): "" si no tiene, null si el Name
# está roto.
static func _common_name(der: PackedByteArray, name: Dictionary) -> Variant:
	for rdn: Dictionary in _children(der, name):
		if int(rdn["tag"]) != TAG_SET:
			return null
		for attribute: Dictionary in _children(der, rdn):
			if int(attribute["tag"]) != TAG_SEQUENCE:
				return null
			var parts: Array[Dictionary] = _children(der, attribute)
			if parts.size() < 2 or int(parts[0]["tag"]) != TAG_OID:
				return null
			if der.slice(int(parts[0]["start"]), int(parts[0]["end"])) != OID_COMMON_NAME:
				continue
			return _string_value(der, parts[1])
	return ""


# El texto de un valor de tipo cadena de ASN.1 (UTF-8, Printable, IA5 o Teletex como UTF-8; BMP en UTF-16BE).
static func _string_value(der: PackedByteArray, value: Dictionary) -> Variant:
	var bytes: PackedByteArray = der.slice(int(value["start"]), int(value["end"]))
	match int(value["tag"]):
		TAG_UTF8_STRING, TAG_PRINTABLE_STRING, TAG_IA5_STRING, TAG_TELETEX_STRING:
			return bytes.get_string_from_utf8()
		TAG_BMP_STRING:
			if bytes.size() % 2 != 0:
				return null
			var swapped := PackedByteArray()
			swapped.resize(bytes.size())
			for i: int in range(0, bytes.size(), 2):
				swapped[i] = bytes[i + 1]
				swapped[i + 1] = bytes[i]
			return swapped.get_string_from_utf16()
	return null


# Los elementos que hay dentro de [param parent] (un TLV de _tlv); vacío si alguno está roto.
static func _children(der: PackedByteArray, parent: Dictionary) -> Array[Dictionary]:
	var children: Array[Dictionary] = []
	var at: int = int(parent["start"])
	var end: int = int(parent["end"])
	while at < end:
		var child: Dictionary = _tlv(der, at, end)
		if child.is_empty():
			return []
		children.append(child)
		at = int(child["end"])
	return children


# Un TLV de DER que empieza en [param at] y no pasa de [param limit]: {tag, header (donde empieza), start (el
# contenido), end}. Vacío si no cabe o la longitud no es DER (etiquetas de un byte; longitudes de hasta 4 B).
static func _tlv(der: PackedByteArray, at: int, limit: int) -> Dictionary:
	if at < 0 or at + 2 > limit or limit > der.size():
		return {}
	var tag: int = der[at]
	if tag & 0x1F == 0x1F:
		return {}
	var length: int = der[at + 1]
	var start: int = at + 2
	if length & 0x80 != 0:
		var count: int = length & 0x7F
		if count == 0 or count > 4 or start + count > limit:
			return {}
		length = 0
		for i: int in count:
			length = (length << 8) | der[start + i]
		start += count
	var end: int = start + length
	if end > limit:
		return {}
	return {"tag": tag, "header": at, "start": start, "end": end}


static func _failed(reason: String) -> ZoneDtls:
	var dtls := ZoneDtls.new()
	dtls.error = reason
	return dtls
