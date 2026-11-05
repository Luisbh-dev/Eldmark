#!/usr/bin/env bash
# CI secrets check (docs/platform.md §10.3). Fails if the git index contains any *.env, anything under a
# secrets/ directory or a *.pem or *.key outside tests/, or if a platform/deploy/*.example has the value of a
# secret (ELDMARK_TICKET_KEYS=…, ELDMARK_ZONE_TOKENS=…, ELDMARK_ZONE_TOKEN=…, ELDMARK_SMTP_URL=…,
# ELDMARK_DATABASE_URL=… or ELDMARK_EMAIL_HMAC_KEY=…; the *_FILE variables holding the path to the secret are fine).
#
# Usage: tools/check_secrets.sh [repository root]   (by default, the current repository's)
set -euo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"
cd "$root"

status=0

tracked="$(git ls-files)"
offenders="$(printf '%s\n' "$tracked" | grep -E '(^|/)[^/]*\.env$|(^|/)secrets/|\.(pem|key)$' | grep -vE '^tests/.*\.(pem|key)$' || true)"
if [ -n "$offenders" ]; then
	echo "El índice de git lleva archivos que pueden ser secretos (ver docs/platform.md §10.3):"
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

# Binary policy (.gitattributes): no Git LFS pointers committed as normal files and no file over 50 MB.
pointers="$(git grep -l -I --cached -E '^version https://git-lfs\.github\.com/spec/v1$' || true)"
if [ -n "$pointers" ]; then
	echo "El índice lleva punteros de Git LFS (los binarios son blobs normales, ver .gitattributes):"
	printf '%s\n' "$pointers" | sed 's/^/  /'
	status=1
fi
big="$(git ls-files -s | awk '{ print $2 }' | git cat-file --batch-check='%(objectsize)' |
	awk -v max=$((50 * 1024 * 1024)) '$1 > max { print NR }' | while read -r n; do
	git ls-files | sed -n "${n}p"
done || true)"
if [ -n "$big" ]; then
	echo "Archivos de más de 50 MB en el índice (ver CONTRIBUTING.md):"
	printf '%s\n' "$big" | sed 's/^/  /'
	status=1
fi

if [ "$status" -eq 0 ]; then
	echo "Sin secretos en el índice ni en los ejemplos."
fi
exit "$status"
