#!/usr/bin/env bash
###
# Push packaging/arch/<pkg>/PKGBUILD to the AUR when it differs from what's published.
#
# Single-source-of-truth flow: the PKGBUILD here drives BOTH the binary pacman repo
# (build-arch-repo.sh serves the built package) and the AUR listing (this script).
# .SRCINFO is regenerated from the PKGBUILD every run — never hand-edited.
#
# Clone AND push over ssh with the dedicated CI key (AUR_KEY_FILE) — the AUR's edge
# intermittently resets anonymous https from datacenter networks, and ssh is the
# channel we need for the push anyway. Clone retries 3x for the AUR's flaky moments.
# Host keys are pinned from packaging/aur/known_hosts — no ssh-keyscan TOFU at run
# time. Idempotent: identical PKGBUILD+.SRCINFO = no push.
###
set -euo pipefail

PKG="${1:?usage: publish-aur.sh <pkgname>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[ -f "$ROOT/packaging/arch/$PKG/PKGBUILD" ] || { echo "no PKGBUILD for $PKG"; exit 1; }
[ -n "${AUR_KEY_FILE:-}" ] || { echo "AUR_KEY_FILE not set"; exit 1; }

docker run --rm \
    -v "$ROOT/packaging/arch/$PKG:/pkgsrc:ro" \
    -v "$ROOT/packaging/aur/known_hosts:/aur_known_hosts:ro" \
    -v "$(readlink -f "$AUR_KEY_FILE"):/aur_key_ro:ro" \
    -e PKG="$PKG" \
    archlinux:base bash -ec '
        pacman -Sy --noconfirm --needed git openssh >/dev/null 2>&1

        useradd -m builder
        install -d -m700 -o builder -g builder /home/builder/.ssh
        install -m600 -o builder -g builder /aur_key_ro /home/builder/.ssh/aur_key
        install -m644 -o builder -g builder /aur_known_hosts /home/builder/.ssh/known_hosts

        # regenerate .SRCINFO from the PKGBUILD (makepkg refuses root; builder does it)
        su builder -c "mkdir -p /tmp/gen && cp /pkgsrc/PKGBUILD /tmp/gen/ && cd /tmp/gen && makepkg --printsrcinfo > .SRCINFO"

        export GIT_SSH="/usr/local/bin/aur-ssh"
        printf "#!/bin/sh\nexec ssh -i /home/builder/.ssh/aur_key -o UserKnownHostsFile=/home/builder/.ssh/known_hosts -o IdentitiesOnly=yes \"\$@\"\n" > /usr/local/bin/aur-ssh
        chmod 755 /usr/local/bin/aur-ssh

        ok=""
        for attempt in 1 2 3; do
            if su builder -c "GIT_SSH=/usr/local/bin/aur-ssh git clone -q ssh://aur@aur.archlinux.org/$PKG.git /tmp/aur"; then
                ok=1; break
            fi
            echo "clone attempt $attempt failed; retrying in 10s"
            rm -rf /tmp/aur
            sleep 10
        done
        [ -n "$ok" ] || { echo "could not clone AUR repo after 3 attempts"; exit 1; }
        cd /tmp/aur
        cp /pkgsrc/PKGBUILD /tmp/gen/.SRCINFO .
        if su builder -c "cd /tmp/aur && git diff --quiet"; then
            echo "AUR already current for $PKG — nothing to push."
            exit 0
        fi

        ver=$(grep -m1 "pkgver = " .SRCINFO | cut -d= -f2 | tr -d " ")
        rel=$(grep -m1 "pkgrel = " .SRCINFO | cut -d= -f2 | tr -d " ")
        chown -R builder:builder /tmp/aur
        su builder -c "
            cd /tmp/aur &&
            git config user.name \"dwmud.FYI\" &&
            git config user.email \"pkgs@dwmud.fyi\" &&
            git add PKGBUILD .SRCINFO &&
            git commit -q -m \"Update to $ver-$rel\" &&
            GIT_SSH=/usr/local/bin/aur-ssh git push origin master
        "
        echo "AUR updated: $PKG $ver-$rel"
    '
