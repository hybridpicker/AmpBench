# The sound store

The sound store keeps every sound of a device (the presets folder) encrypted in a place you choose, and brings the
sounds of your other devices to this one. It is a backup and a sync in one: a Mac and an iPad with the same key hold
the same sounds. How to use it is in the [manual](MANUAL.md#the-sound-store); this document says how it works, what
the place sees, and how to run a place of your own.

## What goes where

- **Encrypted on the device.** Every file is encrypted before it leaves, with the [age](https://age-encryption.org)
  format (X25519, ChaCha20-Poly1305). The place only ever gets ciphertext.
- **The key** is an age identity (`AGE-SECRET-KEY-1…`), made on the device and kept in the system keychain, never in
  a file, a setting or the repository. "Show key" in the app and `--store-key show` print it, so you can put it in
  your password manager and enter it on your other devices. Without the key nobody can read the store, you included.
- **The place** is one of:
  - a **folder**: any folder, also one a cloud drive keeps in step (iCloud Drive, Google Drive, Dropbox, a network
    share). On the iPad the folder comes from the Files dialog, so every provider that shows up in Files works.
  - a **server over SSH** (Mac only): the Mac's own `ssh` with your keys and `~/.ssh/config`. AmpBench stores no login.
  - an **HTTPS address**: any server that takes `GET` and `PUT` below one address, such as a WebDAV folder
    (Nextcloud) or your own web server. The password is kept in the keychain.
- **Settings** (which kind of place, its path or address, a user name) are in the app's preferences on that device.
  They hold no secret and are not part of the repository either.

## What the place holds

```
manifest.age                 the index: every sound's path, its object, date and size, and what was removed
objects/<64 hex digits>.age  one sound each
```

Both are age files. An object's name is an HMAC of its content under a key derived from the store key, so the same
sound is stored once and a name says nothing about it. Whoever runs the place sees how many objects there are, how
large they are and when they changed. They do not see names, tags, notes or settings.

Objects are never deleted. A sound that was overwritten or removed stays in the store, and the manifest remembers
the last ten earlier versions of each path.

## Syncing

A sync compares three things: the folder, the manifest, and what was in step after this device's last sync.

| Since the last sync | Result |
|---|---|
| changed or new here only | stored |
| changed or new in the store only | fetched |
| changed on both sides, the same content | nothing |
| changed on both sides, differently | the newer one wins; the other stays in the store as an earlier version |
| removed here, unchanged in the store | marked removed in the store (the object stays) |
| removed in the store, unchanged here | removed here: to the Trash on the Mac, to the hidden `.Trash` in the presets folder on the iPad |
| removed on one side, changed on the other | the change wins |

A wrong key, a damaged index or a damaged object stops the sync before anything changes, here or in the store. Paths
from the index are checked before a file is written, so a tampered store cannot write outside the presets folder.
Files over 8 MB and hidden files are left out. Recordings are not part of the store.

The app syncs at its start, when it comes to the front (at most every five minutes), about 15 seconds after sounds
changed, and with the key "Sync". The index is read, merged and written without a lock: two devices that sync in the
same second can lose one index update, which the next sync repairs. Objects are never lost that way.

## Without the app

The store is readable with the standard `age` tool, so it does not depend on AmpBench:

```bash
age -d -i key.txt manifest.age                       # the index, as JSON
age -d -i key.txt objects/<name>.age > "Lead.json"   # one sound; the index says which object is which
```

`key.txt` holds the key as "Show key" prints it. Keep that file out of any folder that is synced or published, and
delete it afterwards.

## From the command line (Mac)

```bash
AmpBench --store-setup folder ~/Drive/AmpBench-Store   # or: ssh <host> <folder>   or: https <url> [user]
AmpBench --store-key new        # makes the key; prints only its public half
AmpBench --store-key set        # takes a key from standard input
AmpBench --store-key show       # prints the key
AmpBench --store-sync           # both ways; exit status 1 when it failed
AmpBench --store-status
```

`AmpBench` is the app's own program, `/Applications/AmpBench.app/Contents/MacOS/AmpBench`. With an HTTPS place and a
user name, `--store-setup` reads the password from standard input, never from an argument.

## A place of your own

**Over SSH** nothing needs to be installed: the folder is created on the first sync. The server needs `tar`.

**Over HTTPS**, for devices without SSH such as the iPad, a web server that stores what is PUT is enough. With nginx
(`ngx_http_dav_module`, part of the standard build):

```nginx
location /ampbench-store/ {
    alias /srv/ampbench-store/;              # owned by the nginx user
    auth_basic "AmpBench store";
    auth_basic_user_file /etc/nginx/ampbench-store.htpasswd;
    dav_methods PUT;
    create_full_put_path on;
    client_max_body_size 16m;
    limit_except GET PUT { deny all; }
}
```

The app refuses an address that is not `https://` (except on the same machine, for tests). An SSH place and an HTTPS
place can be the same folder on the server, so the Mac and the iPad meet there.

## Open

- Linux has no sound store yet. Its presets folder can be kept in step by hand with `age` as above.
- Earlier versions and removed sounds stay in the store but the app has no view to bring one back.
- No lock on the index (see Syncing).
- The nginx example above is written from nginx's documentation and was not run; the HTTPS place was checked
  against a small local test server (GET, PUT, MKCOL, Basic auth).
- On the iPad the store has run in the simulator only; a folder from a cloud provider in Files and a real HTTPS
  server were not tried from a real iPad.
