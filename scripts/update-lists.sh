#!/bin/bash
# scripts/update-lists.sh — refreshes lists/custom/*.lst from scripts/seeds.json.
#
# For every candidate domain in seeds.json: check it actually resolves and
# answers a TLS handshake on :443, keep only the ones that are alive, and
# rewrite the corresponding lists/custom/<key>.lst with a generated header.
# Run by .github/workflows/update-domain-lists.yml on a schedule; also runnable
# locally: `bash scripts/update-lists.sh`.
#
# This is intentionally a *verifier/pruner* over a maintainer-curated candidate
# pool (seeds.json), not an open-ended internet crawler — that keeps the list
# trustworthy (no random third-party domains sneaking in) while still being
# "run it and it goes and checks/updates things for you".

set -euo pipefail
cd "$(dirname "$0")/.."

SEEDS="scripts/seeds.json"
OUT_DIR="lists/custom"
NOW="$(date -u +%Y-%m-%d)"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

check_domain() {
	local d="$1"
	timeout 5 bash -c "echo | openssl s_client -connect '$d:443' -servername '$d' 2>/dev/null" \
		| grep -q "CONNECTED" && return 0
	# fallback: plain TCP connect if openssl isn't happy (e.g. no TLS on 443 for some reason)
	timeout 5 bash -c "cat < /dev/null > /dev/tcp/$d/443" 2>/dev/null
}

keys="$(jq -r 'keys[] | select(startswith("_")|not)' "$SEEDS")"

for key in $keys; do
	echo "== $key =="
	alive=()
	dead=()
	while IFS= read -r domain; do
		if check_domain "$domain"; then
			echo "  [alive] $domain"
			alive+=("$domain")
		else
			echo "  [dead]  $domain"
			dead+=("$domain")
		fi
	done < <(jq -r --arg k "$key" '.[$k][]' "$SEEDS")

	out="$OUT_DIR/$key.lst"
	{
		echo "# $key — auto-verified $NOW by .github/workflows/update-domain-lists.yml"
		echo "# candidates come from scripts/seeds.json; only reachable domains are kept here."
		if [ "${#dead[@]}" -gt 0 ]; then
			echo "# dropped as unreachable this run: ${dead[*]}"
		fi
		printf '%s\n' "${alive[@]}" | sort -u
	} > "$out"
done

echo "Done. Diff:"
git --no-pager diff --stat -- "$OUT_DIR" || true
