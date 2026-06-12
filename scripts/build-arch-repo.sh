#!/usr/bin/env bash
###
# Build the pacman tree into public/arch from manifest.json. Runs in the archlinux
# Docker stage (repo-add isn't packaged usefully outside Arch). Same model as the
# apt/rpm script: download, verify sha256, sign the DATABASE only — packages stay
# byte-for-byte as built, the signed db's checksums carry their integrity.
# pacman.conf side: SigLevel = PackageNever DatabaseRequired
###
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/public/arch"

[ -n "${GPG_KEY_FILE:-}" ] || { echo "GPG_KEY_FILE not set"; exit 1; }
command -v repo-add >/dev/null || { echo "repo-add missing"; exit 1; }

mkdir -p "$OUT"
export GNUPGHOME="$(mktemp -d)"
chmod 700 "$GNUPGHOME"
gpg --batch --import "$GPG_KEY_FILE"

count=$(jq '.artifacts | length' "$ROOT/manifest.json")
pkgs=0
for i in $(seq 0 $((count - 1))); do
    [ "$(jq -r ".artifacts[$i].type" "$ROOT/manifest.json")" = "arch" ] || continue
    url=$(jq -r ".artifacts[$i].url" "$ROOT/manifest.json")
    sha=$(jq -r ".artifacts[$i].sha256" "$ROOT/manifest.json")
    file="$OUT/$(basename "$url")"
    echo "fetch $(basename "$url")"
    curl -fsSL --retry 3 -o "$file" "$url"
    echo "$sha  $file" | sha256sum -c - >/dev/null || { echo "sha256 MISMATCH for $url"; exit 1; }
    pkgs=$((pkgs + 1))
done

# repo-add tolerates zero packages (creates an empty but valid db), matching the
# rpm repo's live-but-empty behaviour while a format waits on its first artifact.
repo-add --sign --key 1D19FE3C95B59712 "$OUT/dwmud.db.tar.gz" "$OUT"/*.pkg.tar.zst 2>/dev/null \
    || repo-add --sign --key 1D19FE3C95B59712 "$OUT/dwmud.db.tar.gz"

# pacman fetches $repo.db / $repo.db.sig — repo-add leaves those as symlinks, which
# survive the COPY into the final image as real files. Make them real here anyway
# so the tree is self-contained regardless of how it's copied.
for f in db files; do
    [ -L "$OUT/dwmud.$f" ] && cp --remove-destination "$(readlink -f "$OUT/dwmud.$f")" "$OUT/dwmud.$f"
    [ -L "$OUT/dwmud.$f.sig" ] && cp --remove-destination "$(readlink -f "$OUT/dwmud.$f.sig")" "$OUT/dwmud.$f.sig"
done

rm -rf "$GNUPGHOME"
echo "arch repo: $pkgs package(s)"
ls -la "$OUT"
