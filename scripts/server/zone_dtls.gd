class_name ZoneDtls
extends RefCounted
## Zone DTLS certificate and key (docs/plataforma.md §10.2, P9c; TEC-27).
## [br][br]
## [code]ServerMain[/code] loads it with [method load_files] from [code]--dtls-cert=<pem>[/code] and
## [code]--dtls-key=<pem>[/code] (paths: in staging and production, Docker secrets mounted at
## [code]/run/secrets/[/code]) and leaves it in [member ServerConfig.dtls]. From there it is used by:
## [br]- [ZoneServer], which opens the port with [member server_options] ([method NetTransport.host]).
## [br]- [ZonePlatform], which sends [member certificate_pem] and [member common_name] in the
## registration (§6): the platform gives them to the client in [code]enter[/code] over HTTPS and the
## client pins that certificate with [method TLSOptions.client] and checks that name.
## [br][br]
## [b]The name.[/b] Godot's [X509Certificate] does not expose the subject, so the [code]CN[/code] is
## read from the DER with a minimal ASN.1 reader ([method certificate_fields]): the first
## [code]commonName[/code] (OID 2.5.4.3) of the subject of the first certificate in the PEM. A
## certificate without [code]CN[/code] is not valid: the client needs it (mbedtls compares it with the
## [code]subjectAltName[/code] if there is one, and with the [code]CN[/code] otherwise).
## [br][br]
## [b]The key.[/b] Godot does not check that the key belongs to the certificate (with one that does not,
## the zone would start and every handshake would fail with one engine error each). Here the public key
## of the key ([method CryptoKey.save_to_string] with [code]public_only[/code]) is compared with the
## [code]subjectPublicKeyInfo[/code] of the certificate, byte by byte.
## [br][br]
## The certificate is pinned by the client as is: self-signed and one per zone, with no CA of its own
## (rotating it means a new certificate and a restart; the client receives the new one on its next
## [code]enter[/code], §10.3).

## Maximum size of the certificate PEM (the same cap as the platform, [code]maxCertPEM[/code]).
const MAX_CERT_PEM_BYTES: int = 16 << 10
## Maximum length of the name (the same as the platform, [code]maxDTLSName[/code]).
const MAX_NAME_BYTES: int = 253
## ASN.1 tags used by the reader.
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
## OID of [code]commonName[/code] (2.5.4.3), already encoded.
const OID_COMMON_NAME: PackedByteArray = [0x55, 0x04, 0x03]

## Certificate PEM exactly as it is in the file (with its chain, if it has one): what goes in the registration.
var certificate_pem: String = ""
## The subject [code]CN[/code] of the first certificate: the [code]dtls_name[/code] of the registration.
var common_name: String = ""
## [method TLSOptions.server] with the key and the certificate, for [method NetTransport.host].
var server_options: TLSOptions = null
## Empty if all went well; otherwise, the reason in Spanish (and everything else stays empty).
var error: String = ""


## Reads the certificate from [param cert_path] and the key from [param key_path] (PEM). On any
## problem (one of the two is missing, cannot be read, the certificate has no [code]CN[/code], the key
## does not belong to the certificate) it returns a [ZoneDtls] with [member error] set.
static func load_files(cert_path: String, key_path: String) -> ZoneDtls:
	if cert_path.is_empty() or key_path.is_empty():
		return _failed("DTLS necesita a la vez --dtls-cert=<pem> y --dtls-key=<pem>")
	if not FileAccess.file_exists(cert_path):
		return _failed("No existe el certificado DTLS %s" % cert_path)
	if not FileAccess.file_exists(key_path):
		return _failed("No existe la clave DTLS %s" % key_path)
	return from_pem(FileAccess.get_file_as_string(cert_path), FileAccess.get_file_as_string(key_path))


## Like [method load_files], with the text of the two PEMs.
static func from_pem(cert_pem: String, key_pem: String) -> ZoneDtls:
	if cert_pem.to_utf8_buffer().size() > MAX_CERT_PEM_BYTES:
		return _failed("El certificado DTLS pasa de %d B" % MAX_CERT_PEM_BYTES)
	# Before handing it to Godot, which logs an engine error on a PEM it does not understand.
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


## true if it loaded correctly.
func is_valid() -> bool:
	return error.is_empty() and server_options != null


## The [code]-----BEGIN <label>-----[/code] blocks of [param pem], in DER and in order. Those that
## are not valid base64 are skipped.
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
		# Marshalls logs an engine error on invalid base64: check beforehand.
		var der: PackedByteArray = Marshalls.base64_to_raw(clean) if _is_base64(clean) else PackedByteArray()
		if not der.is_empty():
			blocks.append(der)
		from = end + end_marker.length()
	return blocks


# true if [param text] is standard padded base64 (non-empty, multiple of 4, the = only at the end).
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


## Reads what is needed from an X.509 certificate in DER: [code]{"common_name": String,
## "public_key": PackedByteArray}[/code] (the first [code]commonName[/code] of the subject, or empty if
## it has none; and the whole [code]subjectPublicKeyInfo[/code], with its header). Empty if the DER
## does not have the shape of a certificate.
static func certificate_fields(der: PackedByteArray) -> Dictionary:
	var certificate: Dictionary = _tlv(der, 0, der.size())
	if certificate.is_empty() or int(certificate["tag"]) != TAG_SEQUENCE:
		return {}
	var tbs: Dictionary = _tlv(der, int(certificate["start"]), int(certificate["end"]))
	if tbs.is_empty() or int(tbs["tag"]) != TAG_SEQUENCE:
		return {}
	# tbsCertificate: [0] version (optional), serialNumber, signature, issuer, validity, subject,
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


# The first commonName of a Name (SEQUENCE OF SET OF SEQUENCE {OID, value}): "" if it has none, null
# if the Name is broken.
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


# The text of an ASN.1 string-type value (UTF-8, Printable, IA5 or Teletex as UTF-8; BMP as UTF-16BE).
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


# The elements inside [param parent] (a TLV from _tlv); empty if any is broken.
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


# A DER TLV that starts at [param at] and does not go past [param limit]: {tag, header (where it
# starts), start (the content), end}. Empty if it does not fit or the length is not DER (one-byte
# tags; lengths of up to 4 B).
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
