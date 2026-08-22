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

## What is actually done about it

| Mitigation | State |
|---|---|
| Parent directory `0700` | ✅ enforced on every connect |
| Index file `0600`, including `-wal` and `-shm` | ✅ enforced on every connect |
| `.metadata_never_index` so Spotlight builds no second copy | ✅ written |
| Kept out of the repo working tree | ✅ lives in `~/Library/Application Support/apple-tools/` |
| Encryption at rest | 🛑 **none** |
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

## 🛑 Before this ever ships

Three things are not optional for a released version:

1. **A `--forget` path that actually runs**, wired to the same moment a user
   revokes Full Disk Access. Right now nothing connects those.
2. **A decision on encryption at rest.** SQLCipher is the obvious route. Note
   that an FTS5 index leaks its own terms, so encrypting only the body column
   is not enough.
3. **An explicit opt-in.** A tool that silently aggregates every protected store
   into one unprotected file is not something a user should get by accident.

## The honest summary

This lab makes searching your own data much better and makes stealing it much
easier. Those are the same change. Nothing here is safe to ship without the
three items above.
