#!/usr/bin/env bash
###
# Build the apt + rpm trees into public/ from manifest.json.
# Runs inside the Dockerfile builder stage. Needs: jq curl reprepro createrepo_c gpg.
#
# Signing model: metadata-only. The apt InRelease and the rpm repomd.xml carry our
# signature; package files stay byte-for-byte as upstream shipped them (we don't
# re-sign Carlos's artifacts). The hash chain (signed metadata -> sha256 of every
# package) covers integrity end to end. The .repo file pins repo_gpgcheck=1 and
# gpgcheck=0 to match.
#
# GPG_KEY_FILE must point at the armored private key (a BuildKit secret mount —
# never a layer, never the final image).
###
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/public"
WORK="$ROOT/.work"
BASE_URL="https://pkgs.dwmud.fyi"

[ -n "${GPG_KEY_FILE:-}" ] || { echo "GPG_KEY_FILE not set"; exit 1; }
command -v reprepro >/dev/null || { echo "reprepro missing"; exit 1; }
command -v createrepo_c >/dev/null || { echo "createrepo_c missing"; exit 1; }

rm -rf "$OUT" "$WORK"
mkdir -p "$OUT" "$WORK/apt/conf" "$WORK/pool" "$OUT/rpm"

# throwaway keyring for this build only
export GNUPGHOME="$WORK/gnupg"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
gpg --batch --import "$GPG_KEY_FILE"

###
# Fetch + verify every artifact up front — one bad hash fails the whole build
# before anything is published.
###
count=$(jq '.artifacts | length' "$ROOT/manifest.json")
echo "manifest: $count artifact(s)"
for i in $(seq 0 $((count - 1))); do
    url=$(jq -r ".artifacts[$i].url" "$ROOT/manifest.json")
    sha=$(jq -r ".artifacts[$i].sha256" "$ROOT/manifest.json")
    file="$WORK/pool/$(basename "$url")"
    echo "fetch $(basename "$url")"
    curl -fsSL --retry 3 -o "$file" "$url"
    echo "$sha  $file" | sha256sum -c - >/dev/null || { echo "sha256 MISMATCH for $url"; exit 1; }
done

###
# apt tree — reprepro builds dists/ + pool/ and signs the Release/InRelease
# (SignWith in conf/distributions).
###
cp "$ROOT/conf/distributions" "$WORK/apt/conf/distributions"
for i in $(seq 0 $((count - 1))); do
    [ "$(jq -r ".artifacts[$i].type" "$ROOT/manifest.json")" = "deb" ] || continue
    file="$WORK/pool/$(basename "$(jq -r ".artifacts[$i].url" "$ROOT/manifest.json")")"
    reprepro -b "$WORK/apt" includedeb stable "$file"
done
mkdir -p "$OUT/apt"
cp -r "$WORK/apt/dists" "$WORK/apt/pool" "$OUT/apt/" 2>/dev/null || true

###
# rpm tree — flat dir + repodata, detached-signed repomd.xml. Valid (and served)
# even with zero rpms, so dnf users can configure now and pick up the first
# package the moment one lands in the manifest.
###
for i in $(seq 0 $((count - 1))); do
    [ "$(jq -r ".artifacts[$i].type" "$ROOT/manifest.json")" = "rpm" ] || continue
    cp "$WORK/pool/$(basename "$(jq -r ".artifacts[$i].url" "$ROOT/manifest.json")")" "$OUT/rpm/"
done
createrepo_c --quiet "$OUT/rpm"
gpg --batch --detach-sign --armor "$OUT/rpm/repodata/repomd.xml"

cat > "$OUT/rpm/dwmud.repo" <<EOF
[dwmud]
name=dwmud.FYI packages
baseurl=$BASE_URL/rpm/
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=$BASE_URL/key.asc
EOF

###
# shared bits: public key (armored + dearmored), landing page
###
cp "$ROOT/key.asc" "$OUT/key.asc"
gpg --batch --dearmor < "$ROOT/key.asc" > "$OUT/key.gpg"
cp "$ROOT/public-src/index.html" "$OUT/index.html"

rm -rf "$WORK"
echo "build complete:"
find "$OUT" -type f | sort
