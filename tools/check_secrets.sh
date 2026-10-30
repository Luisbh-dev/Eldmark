#!/usr/bin/env bash
# Comprobación de secretos de la CI (docs/plataforma.md §10.3). Falla si el índice de git lleva
# algún *.env, algo bajo un directorio secrets/ o un *.pem o *.key fuera de tests/, o si un
# platform/deploy/*.example trae el valor de un secreto (ELDMARK_TICKET_KEYS=…, ELDMARK_ZONE_TOKENS=…,
# ELDMARK_ZONE_TOKEN=…, ELDMARK_SMTP_URL=…, ELDMARK_DATABASE_URL=… o ELDMARK_EMAIL_HMAC_KEY=…; las
# variables *_FILE con la ruta del secreto sí valen).
#
# Uso: tools/check_secrets.sh [raíz del repositorio]   (por defecto, la del repositorio actual)
set -euo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"
cd "$root"

status=0

tracked="$(git ls-files)"
offenders="$(printf '%s\n' "$tracked" | grep -E '(^|/)[^/]*\.env$|(^|/)secrets/|\.(pem|key)$' | grep -vE '^tests/.*\.(pem|key)$' || true)"
if [ -n "$offenders" ]; then
	echo "El índice de git lleva archivos que pueden ser secretos (ver docs/plataforma.md §10.3):"
	printf '%s\n' "$offenders" | sed 's/^/  /'
	status=1
fi

shopt -s nullglob
examples=(platform/deploy/*.example)
if [ ${#examples[@]} -gt 0 ]; then
	if leaks="$(grep -HnE 'ELDMARK_(TICKET_KEYS|ZONE_TOKENS?|SMTP_URL|DATABASE_URL|EMAIL_HMAC_KEY)=[^[:space:]]' "${examples[@]}")"; then
		echo "Un ejemplo de configuración trae el valor de un secreto (usa la variable *_FILE con la ruta):"
		printf '%s\n' "$leaks" | sed 's/=.*/=…/; s/^/  /'
		status=1
	fi
fi

if [ "$status" -eq 0 ]; then
	echo "Sin secretos en el índice ni en los ejemplos."
fi
exit "$status"
