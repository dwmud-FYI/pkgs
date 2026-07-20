# dwmud.FYI package repository

apt (.deb), rpm, and pacman repos — plus the AUR listing — for the Discworld MUD
community, served at <https://pkgs.dwmud.fyi>. Currently distributes
[Luggage](https://callmecarlos.com/), Carlos's Discworld MUD client.

This repo is deliberately public: it holds the manifest, the build scripts, and the
*public* signing key — nothing secret — and anyone trusting our key can audit
exactly how the repos are built.

## System requirements

Luggage's binary is built against **glibc 2.39**, so it only runs on reasonably
current systems:

| Works | Too old (won't run) |
|-------|---------------------|
| Ubuntu 24.04+, Debian 13+ | Ubuntu 22.04 and older, Debian 12 |
| Fedora 40+ | Fedora 39 and older, RHEL/Rocky/Alma 9 |
| Arch / any rolling distro | |

The packages declare this floor (`libc6 >= 2.39` on the deb, a `GLIBC_2.39` requirement
on the rpm), so apt/dnf refuse to install on an older system with a clear message
rather than installing something that fails at launch. If you're on an older release,
upgrade the OS (e.g. Ubuntu `do-release-upgrade` to 24.04) or run Luggage inside a
[distrobox](https://distrobox.it/) container based on a newer image.

## Installing

### Debian / Ubuntu (apt)

```sh
sudo curl -fsSL https://pkgs.dwmud.fyi/key.asc -o /etc/apt/keyrings/dwmud.asc
echo "deb [signed-by=/etc/apt/keyrings/dwmud.asc] https://pkgs.dwmud.fyi/apt stable main" | sudo tee /etc/apt/sources.list.d/dwmud.list
sudo apt update
sudo apt install luggage
```

> Tray-icon dependency: upstream's .deb/.rpm pin a single appindicator library
> that flip-flops between builds (libappindicator3 vs the ayatana fork), which
> breaks apt/dnf resolution on whichever distros ship only the other one. Our
> packaged deb and rpm replace it with an either/or dependency
> (`libayatana-appindicator3-1 | libappindicator3-1`), so both current and older
> releases resolve; the binary loads whichever is installed. No user action needed.

### Fedora / RHEL-family (dnf)

```sh
sudo curl -fsSL https://pkgs.dwmud.fyi/rpm/dwmud.repo -o /etc/yum.repos.d/dwmud.repo
sudo dnf install luggage
```

The rpm repo is live but waiting on upstream's first .rpm — configure it now and
`dnf` picks Luggage up the moment it lands.

### Arch Linux (binary repo)

```sh
curl -fsSL https://pkgs.dwmud.fyi/key.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key 1D19FE3C95B59712
```

Append to `/etc/pacman.conf`:

```ini
[dwmud]
SigLevel = PackageNever DatabaseRequired
Server = https://pkgs.dwmud.fyi/arch
```

Then:

```sh
sudo pacman -Sy luggage-desktop
```

### Arch Linux (AUR)

The same package is published as
[`luggage-desktop`](https://aur.archlinux.org/packages/luggage-desktop) and kept in
lockstep with this repo's PKGBUILD by CI:

```sh
yay -S luggage-desktop        # or: paru -S luggage-desktop
```

Or by hand:

```sh
git clone https://aur.archlinux.org/luggage-desktop.git
cd luggage-desktop && makepkg -si
```

> Naming note: the apt package is `luggage` (upstream's own .deb name); the Arch
> package is `luggage-desktop` (the AUR listing's name, which the binary repo
> matches so the two channels never conflict on one machine).

## How it works

Everything is manifest-driven and immutable:

- `manifest.json` lists every artifact: package, version, type, a stable download
  URL, and its sha256.
- CI (`publish.yml`, on the dwmud ARC runners) downloads + verifies the artifacts,
  builds the apt tree with `reprepro`, the rpm tree with `createrepo_c`, and the
  pacman tree with `repo-add`, signs the metadata, bakes the whole thing into an
  nginx image, and rolls `deployment/dwmud-pkgs` on sherm.
- No PVC, no in-place publishing. Rollback = roll back the image.

Package files are served byte-for-byte as upstream shipped them — we sign the repo
**metadata** (apt `InRelease`, rpm `repomd.xml.asc`, pacman `dwmud.db.sig`), and the
metadata's checksums cover package integrity. We never re-sign someone else's
artifact. The matching client settings: apt's `signed-by`, dnf's
`repo_gpgcheck=1` + `gpgcheck=0`, pacman's `PackageNever DatabaseRequired`.

## Publishing a new release

1. Upload the artifacts somewhere with a stable URL. House default: a release on
   this repo —

   ```sh
   gh release create luggage-v<VER> --notes "Luggage <VER> artifacts" <file>.deb [<file>.rpm]
   ```

2. Add an entry per artifact to `manifest.json` (`sha256sum` the file first).
3. Commit + push to main. CI does the rest (~2 min).

### Arch packages + AUR

There's no upstream `.pkg.tar.zst` — `packaging/arch/luggage-desktop/PKGBUILD`
repackages the .deb (sourced from upstream's stable URL, deps mapped to Arch names,
.desktop Categories fixed). That one PKGBUILD drives **both** Arch channels:

- **binary repo** — for a new release: bump `pkgver` + `sha256sums`, `makepkg -f`,
  upload the `.pkg.tar.zst` to the release, add the manifest entry.
- **AUR** — CI regenerates `.SRCINFO` from the PKGBUILD and pushes to the AUR git
  remote whenever they differ from what's published (`scripts/publish-aur.sh`,
  runs after every successful repo build, no-ops when current). Pushes
  authenticate with the dedicated `AUR_SSH_KEY` CI key; AUR host keys are pinned
  in `packaging/aur/known_hosts`, no TOFU at run time.

## Keys + secrets

- **Repo signing key**: `dwmud.FYI Package Repository <pkgs@dwmud.fyi>` /
  `1D19FE3C95B59712`, RSA-4096, no expiry. Public half is committed (`key.asc`);
  private half lives in the `GPG_PRIVATE_KEY` repo secret, with custody backups
  (keyring + revocation certificate) in the secrets manager.
- **AUR CI key**: dedicated ed25519 keypair; private half in the `AUR_SSH_KEY`
  repo secret, public half registered on the maintainer's AUR account. Custody
  backup in the secrets manager alongside the signing key.
- If the signing key is ever compromised: revoke with the stored revocation
  certificate, generate a fresh key, update `SignWith` in `conf/distributions` and
  the keyid baked into `scripts/build-arch-repo.sh` + the docs, replace `key.asc` +
  the secret, republish. Users re-run the one-line key install.
- `DHI_TOKEN` / `DHI_USERNAME` — pull creds for the hardened nginx base image.

## Layout served

```
/                 landing page with setup instructions
/key.asc          armored public key   (apt signed-by · dnf gpgkey · pacman-key add)
/key.gpg          dearmored copy
/apt/             dists/ + pool/  (reprepro)
/rpm/             *.rpm + repodata/ + dwmud.repo
/arch/            *.pkg.tar.zst + dwmud.db[.sig]
```
