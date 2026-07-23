#!/usr/bin/env bash
###
# Build the pacman tree into public/arch from manifest.json. Runs in the archlinux
# Docker stage (repo-add / makepkg aren't packaged usefully outside Arch). Two kinds
# of arch artifact, keyed on the manifest entry:
#   - url:      a prebuilt .pkg.tar.zst hosted on a release. Download + verify sha256.
#   - pkgbuild: build it here from packaging/arch/<pkg>/PKGBUILD with makepkg (source
#               fetched from GitHub, so cluster egress stays reliable).
# Sign the DATABASE only; the signed db's checksums carry each package's integrity.
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

MAPDB='usr/lib/Luggage/_up_/quow-data/_quowmap_database.db'
count=$(jq '.artifacts | length' "$ROOT/manifest.json")
pkgs=0
for i in $(seq 0 $((count - 1))); do
    [ "$(jq -r ".artifacts[$i].type" "$ROOT/manifest.json")" = "arch" ] || continue
    pkgbase=$(jq -r ".artifacts[$i].package" "$ROOT/manifest.json")
    pb=$(jq -r ".artifacts[$i].pkgbuild // empty" "$ROOT/manifest.json")

    if [ -n "$pb" ]; then
        # build here — makepkg refuses to run as root, so hand it to a builder user
        command -v makepkg >/dev/null || { echo "makepkg missing (need base-devel)"; exit 1; }
        [ -f "$ROOT/$pb/PKGBUILD" ] || { echo "no PKGBUILD at $pb for $pkgbase"; exit 1; }
        id builder &>/dev/null || useradd -m builder
        wd="/tmp/build-$pkgbase"
        rm -rf "$wd"; install -d -o builder -g builder "$wd"
        cp "$ROOT/$pb/PKGBUILD" "$wd/"; chown -R builder:builder "$wd"
        echo "makepkg $pkgbase (from $pb)"
        su builder -c "cd '$wd' && makepkg -f --nodeps --noconfirm"
        built=$(find "$wd" -maxdepth 1 -name '*.pkg.tar.zst' | head -1)
        [ -n "$built" ] || { echo "makepkg produced no package for $pkgbase"; exit 1; }
        cp "$built" "$OUT/"
        file="$OUT/$(basename "$built")"
    else
        url=$(jq -r ".artifacts[$i].url" "$ROOT/manifest.json")
        sha=$(jq -r ".artifacts[$i].sha256" "$ROOT/manifest.json")
        file="$OUT/$(basename "$url")"
        echo "fetch $(basename "$url")"
        curl -fsSL --retry 3 -o "$file" "$url"
        echo "$sha  $file" | sha256sum -c - >/dev/null || { echo "sha256 MISMATCH for $url"; exit 1; }
    fi

    # content guard: Luggage once shipped without its map db. Scoped to luggage-desktop.
    if [ "$pkgbase" = "luggage-desktop" ]; then
        bsdtar -tf "$file" | grep "$MAPDB" >/dev/null \
            || { echo "GUARD FAIL: $(basename "$file") is missing the map db"; exit 1; }
    fi
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
