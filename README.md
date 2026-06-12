# dwmud.FYI package repository

apt (.deb) + rpm repos for the Discworld MUD community, served at
<https://pkgs.dwmud.fyi>. Currently distributes [Luggage](https://callmecarlos.com/).

## How it works

Everything is manifest-driven and immutable:

- `manifest.json` lists every artifact: package, version, type, a stable download
  URL, and its sha256.
- CI (`publish.yml`, on the dwmud ARC runners) downloads + verifies the artifacts,
  builds the apt tree with `reprepro` and the rpm tree with `createrepo_c`, signs
  the metadata, bakes the whole thing into an nginx image, and rolls
  `deployment/dwmud-pkgs` on sherm.
- No PVC, no in-place publishing. Rollback = roll back the image.

Package files are served byte-for-byte as upstream shipped them — we sign the repo
**metadata** (apt `InRelease`, rpm `repomd.xml.asc`), and the metadata's checksums
cover package integrity. We never re-sign someone else's artifact.

## Publishing a new release

1. Upload the artifact somewhere with a stable URL. House default: a release on
   this repo —

   ```
   gh release create luggage-v<VER> --notes "Luggage <VER> artifacts" <file>.deb [<file>.rpm]
   ```

2. Add an entry to `manifest.json` (`sha256sum` the file first).
3. Commit + push to main. CI does the rest (~2 min).

### Arch packages

There's no upstream `.pkg.tar.zst` — we repackage the .deb via
`packaging/arch/luggage/PKGBUILD` (the standard `-bin` pattern, dependencies mapped
to Arch package names). For a new Luggage release: bump `pkgver` + `sha256sums`,
`makepkg -f`, upload the resulting `.pkg.tar.zst` to the same release, add the
manifest entry. The pacman db is signed by the same key; packages are covered by
the db's checksums (`SigLevel = PackageNever DatabaseRequired`).

## Keys + secrets

- Signing key: `dwmud.FYI Package Repository <pkgs@dwmud.fyi>` / `1D19FE3C95B59712`,
  RSA-4096, no expiry. Public half is committed (`key.asc`); private half lives in
  the `GPG_PRIVATE_KEY` repo secret and the offline backup (keyring + revocation
  cert in the usual credentials spot).
- If the key is ever compromised: revoke with the stored revocation certificate,
  generate a fresh key, update `SignWith` in `conf/distributions`, replace
  `key.asc` + the secret, republish. Users re-run the one-line key install.
- `DHI_TOKEN` / `DHI_USERNAME` — pull creds for the hardened nginx base image,
  same as the web repo.

## Layout served

```
/                 landing page with setup instructions
/key.asc          armored public key   (apt signed-by + dnf gpgkey)
/key.gpg          dearmored copy
/apt/             dists/ + pool/  (reprepro)
/rpm/             *.rpm + repodata/ + dwmud.repo
```
