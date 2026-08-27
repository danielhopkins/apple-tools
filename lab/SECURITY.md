# 🛑 What this index exposes

**This directory builds a single unencrypted file containing the plaintext of
everything the `apple` tools can read.** That file is not protected the way the
data it came from is protected. Read this before running it on real data.

## What is in the file

Measured on this machine, 2026-08-21:

| Source | Records | Decoded plaintext |
|---|---|---|
| mail | 40,351 | **105.5 MB** |
| messages | 5,924 | 4.0 MB |
| calendar | 11,374 | 1.0 MB |
| notes | 681 | 1.0 MB |
| contacts | 687 | 0.02 MB |
| chunk copies of the above | 239,056 | 69.6 MB |

Every email body, decoded out of MIME and base64. Every message. Every note.
Every contact's company, title and note. Total file size: **~870 MB**.

## 🛑 The index defeats the protection on its own inputs

The stores this reads from are protected two ways:

1. **TCC Full Disk Access**, enforced by the kernel. That is why `apple mail`
   needs a grant and why an ordinary process cannot read `~/Library/Mail`.
2. **Directory modes.** `~/Library/Mail` is `drwx------`.

**The index inherits neither.** It is an ordinary SQLite file. Any process
running as this user can open it and read every email, with no grant, no
prompt, and no record that it happened.

⚠️ **A CLI cannot fix this.** There is no TCC-protected location a non-app
binary can write into, so the kernel-level protection cannot be reproduced.

⚠️ **Revoking Full Disk Access does not disable the index.** A user who removes
the grant expects their mail to stop being readable. The index keeps answering.

### ⚠️ One thing this section does NOT defeat: iCloud encryption of notes

A fair objection to all of the above is "but my notes are encrypted in iCloud,
and this file is not." **On a default account that is not true**, and the
correction is worth having because it changes what this index costs.

`icloud-md` — [`../docs/prior-art.md`](../docs/prior-art.md) — talks to the
CloudKit private database for Notes and reports that it **requires Advanced Data
Protection to be off**, because *"with ADP on, note content is end-to-end
encrypted in a way this tool doesn't attempt to decrypt."* The corollary is the
part that matters here: without ADP, the fields named `TitleEncrypted` and
`TextDataEncrypted` arrive **as plain readable bytes** — compressed, not
client-side encrypted. The name says encrypted; the bytes are not.

- **So indexing note plaintext locally does not remove a protection that iCloud
  was providing**, unless the user has ADP switched on.
- 🛑 **It is still a second copy in a second place**, and every other word in
  this file stands. This narrows the objection; it does not answer it.
- ⚠️ **Not measured here.** It is `icloud-md`'s claim, read from its README. If
  it ever matters, test it rather than cite it.

## What is actually done about it

| Mitigation | State |
|---|---|
| Parent directory `0700` | ✅ enforced on every connect |
| Index file `0600`, including `-wal` and `-shm` | ✅ enforced on every connect |
| `.metadata_never_index` so Spotlight builds no second copy | ✅ written |
| Kept out of the repo working tree | ✅ lives in `~/Library/Application Support/apple-tools/` |
| Explicit opt-in before the first ingest | ✅ `consent` table, `--accept-risk` |
| A revocation path that deletes everything | ✅ `apple-index forget` |
| Refusing to serve after the grant is revoked | ✅ the daemon checks and declines |
| Encryption at rest | ✅ **AES-256, once the app holds the index** — see below |
| Access logging | 🛑 **none** |
| Automatic expiry | 🛑 **none** |

## ⚠️ Three second copies people forget

1. **The query log stores results, snippets included.** `query_log` keeps what
   each search returned so a tester can see what a user saw. Those rows contain
   real message text. This was added for debugging and it is a second store of
   the same content.
2. **The result cache stores the same thing**, keyed by query and settings.
3. **Every backup copies the file.** Time Machine, and any cloud backup. 🛑
   **Deleting the original mail does not remove it from a backup of this
   index.**

## ⚠️ The daemon holds it all in RAM, and answers a socket

`./index.py daemon start` runs a resident process holding **525 MB**: the
embedding model, and the plaintext-derived vectors for all 239,056 chunks. It
stays hot for as long as it runs.

The socket is protected by four independent barriers, verified 2026-08-21:

```
drwxr-x---   /Users/dhopkins
drwx------   /Users/dhopkins/Library
drwx------   /Users/dhopkins/Library/Application Support
drwx------   /Users/dhopkins/Library/Application Support/apple-tools
srw-------   .../apple-tools/index.sock
```

Another user is stopped at `~/Library`, two directories before the socket. They
cannot traverse it, so they cannot name the socket at all.

**macOS enforces the socket mode on connect, and that was measured, not
assumed**, because the behaviour varies between systems:

```
mode 0600, as the owner   ->  CONNECTED
mode 0000, as the owner   ->  DENIED: [Errno 13] Permission denied
```

Setting the mode to `000` denied the owner, so the bits are real.

🛑 **It is NEVER a TCP port.** A port would put the whole mail corpus one bad
bind address away from the network.

⚠️ **The socket is not a new hole. It is a second door into the one that
already exists.** Anything that can connect can already open the index file
directly. What the daemon adds is that everything stays hot in RAM all day,
which the file alone does not.

What it does not protect against, in order of how likely it is:

1. **Any process running as you.** A script, an app you installed, or an agent.
   It connects, asks, and reads every result. No prompt, no record.
2. **root.** Permission checks do not apply.
3. **A memory read of the daemon process.**

Stop it with `./index.py daemon stop`.

## Removing it

```
./index.py purge --yes          # delete the index, the log and the cache
./index.py purge --logs-only    # keep the index, drop query_log + result_cache
```

`purge` is the closest thing to a revocation. Use it before handing the machine
to anyone, and after any test run on real data.

## Before this ever ships — where the three blockers stand

1. **A `--forget` path.** ✅ **Done.** `apple-index forget` deletes the index,
   the write-ahead log, the socket, the daemon log and the `consent` row, and
   stops the daemon first. Revocation is now noticed rather than ignored:
   `search` and `status` warn when Full Disk Access is gone and the index is
   still there, and the daemon **refuses to serve** at that point.
   ⚠️ **It cannot reach a backup.** Time Machine holds copies it will never see.

2. **An explicit opt-in.** ✅ **Done, and this document was wrong about it.**
   The `consent` table, the prompt and `--accept-risk` have existed for some
   time; this file went on listing the work as outstanding. A stale security
   document is its own defect.

3. **A decision on encryption at rest.** ✅ **Done, 2026-08-23, and NOT the way
   this section predicted.** The index now lives in an **AES-256 encrypted APFS
   disk image**, created and mounted by `app/AppleTools.app`, with the key in
   the Keychain. Both readers see an ordinary SQLite file on a mounted volume,
   so neither `index.py` nor `vec` changed at all.

   **The reasoning below was right about SQLCipher and wrong about the
   conclusion.** SQLCipher is genuinely unreachable: Python's stdlib `sqlite3`
   cannot open one, and giving it one means a compiled extension. A disk image
   sidesteps that entirely.

   🛑 **Be precise about what it buys, because "encrypted" will be read as more
   than this is.**

   | | |
   |---|---|
   | a Time Machine or cloud backup | copies **ciphertext** |
   | a stolen or discarded disk | gives up **nothing** |
   | deleting the key | makes 812 MB of decoded mail **inert** — real revocation |
   | **while the app runs** | the volume is **mounted and readable** by anything running as you |

   That last row is the same exposure the plaintext file always had, now
   limited to the time the app is open rather than forever. **It is an
   improvement and it is not a solution.**

   ⚠️ **One prediction here was measured and is wrong.** This section said "a
   key in the login keychain is readable by anything running as the user".
   Measured: `security find-generic-password` from a terminal **blocked on an
   authorization prompt** and returned nothing. The item is bound to the app
   that created it, so another process needs the user to approve it.

   ⚠️ **The FTS5 point still stands and is why the whole file is encrypted**
   rather than the body column. An FTS5 index leaks its own terms.

## The honest summary

This lab makes searching your own data much better and makes stealing it much
easier. Those are the same change. Nothing here is safe to ship without the
three items above.
