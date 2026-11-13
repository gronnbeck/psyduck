# Distributing the Mac app

The np.lol distribution, same as tsukue, kurikuri and nagori: Developer ID
signing, notarization, and Sparkle updates, published to the shared nplol
dist bucket. One channel: **edge**. Every push to `main` that touches
`PsyduckMac/` builds a signed, notarized `.app`, publishes it under
`psyduck/edge/`, and updates the appcast so installed copies update themselves.

| Object | Purpose |
|---|---|
| `psyduck/edge/psyduck-<run>.zip` | Immutable, run-numbered. What the appcast advertises. |
| `psyduck/edge/psyduck-edge-latest.zip` | Rolling copy at a URL that never changes. |
| `psyduck/edge/appcast.xml` | The Sparkle feed, EdDSA-signed. |

Download link: <https://nplol-dist.hel1.your-objectstorage.com/psyduck/edge/psyduck-edge-latest.zip>

The edge build is stamped `lol.np.psyduck.edge` / "Psyduck (edge).app", so a
future stable channel installs beside it rather than over it.

## Runner

Unlike the other np.lol apps, the release runs on a **GitHub-hosted** macOS
runner (`macos-26`), not a self-hosted one. This repo is public, and a public
repo must not be able to run jobs on a personal Mac. Secrets load only on
pushes to `main` and manual runs, never on pull requests.

## Secrets

| Asset | Where | Shared? |
|---|---|---|
| Developer ID Application cert | `op://nplol/jidouanki/developer-id-cert-p12-base64` | Yes, issued to the team |
| App Store Connect API key | `op://nplol/app-store-connect/*` | Yes, team-wide, used for notarization |
| Dist bucket credentials | `op://nplol/nplol-dist/*` | Yes, the bucket's own item |
| Sparkle EdDSA key | `op://nplol/psyduck/sparkle-private-key` | **No, psyduck's own** |
| 1Password service account | GitHub secret `OP_SERVICE_ACCOUNT_TOKEN` | Same token as the other repos, set per repo |

The private Sparkle key lives at `op://nplol/psyduck/sparkle-private-key`, and
that copy is the source of truth. Its public half is `SUPublicEDKey` in
`PsyduckMac/project.yml` (`SsuEaOgM+uD8ubm+P+NapxQzxQQ8K5hkrD236qUBhGU=`). The
key under keychain account `psyduck` on the gronnbeck Mac is a different,
unused key from the first setup attempt. Don't export it into 1Password. The
private key is unrecoverable if lost: losing it strands every installed copy
on its current version.

## First release checklist

1. **Sparkle private key → 1Password** (needs `op` signed in):
   ```sh
   cd /tmp && curl -sL https://github.com/sparkle-project/Sparkle/releases/download/2.9.5/Sparkle-2.9.5.tar.xz | tar -xJ bin/generate_keys
   mkdir -p ~/.psyduck-secrets && chmod 700 ~/.psyduck-secrets
   ./bin/generate_keys --account psyduck -x ~/.psyduck-secrets/sparkle-private-key
   eval "$(op signin)"
   op item create --vault nplol --category "API Credential" --title psyduck \
     "sparkle-private-key=$(cat ~/.psyduck-secrets/sparkle-private-key)"
   rm -rf ~/.psyduck-secrets
   ```
2. **The 1Password token**: GitHub secrets don't carry over between repos.
   ```sh
   gh secret set OP_SERVICE_ACCOUNT_TOKEN --repo gronnbeck/psyduck
   ```
3. **Run the release**:
   ```sh
   gh workflow run "Release macOS app (edge)" --repo gronnbeck/psyduck
   gh run watch --repo gronnbeck/psyduck
   ```
