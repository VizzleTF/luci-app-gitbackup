# Research: encrypted backups with locally-readable diffs

Status: research only. Not a spec, not a ticket. No code under `package/`, `applications/`,
`tests/`, `tools/`, `bootstrap.sh` or `.github/` was touched to produce this.

## The question

"Encrypted backups, but with diffs still readable (decrypted) locally." Today the repository
holds every backed-up file as plain text (`docs/adr/0001-no-encryption-visibility-gate.md`), and
both the README and the Overview tab say so explicitly, listing `/etc/shadow`, dropbear host
keys, `authorized_keys`, WPA PSKs, WireGuard private keys, PPPoE credentials and `uhttpd.key` as
what actually ends up there. The only defense today is a hard refusal to push to a repository
that turns out to be public (`gb_visibility_ok`, exit 4) — nothing technical stops a compromised
*private* repository, or its own account, from handing over all of that in the clear.

Encryption is the obvious fix and ADR 0001 already rejected it once, for one specific reason:
*"a router has no secure place to hold a decryption key that isn't itself part of the thing being
backed up, and restore is meant to work from an arbitrary machine at the moment of a
catastrophe."* That reasoning deserves a second, more concrete look rather than a standing
assumption — this document is that look, checked against the actual code and the actual target
image rather than argued from first principles.

## What is available on the target

Measured live: `openwrt/rootfs:x86_64-25.12.4` (matches the `owrt2512` stand, OpenWrt 25.12.4,
`git 2.50.1`, `apk-tools 3.0.5`), both as a bare image and with `gitbackup`'s own dependency set
already installed (`git git-http ca-bundle jsonfilter coreutils-stat openssh-client
openssh-keygen`, i.e. the state a router running this package is actually in).

| package | in 25.12.4 feeds? | installed size | notes |
|---|---|---:|---|
| `libopenssl3` | yes, already a `git` dependency | 6.3 MiB (6451 KiB with git+ssh already in) | **already paid for** — `git`, `git-http` and `openssh-client` all link it |
| `openssl-util` | yes | +925 KiB, +14 KiB `libopenssl-conf` (~939 KiB total, on top of `libopenssl3` already present) | the `openssl` CLI: `enc`, `dgst`, `rand`, ... |
| `gnupg` | yes, but ancient: **1.4.23-r5** | +673 KiB, pulls `terminfo` (36 KiB), `libncurses6` (387 KiB), `libreadline8` (333 KiB) → **+1.4 MiB total** | classic GnuPG 1.4, not GnuPG 2; no modern AEAD ciphers, no `gpg-agent` |
| `gnupg-utils` | yes | +47 KiB on top of `gnupg` (curl/nghttp2 already present via `git-http`) | `gpgsplit`/`gpgv`-adjacent tools, not needed here |
| `age` | **not in the feeds at all** | — | `apk search -e age`/`apk search age` on the live 25.12.4 index returns nothing; confirmed against both the `owrt2512` stand and a fresh throwaway `openwrt/rootfs:x86_64-25.12.4` container. Nobody has packaged it for OpenWrt's own apk feeds. |
| `rage` (Rust `age`) | not in the feeds | — | same check, same result |

So the realistic choice is between `openssl-util` (cheapest, `libopenssl3` is sunk cost already)
and `gnupg` (1.4 MiB heavier, and a 2016-era codebase with no maintained upstream security
posture comparable to OpenSSL's). `age` is not on the table without building and shipping a new
binary through this project's own feed — a meaningfully bigger commitment than adding one
`DEPENDS` line, and its own footprint would need the same `apk info -s` measurement this table
just gave the other three (`VERIFY:` no measurement exists because there is no package to
measure).

**A finding, not a guess:** GnuPG's OpenPGP format cannot produce deterministic ciphertext at
all, checked live rather than assumed. OpenPGP's symmetrically-encrypted data packet always
prepends a random block-sized "quick check" prefix before the plaintext and re-encrypts part of
it (this is what lets a decrypting party detect a wrong key without a MAC) — that prefix is
freshly random on every single invocation, so `gpg --symmetric` on the *same file with the same
passphrase* never produces the same ciphertext twice, even with the deprecated
`--s2k-mode 0` (no-salt key derivation) forced. Confirmed by running it twice against `hello
world\n` with an identical passphrase and identical S2K settings: the two output files differed
from the very first ciphertext byte and had different sizes' worth of unpredictable bytes on the
first line. `openssl enc`, by contrast, with an explicit `-K` (key) and `-iv` (IV) rather than
its own random-salt default, reproduced byte-identical ciphertext across two runs — confirmed the
same way. **This alone rules `gnupg` out for anything that needs determinism (see "change
detection" below), independent of its size.**

## Options

### Option A — do nothing, document the exposure (current state)

**How it works:** unchanged. Plaintext in the repository; the visibility gate is the only
technical control; README/Overview/ADR 0001 carry the warning.

**Cost:** zero — nothing to build, nothing to test, nothing new in `DEPENDS`.

**Leaks:** everything not scrubbed, to anyone who can read the repository.

**Change detection:** unaffected — this is what it already does.

**Both diffs:** unaffected — this is what they already do.

**Reset-router recovery:** unaffected — `bootstrap.sh` already works exactly as documented,
needing only `--token` or `--ssh-key`.

This is the option `docs/COMPARISON.md` already tells prospective users to route around ("if your
environment has a compliance or policy requirement for encryption at rest, this tool cannot
satisfy it... restic or borg is the better-fitting tool"). It is not a placeholder — it is a
considered trade for a project whose whole reason to exist is fitting inside a flash budget a
real dedup+encrypt+prune engine cannot.

### Option B — deterministic symmetric encryption of file content with `openssl enc`

**How it works:** a new module (`crypto.sh`, following every other module's own sourced/no-
side-effects convention) runs after `gb_collect`+`gb_scrub` and before `gb_build_tree`, replacing
every regular file under the run's `$_gb_outdir/files` with its ciphertext, only on the path that
already knows something changed (i.e. *after* the existing manifest-equality short-circuit at
`_gb_run_backup`, `usr/sbin/gitbackup:680-687` — a no-op run never needs to touch a single byte
of the collected set a second time). Symlinks are left alone (their "content" is a path string
staged directly into the tree, `gb_build_tree`'s own `--stdin` hash-object path — encrypting a
symlink target would break its own dangling-target semantics for zero confidentiality benefit,
since a symlink target is rarely secret and `readlink` never dereferences it anyway).

Key material: a single AES-256 key generated once (e.g. `openssl rand 32` at first `gitbackup
keygen`-equivalent time, or a dedicated `gitbackup crypto-init`), stored at
`/etc/gitbackup/encryption_key` (0600, under the existing 0700 directory, and — critically — the
existing hard-exclude in `exclude.list` already keeps everything under `/etc/gitbackup/` out of
the backup set, so this needs no new exclusion rule, only reuse of the one that already exists
for `id_ed25519`/`token`).

**Determinism, and what it costs:** the per-file nonce/IV is derived from the plaintext's own
SHA-256 (already computed by `collect.sh` for the manifest, so this is free to obtain) rather
than from a random source — `openssl enc -aes-256-gcm -K <hex key> -iv <hex, derived from
sha256(plaintext)>`. Two runs of the *same plaintext* then produce byte-identical ciphertext
(measured: confirmed with `openssl enc -aes-256-ctr` and a content-derived IV, two invocations
diff clean). This is deliberately **convergent encryption**, and it leaks exactly what
convergent encryption always leaks: **two files with identical plaintext — the same file
unchanged across runs, the same default config on two different devices sharing this key, a
factory-default file nobody has touched — produce identical ciphertext.** An attacker who holds
the key (or who can just compare ciphertext blobs without it) learns which files are byte-for-
byte identical to which other files or previous versions, across the whole keyspace that shares
this key. It does **not** leak plaintext content to someone without the key, and it does not
suffer from IV-reuse-with-different-plaintext (the one catastrophic failure mode for CTR/GCM),
because the IV only repeats when the plaintext is identical.

**Change detection:** unaffected in the one way that actually matters — `gb_manifest_equal`
(`collect.sh`) already compares `entries[]`/`scrubbed[]` built from the **plaintext** SHA-256
computed at collect time (`_gb_collect_entry_file`, `collect.sh`), before any encryption step
would run. The "no changes, push nothing" shortcut (`usr/sbin/gitbackup:680-687`) exits before
`gb_build_tree` is even reached, so it is decided identically whether or not encryption exists.
What *does* change: on a run where **anything** changed, `gb_build_tree` re-walks and re-hashes
**every** file under the prefix (it always rebuilds the whole tree, `gitio.sh`'s own
`gb_build_tree`), not just the changed ones. With deterministic encryption, an unchanged file's
ciphertext is identical to last time, so `hash-object` produces the same blob SHA and git commits
no new blob for it — the tree entry for that path is literally identical, same as today. Without
determinism, every file — changed or not — would get a fresh ciphertext blob on every push that
touches anything, unbounded repository growth on every device that ever changes even one file.
This is the one property that makes deterministic encryption necessary here, not optional.

**A cost this option cannot avoid even with determinism:** git's own delta compression stops
helping for files that *do* change. A one-line change to `/etc/config/network` today produces a
tiny delta against the previous blob; the AES ciphertext of that same one-line change is a
completely different byte sequence from the previous ciphertext (block-cipher avalanche), so git
stores what is effectively a second full-size blob rather than a small delta. Long-lived,
frequently-changing files (logs kept in the set, DHCP leases, anything with rotating timestamps)
would grow the repository measurably faster than they do today. `VERIFY:` no measurement of this
exists yet — it would need a real fleet-shaped fixture run over many commits to quantify, not
just asserted from how block ciphers work.

**Both diffs:**
- **`config_diff` (Overview)** is *not* a content diff at all — checked directly in
  `usr/sbin/gitbackup`'s `cmd_diff` (no-argument form): it compares `manifest.json` fields
  (path/type/mode/uid/gid/sha256/target) line by line via `_gb_diff_compare`/`_gb_diff_dump`,
  never `git diff` on file content. Since `manifest.json`'s own sha256 fields are already computed
  from plaintext, `config_diff` needs only `manifest.json` itself decrypted after the
  `git cat-file -p $parent:$prefix/manifest.json` fetch (`usr/sbin/gitbackup:669` and the
  equivalent in `cmd_diff`'s zero-arg branch) *if* `manifest.json` itself is also encrypted — one
  small file, one `openssl enc -d` call, not a blob-fetching problem at all. This is the cheap
  half of "both diffs" in the prompt, and conflating it with the other half overstates the work.
- **`gitbackup diff <from> <to>` (History's "View diff")** is the expensive half: it really is
  `git diff --end-of-options <from> <to>` (`cmd_diff`, two-argument form) — a genuine line-level
  text diff of file *content*, rendered by `diffview.unified` in `history.js`. With ciphertext
  blobs, `git diff` would show either "Binary files differ" or a byte-level diff of
  garbage, useless to a human. Two ways to fix it, both real engineering, neither free:
  1. A git `textconv` filter (`.gitattributes` + `diff.<driver>.textconv = decrypt-for-diff`)
     that shells out to decrypt each blob before git diffs it. `git diff` already lazily fetches
     exactly the blobs it needs from a `--filter=blob:none` promisor remote (this is the same
     mechanism `gb_fetch_meta`'s own comments document for `cat-file -p` and `restore.sh`'s
     scoped checkout, and this exact two-sha `git diff` path is already exercised against a real
     local bare repository in `tests/run.sh`, `GB_TEST_GIT_REAL=1` — so the *fetch* half is
     already proven; only the *decrypt-before-diff* half is new). `VERIFY:` textconv's own
     interaction with a promisor remote's lazy fetch has not been checked live — it should work
     (textconv runs after git has the blob content in hand) but this is exactly the kind of claim
     this project's own convention is to verify live before trusting.
  2. Or drop `git diff` entirely for this path and reimplement it as "checkout both commits'
     prefix to two scratch directories (reusing `restore.sh`'s own scoped-checkout trick),
     decrypt both, run `diff -ru`" — more code, but avoids depending on git's textconv machinery
     behaving correctly against a promisor remote at all.

**Reset-router recovery:** this is where the ADR's original objection bites hardest, and
deterministic encryption does not soften it at all — it is orthogonal. Whatever the router had
that let it push encrypted commits (the key at `/etc/gitbackup/encryption_key`) is gone the
instant the router is reset, by the same `/etc/gitbackup/**` hard-exclude that already protects
`id_ed25519` and `token` from ending up inside the very repository they authenticate to. Unlike
losing the SSH deploy key — recoverable by generating a *new* keypair and adding its public half
to the provider, no data lost — **losing the encryption key makes every existing commit
permanently unreadable.** There is no equivalent to "just add a new key" for symmetric backup
decryption; the ciphertext already pushed can never be re-derived from a new key.
`bootstrap.sh --token`/`--ssh-key` already models "the one thing this script cannot get from
anywhere but the operator" for *access* — a third required secret for *decryption* would need the
exact same one-liner ergonomics (`--decrypt-key <...>` or equivalent), and, unlike the access
credential, has genuinely nowhere to be recovered from if the operator does not have it: not the
provider account, not a password reset, nothing. `gitbackup card`'s own header comment states an
explicit, already-shipped invariant: *"Секрета в карточке нет"* / *"Never the secret itself:
neither the token nor the deploy key's private half ever passes through this module."* Putting an
encryption key on that same card — the one plausible place an operator would actually keep it
next to the bootstrap one-liner — directly contradicts a design invariant this project has
already built and, per its own comments, deliberately tested for.

### Option C — GPG symmetric encryption (`gnupg`)

**How it works:** `gpg --batch --passphrase-file ... --symmetric` per file, same insertion point
as Option B.

**Cost:** +1.4 MiB (`gnupg` 673 KiB + `terminfo`/`libncurses6`/`libreadline8` it pulls in that
nothing else on this router needs — `readline`/`ncurses` exist here purely so `gpg`'s own
interactive prompt machinery can link, dead weight for a batch-mode router process that never
uses either).

**Leaks:** in principle the same convergent-encryption leak as Option B, **except it cannot
actually be made deterministic at all** (see "What is available on the target" above — the
random quick-check prefix is unconditional, confirmed live). So in practice Option C is strictly
worse than Option B on every axis: heavier, and it fails the one hard requirement (change
detection / bounded repository growth) that Option B was built to satisfy. There is no
`--deterministic`/no-prefix flag GnuPG 1.4 exposes; the random prefix is how OpenPGP CFB mode's
own integrity check works, not a tunable.

**Change detection:** **broken.** Every file gets new ciphertext on every run regardless of
whether its plaintext changed, so the moment *anything* on the router changes and a push
happens, `gb_build_tree`'s full-tree rewalk gives every single file a brand new blob — unbounded
growth on every push, not just the ones that touch a given file. This is precisely the failure
mode the prompt's ticket 2 warns about, and it is not a corner case for GnuPG — it is the format
working as designed.

**Both diffs / recovery:** same shape as Option B (same textconv-or-reimplement problem, same
key-custody problem), for a worse price. Included here only because the prompt asks specifically
to check it, and it needs to be actually run and measured to rule out, not assumed.

### A fourth shape worth naming and rejecting explicitly: per-file random encryption, accepting the growth

Encrypt with a normal random nonce/salt (whichever tool), accept that every touched file's
ciphertext changes every time it's part of a push, and rely on git's own garbage collection or a
periodic history-squash to bound growth. Rejected outright: this project's own `docs/COMPARISON.md`
already names "Git history is append-only in practice, nobody rewrites it fleet-wide" as one of
the two structural weaknesses this tool already lives with (the other being the shared deploy
key). Adding a design that *requires* periodic history rewriting to stay usable compounds a
weakness the project has already decided not to solve, rather than working within it.

## The hard parts

1. **Change detection vs. nonces.** Solved cleanly by Option B's content-derived IV/nonce,
   *because* the actual "did anything change" decision already lives in `gb_manifest_equal`
   against plaintext SHA-256 computed before any encryption step runs — encryption never has to
   answer that question itself, only avoid corrupting `gb_build_tree`'s per-path blob stability
   for paths that did not change. GnuPG cannot solve it at all (see above); this is a real,
   verified-live tool limitation, not a configuration choice.

2. **Blob fetching for diffs — but only for one of the two diffs.** `config_diff` (Overview)
   needs only `manifest.json` decrypted, a few hundred bytes, cheap. The History two-commit
   `git diff` needs real content, and `--filter=blob:none` already means the blobs are not
   present until something asks for them — proven to lazily arrive today for `cat-file -p` and a
   scoped `checkout`, not separately proven for a textconv-filtered `git diff` against a promisor
   remote. This is the piece with the most engineering and the least prior verification in this
   codebase.

3. **Key custody at recovery time.** Not a corner case, the central problem: the credential
   `bootstrap.sh` already asks for (`--token`/`--ssh-key`) gets you *access* to ciphertext, not
   *plaintext*. A decryption key needs the same "operator brings it, every time, from outside the
   repository" property bootstrap already relies on for the deploy credential — except, unlike a
   deploy credential, it has no recovery path if lost (no equivalent of "generate a new keypair").
   The one place an operator would naturally keep it alongside the bootstrap one-liner — the
   recovery card — is a place this project has already, deliberately, decided never carries a
   secret, both in `card.sh`'s own header comment and in its behavior (`gb_card` never touches
   token/key material). Any encrypted-backup design has to either invent a *new* place for this
   secret to survive a total router loss, or accept that the operator's own external secret
   storage (password manager, printed sheet not generated by this tool) is now a second point of
   failure the recovery flow depends on, above and beyond the git credential it already depends
   on.

4. **What breaks in the existing test suite.** Checked directly, not estimated: at least five
   assertions in `tests/run.sh` (`GB_TEST_GIT_REAL=1` tests around lines 2568, 2574, 2625, 2758,
   2760) push through the real `gb_build_tree`/`gb_commit_push` path against a real local bare
   repository and then `git cat-file -p <commit>:<path>` the pushed blob, asserting its content
   equals the **original plaintext fixture value byte for byte** (e.g. the contents of
   `etc/config/network`, or a symlink's raw target string). Every one of these would need to
   either decrypt the fetched blob before asserting, or gain a parallel "assert it's ciphertext,
   and assert it decrypts back to X" shape — not a small mechanical find-and-replace, because the
   whole point of several of these tests is proving the blob equals what was collected, which
   stops being true the moment encryption sits in between. `restore.sh`'s own sha256 verification
   (`_gb_restore_verify_sha_one`) reads `$_gb_srcfiles$_gb_path` directly off a checked-out tree
   and compares against the manifest's plaintext sha256 — with ciphertext checked out, this needs
   a decrypt-in-place pass inserted between checkout and verification, and every restore test
   that currently checks a restored file's bytes against a known plaintext fixture would newly
   depend on that pass actually running correctly.

## Recommendation

**Stay with Option A — do nothing, keep documenting the exposure as loudly as the Overview tab
and README already do.** Not because Option B is unbuildable — it is buildable, deterministic
AES via `openssl-util` genuinely solves the change-detection problem this prompt worried about,
and `libopenssl3` is already a sunk cost — but because the one problem the original ADR raised is
still unsolved, and it is the one that matters most for a *backup* tool specifically: **a
credential this project needs to keep the operator honest about (git access) is recoverable if
lost; a decryption key for already-pushed backups is not, by construction, ever.** Everything
else in this research (tool cost, determinism, diff mechanics) turned out to be tractable with
enough engineering. Key custody at the moment of catastrophic recovery did not — the one place
this project already built for "bring this back from nothing" (`gitbackup card`) has an explicit,
tested invariant against carrying exactly this kind of secret, and no other credible place for it
exists on a router that has, by definition, just lost everything it had.

**What would change this recommendation:**
- A real, load-bearing decision to accept "no printed/stored recovery key means permanent data
  loss on total router loss" as an equally-documented, equally-loud consequence — the same shape
  ADR 0001 already accepts for "repository goes public leaks everything forever." That is a
  legitimate call for this project's maintainer to make; this document does not make it for them.
- A concrete compliance or user requirement where "no encryption at rest, full stop" is the actual
  adoption blocker (not a hypothetical one) — `docs/COMPARISON.md` already tells such users to use
  restic/borg instead, and that advice is arguably still correct even if this feature ships,
  since restic/borg's key-management story (and their prune/retention story, a separate ADR-
  documented gap) doesn't get any better here.
- OpenWrt's feeds shipping a real `age`-equivalent binary at a measured, competitive size — it
  would remove the "GnuPG can't do it, OpenSSL barely can with hand-rolled deterministic IVs"
  awkwardness, but does not exist today and building/maintaining one is a materially bigger
  commitment than this document was asked to evaluate.

## What it would take (if built anyway)

Ticket-shaped, assuming Option B (deterministic AES-256 via `openssl-util`) and assuming the key-
custody question above has been explicitly decided by the maintainer, not smuggled in as a side
effect of shipping code:

1. **`DEPENDS`, size report, footprint doc.** Add `+openssl-util` to `package/gitbackup/Makefile`
   and `owfeed.yml`; re-run `sh tools/size-report.sh owrt2512`; update `docs/footprint.md`'s
   dependency table with the measured ~939 KiB delta.
2. **New module `usr/share/gitbackup/crypto.sh`.** `gb_encrypt_tree <dir>` /
   `gb_decrypt_tree <dir>` (or per-file variants), content-derived IV from the file's own
   SHA-256, key read from `gitbackup.origin.key_file`-style UCI option (new option, e.g.
   `gitbackup.security.encryption_key_file`, default `/etc/gitbackup/encryption_key`) — same
   "never in argv, never in a log line" discipline `auth.sh`/`askpass.sh` already hold themselves
   to for the token and deploy key.
3. **`gitbackup crypto-init` / extend `keygen`.** Generates the encryption key with the same
   refuse-to-overwrite-without-confirmation shape `gb_keygen` already has for the SSH deploy key
   (`_gb_confirm`/fingerprint dance) — losing this key is worse than losing the SSH key, so the
   safety rail should be at least as strict, arguably stricter (e.g. no `--force` path at all,
   only "delete and start a new encrypted history").
4. **Wire into `_gb_run_backup`.** Insert the encrypt step after the manifest-equality
   short-circuit (`usr/sbin/gitbackup:680-687`) and before `gb_build_tree`
   (`usr/sbin/gitbackup:734`); decide whether `manifest.json` itself is encrypted (recommended:
   yes, it lists real paths on the router) and, if so, decrypt the fetched
   `$GB_PARENT:$prefix/manifest.json` right after the `cat-file -p` at
   `usr/sbin/gitbackup:669` before `gb_manifest_equal` runs.
5. **`restore.sh`: decrypt-in-place pass.** Insert `gb_decrypt_tree` between the scoped
   `checkout` (`restore.sh`, "`_gb_co_err=$(git ... checkout ...)`") and
   `_gb_restore_verify_sha` — sha256 verification must run against plaintext, exactly as it does
   today.
6. **`config_diff`: decrypt one file.** In `cmd_diff`'s zero-argument branch, decrypt the fetched
   old `manifest.json` before `_gb_diff_dump`/`_gb_diff_compare` — the smallest, lowest-risk piece
   of this whole feature.
7. **History two-commit diff: pick and build one of the two designs** in "the hard parts" #2
   above (textconv filter, or checkout-and-`diff -ru` reimplementation) — this is the ticket most
   likely to blow the estimate, and the one that most needs a live-verified spike before
   committing to either shape.
8. **`bootstrap.sh`: a third credential.** New `--decrypt-key`/`--decrypt-key-file` flag,
   mirroring `--token`/`--ssh-key`'s "exactly one of, required, never defaults" shape; written to
   `$GB_BS_SECRET_DIR` the same way the deploy key is; `gitbackup restore` extended to decrypt
   using it. Every place `bootstrap.sh`'s own header comment currently says "the credential this
   script cannot get from anywhere but the operator" doubles — this is the ticket that most needs
   the maintainer's explicit key-custody decision settled *before* it starts, not during it.
9. **`card.sh` / LuCI copy.** Decide, and write down as its own ADR, whether the recovery card
   gains a second "you also need this to read anything back" line pointing at wherever the
   encryption key is meant to live — and if the answer is "the operator's own password manager,
   never this tool's own output," say that explicitly in the card text, not by omission.
10. **LuCI Overview.** Replace the current "the following ends up in the repository in plain
    text" block (`overview.js`, the `gitbackup-leak-list` list) with encryption-aware copy, and
    add wherever the key-custody story lives (a Settings section field, a one-time "encryption
    key" reveal-once screen, or a pointer to the recovery-card change above).
11. **Tests.** Every `GB_TEST_GIT_REAL=1` test that currently asserts a pushed blob's plaintext
    content (`tests/run.sh` around lines 2568/2574/2625/2758/2760) needs a decrypt step added to
    its own assertion, plus new tests for: same-plaintext-across-runs produces identical
    ciphertext (the actual change-detection guarantee this whole design rests on), and a
    restore-from-ciphertext round trip matching today's plaintext round-trip tests.
12. **`tools/size-report.sh` / CI package-size job.** No structural change expected, but its
    output needs re-baselining once `openssl-util` is a real dependency, not merely an optional
    one some configurations pull in.
