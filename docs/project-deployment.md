# Bounded project deployment

`skyrim-agent deploy` copies only files explicitly named by a project's deployment
registry into an exact registered MO2 mod target.

Hoarfrost's current native candidate dry-run is:

```bash
skyrim-agent deploy hoarfrost \
  --environment assos \
  --target development \
  --set ordinary-finger-native \
  --build-evidence /home/wodox/skyrim-dev/artifacts/windows-build/20260824-223001 \
  --dry-run
```

The ordinary-finger manual-test batches are a separate registered set:

```bash
skyrim-agent deploy hoarfrost \
  --environment assos \
  --target development \
  --set ordinary-finger-manual-tests \
  --dry-run
```

Repeat `--set` to plan both sets in one transaction. Dry-run is the default even if
`--dry-run` is omitted. Actual copying additionally requires `--apply` and an
available constrained Windows deployment bridge.

## Guarantees

- Project, environment, target, set, artifact ID, source, and destination-relative
  path must all be registered; unknown or ambiguous values are refused.
- Repository files must resolve beneath the authoritative project repository.
- Native DLL/PDB files must resolve beneath the registered build-evidence root, be
  listed in `artifacts.sha256`, match that manifest and protected hash pins, and have
  a valid `source.sha256` matching the registered source-archive hash plus a passing
  native `build.log`.
- The protected bridge allowlist pins each source hash; before copying, the bridge
  reports that source hash and pins the existing destination hash against races.
- Replaced files are backed up when practical; copies are hash-verified afterward.
- Dry-run may read current hashes through `windows-ro`, but neither dry-run nor apply
  ever uses that read-only evidence mount as a write path.

The bridge is not a shell. It cannot mutate load order, enable/disable mods, launch
Skyrim, modify saves, or change game/runtime configuration. Those operations are not
implied by deployment authorization; load-order mutation would require a separate
future capability.

The ASSOS forced-command transport completed its owner-run live SSH smoke on
2026-08-26 against toolkit commit `40024575b1c93eb49cfdd9df44b20daacf5be14e`.
That proof made the registered `project-deploy` capability available; it did not
perform or authorize any candidate deployment.

See `bridges/windows/project-deploy/README.md` for the Windows trust boundary and
registry-derived allowlist.
