# oo7-nixos: A WM-Agnostic Secret Service Stack for NixOS

> Replace `gnome-keyring` + `gcr` with a minimal, fully Rust-native secret
> service stack orchestrated declaratively on NixOS. No GNOME dependency.
> Works on any window manager.

---

## Motivation

The current state of secret management on non-GNOME Linux desktops is fragile:

- `gnome-keyring` works but drags in GNOME session assumptions
- `gcr-ssh-agent` (the replacement for gnome-keyring's SSH component since v46)
  [routinely breaks on non-GNOME setups](https://github.com/nixos/nixpkgs/issues/420193)
  — `SSH_AUTH_SOCK` not set, socket not started, etc.
- `kwallet`/`ksecretd` is KDE-specific
- Every existing solution is tightly coupled to a desktop framework

The `oo7` project (`linux-credentials/oo7`) is building the right primitives:
a pure-Rust Secret Service implementation with `oo7-daemon`, `oo7-pam`, and
`oo7-portal`. But the SSH agent piece — the direct replacement for
`gcr-ssh-agent` — does not exist yet.

This project has two parts:

1. **`oo7-ssh-agent`** — a new standalone Rust daemon: a bridge between
   `org.freedesktop.secrets` (via the `oo7` client library) and the SSH agent
   protocol. Provider-agnostic: works with `oo7-daemon`, `gnome-keyring`,
   `KeePassXC`, or any compliant Secret Service.

2. **`oo7-nixos`** — a NixOS flake that wires together `oo7-daemon`,
   `oo7-pam`, `oo7-portal`, and `oo7-ssh-agent` into a coherent, fully
   declarative replacement for the `gnome-keyring` + `gcr` workflow.

---

## End Goal

After applying the NixOS module, a user on Sway (or any WM) gets:

```
Login (greetd / any PAM-aware greeter)
  └─ pam_oo7.so unlocks the collection synchronously
       └─ oo7-daemon starts (DBus-activated, systemd user service)
            ├─ org.freedesktop.secrets  ← all apps, browsers, git-credential
            ├─ org.freedesktop.portal.Secret ← sandboxed/Flatpak apps
            └─ oo7-ssh-agent  ← SSH keys served from the keyring
                 └─ SSH_AUTH_SOCK set via systemd user environment
```

Zero GNOME dependencies. No manual configuration. `nixos-rebuild switch` and
it works.

---

## Part 1: `oo7-ssh-agent`

### What it is

A small Rust daemon that:
- Speaks the SSH agent protocol over a Unix socket (`SSH_AUTH_SOCK`)
- Stores and retrieves SSH private keys from `org.freedesktop.secrets` via the
  `oo7` client library
- Handles `ssh-add`, `ssh-add -l`, `ssh-add -d`, and signing requests
- Is provider-agnostic — works with any Secret Service daemon

### What it is NOT

- Not a full SSH agent with its own key store
- Not a passphrase cacher (keys are fetched from the keyring on every sign
  request — the keyring is the single source of truth)
- Not tied to oo7-daemon specifically

### Crate Dependencies

```toml
[dependencies]
oo7             = { version = "0.6", features = ["tokio"] }
ssh-agent-lib   = "0.5"    # SSH agent protocol server
ssh-key         = { version = "0.6", features = ["ed25519", "p256", "rsa"] }
zeroize         = { version = "1", features = ["derive"] }
tokio           = { version = "1", features = ["full"] }
tracing         = "0.1"
tracing-subscriber = "0.3"
clap            = { version = "4", features = ["derive"] }
```

> **Review note — verify `ssh-agent-lib` version:** The `ssh-agent-lib` crate
> has had significant API changes between versions. v0.5 may not exist yet.
> The `Agent` trait shape (async vs sync, exact method signatures) varies
> between releases. Pin to a specific published version early and verify the
> trait matches the implementation sketch below. This is the highest-risk
> dependency — prototype `agent.rs` first.

### Secret Service Storage Schema

SSH keys are stored as Secret Service items with the following attribute
convention (compatible with how KeePassXC stores SSH keys, for
interoperability):

```
label      = "SSH key: <comment>"
secret     = <raw OpenSSH private key bytes (PEM or binary)>
attributes = {
    "xdg:schema"    : "org.freedesktop.Secret.Generic",
    "type"          : "ssh-key",
    "comment"       : "<key comment, e.g. user@host>",
    "fingerprint"   : "SHA256:<base64>",   // for fast lookup during signing
    "algorithm"     : "ed25519" | "ecdsa-p256" | "rsa",
}
```

The `fingerprint` attribute is the critical lookup key: when OpenSSH sends a
`SIGN_REQUEST`, it provides the public key. We compute the fingerprint locally
and use it to find the right secret in the keyring without loading all keys.

> **Review note — duplicate fingerprint edge case:** If the user imports the
> same key twice with different comments, the fingerprint matches both items.
> `SIGN_REQUEST` takes `.next()` which is fine, but `REMOVE_IDENTITY` should
> remove **all** matches (or document the behavior). Consider enforcing
> uniqueness on the fingerprint attribute at `ADD_IDENTITY` time (the
> `replace: true` flag in the sketch handles this).

### SSH Agent Protocol — Handler Map

| Message | Handler |
|---|---|
| `SSH_AGENTC_REQUEST_IDENTITIES` | List all items with `type=ssh-key`, return public keys |
| `SSH_AGENTC_SIGN_REQUEST` | Compute fingerprint of requested pubkey → fetch secret → sign → zeroize |
| `SSH_AGENTC_ADD_IDENTITY` | Store new key into Secret Service with schema above |
| `SSH_AGENTC_REMOVE_IDENTITY` | Delete item matching fingerprint |
| `SSH_AGENTC_REMOVE_ALL_IDENTITIES` | Delete all `type=ssh-key` items |
| `SSH_AGENTC_ADD_ID_CONSTRAINED` | Return `SSH_AGENT_FAILURE` (v2 — see review note) |
| `SSH_AGENTC_LOCK` | Call `keyring.lock()` on the collection |
| `SSH_AGENTC_UNLOCK` | Call `keyring.unlock()` (triggers pinentry via oo7-daemon) |
| `SSH_AGENTC_EXTENSION` | Return `SSH_AGENT_FAILURE` (not implemented) |

> **Review note — constrained identities:** OpenSSH supports constrained key
> addition (`ssh-add -t lifetime` for time-limited keys, `-c` for
> confirm-on-use). These use `SSH_AGENTC_ADD_ID_CONSTRAINED`. Returning
> `SSH_AGENT_FAILURE` is correct for MVP, but document this — some users rely
> on `-c` for interactive confirmation before signing.

### Critical Security Requirements

**Memory safety — zeroize on drop**

Private key material must never linger in heap memory. Every type holding key
bytes must implement `ZeroizeOnDrop`. The `ssh-key` crate supports this via its
`ZeroizeOnDrop` feature.

```rust
use zeroize::ZeroizeOnDrop;

#[derive(ZeroizeOnDrop)]
struct KeyMaterial(Vec<u8>);
```

The secret returned from `oo7` must also be zeroized immediately after use.
Do not clone key bytes. Pass references where possible.

> **Review note — zeroize on error paths:** The `from_openssh` call likely
> allocates internally. If it returns `Err`, `secret_bytes` is still alive and
> needs zeroizing. Wrap secret bytes in `Zeroizing<Vec<u8>>` from the `zeroize`
> crate so it auto-zeroizes on drop regardless of code path:
>
> ```rust
> let secret_bytes = Zeroizing::new(item.secret().await?);
> let privkey = SshPrivateKey::from_openssh(&secret_bytes)?;
> // secret_bytes zeroizes on drop even if from_openssh fails
> ```
>
> Do NOT rely on manual `.zeroize()` calls on the happy path — every early
> return or `?` is a potential leak.

**No key caching**

Unlike `ssh-agent`, this bridge does NOT hold decrypted private keys in memory
between requests. Every `SIGN_REQUEST` fetches from the keyring and zeroizes
immediately after use. This is slightly slower but means the attack surface is
minimized: an attacker who can read process memory only sees the key during the
~microseconds of a sign operation.

> **Review note — raw key trust model:** Users with passphrase-protected keys
> in `~/.ssh/` will need to enter the passphrase during import (via
> `ssh-add`), and the key is then stored *unencrypted* in the keyring
> (encrypted at rest by the collection's encryption, but decrypted once the
> collection is unlocked). This is the same trust model as `ssh-agent` holding
> keys in memory, just persisted. Document this clearly so users understand
> they're trading file-level encryption for keyring-level encryption.

**Socket peer credential check**

On every new connection to the Unix socket, verify the peer UID via
`SO_PEERCRED`. Reject connections from any UID other than the current user.

```rust
use std::os::unix::net::UnixListener;

fn check_peer_cred(stream: &tokio::net::UnixStream) -> Result<()> {
    let cred = stream.peer_cred()?;
    let current_uid = unsafe { libc::getuid() };
    if cred.uid() != current_uid {
        return Err(anyhow!("rejected connection from uid {}", cred.uid()));
    }
    Ok(())
}
```

**Socket permissions**

Create the socket with mode `0o600`. Use `std::os::unix::fs::PermissionsExt`.

> **Review note — socket activation changes socket creation:** With systemd
> socket activation, **systemd creates the socket, not the binary**. The
> `socket.rs` module for socket creation + permissions is only needed for the
> non-socket-activated path (manual `--socket` invocation). Under socket
> activation, the fd is received via `LISTEN_FDS` / `SD_LISTEN_FDS_START`.
> The `listenfd` or `sd-notify` crate handles this. The binary should detect
> both modes: if `LISTEN_FDS` is set, use the inherited fd; otherwise, create
> the socket itself. This affects the `socket.rs` design significantly.

**Locked collection handling**

If the collection is locked when a `SIGN_REQUEST` arrives:
1. Call `keyring.unlock().await` — this triggers the prompt configured in
   `oo7-daemon` (pinentry or portal)
2. If unlock succeeds, proceed with signing
3. If unlock fails or times out, return `SSH_AGENT_FAILURE`

Do not hang indefinitely. Set a reasonable timeout (e.g. 30s) on the unlock
call.

### High-Level Code Structure

```
oo7-ssh-agent/
├── Cargo.toml
├── src/
│   ├── main.rs          # clap CLI, socket setup, tokio runtime
│   ├── agent.rs         # implements ssh_agent_lib::Agent trait
│   ├── keyring.rs       # oo7 client wrapper: list/get/add/remove keys
│   ├── keys.rs          # ssh-key parsing, fingerprint computation, signing
│   ├── socket.rs        # Unix socket creation, peer cred check, permissions
│   └── error.rs         # unified error type
└── tests/
    ├── integration.rs   # start agent, connect with ssh-agent-lib client
    └── keyring_mock.rs  # mock Secret Service for unit tests
```

### `agent.rs` — Core Logic Sketch

```rust
use ssh_agent_lib::agent::Agent;
use ssh_agent_lib::proto::{Identity, SignRequest, Signature};

pub struct Oo7Agent {
    keyring: Arc<Mutex<oo7::Keyring>>,
}

impl Agent for Oo7Agent {
    async fn identities(&self) -> Result<Vec<Identity>> {
        let kr = self.keyring.lock().await;
        let items = kr.search_items(&[("type", "ssh-key")]).await?;
        items.iter()
            .filter_map(|item| parse_public_key_from_item(item).ok())
            .collect()
    }

    async fn sign(&self, request: SignRequest) -> Result<Signature> {
        let fingerprint = compute_fingerprint(&request.pubkey);
        let kr = self.keyring.lock().await;

        // Unlock if needed — triggers pinentry
        kr.unlock().await?;

        let items = kr.search_items(&[
            ("type", "ssh-key"),
            ("fingerprint", &fingerprint),
        ]).await?;

        let item = items.into_iter().next()
            .ok_or_else(|| AgentError::KeyNotFound)?;

        // Use Zeroizing wrapper for automatic cleanup on all code paths
        let secret_bytes = Zeroizing::new(item.secret().await?);
        let privkey = SshPrivateKey::from_openssh(&secret_bytes)?;
        let signature = privkey.sign(&request.data, request.flags)?;

        Ok(signature)
    }

    async fn add_identity(&self, key: AddIdentity) -> Result<()> {
        let pubkey = key.privkey.public_key();
        let fingerprint = compute_fingerprint(&pubkey.to_bytes()?);
        let comment = key.comment.clone();

        self.keyring.lock().await
            .create_item(
                &format!("SSH key: {comment}"),
                &[
                    ("type",        "ssh-key"),
                    ("comment",     &comment),
                    ("fingerprint", &fingerprint),
                    ("algorithm",   pubkey.algorithm().as_str()),
                ],
                &key.privkey.to_openssh(LineEnding::LF)?,
                true, // replace if exists
            ).await?;
        Ok(())
    }
}
```

> **Review note — `Mutex<oo7::Keyring>` concurrency bottleneck:** The
> `Arc<Mutex<_>>` wrapper serializes all SSH operations — if two `git push`
> commands run concurrently, one blocks during the entire Secret Service
> roundtrip + signing. Options:
>
> 1. If `oo7::Keyring` is `Clone`, use one per request.
> 2. If not, use `Arc<RwLock<_>>` — most operations are reads.
> 3. Check if `oo7::Keyring` is internally thread-safe (many D-Bus client
>    wrappers are). If so, `Arc<Keyring>` alone suffices with no lock.
>
> Investigate during Milestone 1 prototyping.

### CLI Interface

```
oo7-ssh-agent [OPTIONS]

OPTIONS:
    --socket <PATH>     Socket path [default: $XDG_RUNTIME_DIR/oo7-ssh-agent.sock]
    --collection <NAME> Secret Service collection [default: login]
    --timeout <SECS>    Unlock prompt timeout [default: 30]
    -v, --verbose       Enable tracing output
```

### Systemd User Service

The daemon is socket-activated — it starts on first connection and idles
without consuming resources.

```ini
# oo7-ssh-agent.socket
[Unit]
Description=oo7 SSH Agent Socket

[Socket]
ListenStream=%t/oo7-ssh-agent.sock
SocketMode=0600

[Install]
WantedBy=sockets.target
```

```ini
# oo7-ssh-agent.service
[Unit]
Description=oo7 SSH Agent
Requires=oo7-daemon.service
After=oo7-daemon.service

[Service]
ExecStart=/path/to/oo7-ssh-agent
Environment=RUST_LOG=warn
```

---

## Part 2: `oo7-nixos` — The NixOS Flake

### Flake Inputs

```nix
inputs = {
  nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
  oo7.url         = "github:linux-credentials/oo7";   # if/when they provide a flake
  oo7-ssh-agent.url = "github:<you>/oo7-ssh-agent";
};
```

### NixOS Module Interface

```nix
services.oo7 = {
  enable = true;

  # Which PAM services to add autounlock to
  # (login handled automatically; add screen lockers here)
  pamServices = [ "swaylock" "hyprlock" ];

  sshAgent = {
    enable   = true;
    # Socket path — defaults to $XDG_RUNTIME_DIR/oo7-ssh-agent.sock
    # Overrideable for users who want a stable path
    socket   = null;  # null = use default
    # Import existing ~/.ssh/id_* keys on first run
    scanSshDir = false;
  };

  portal = {
    enable = true;  # sets up oo7-portal + portals.conf for xdg-desktop-portal
  };

  pinentry = "gtk";  # "gtk" | "qt" | "curses" | "tty" | "gnome3"

  # Automatically disable gnome-keyring to prevent conflicts
  disableGnomeKeyring = true;
};
```

> **Review note — additional module options:**
>
> - **`scanSshDir`**: boolean to enable a oneshot service that imports
>   existing `~/.ssh/id_*` keys into the keyring on first run.
> - **`disableGnomeKeyring`**: automatically sets
>   `services.gnome.gnome-keyring.enable = false` and
>   `programs.seahorse.enable = false` (with `mkForce`) to prevent conflicts.
> - **Assertions**: add NixOS assertions to catch conflicts, e.g.:
>   `assert !config.services.gnome.gnome-keyring.enable` when
>   `services.oo7.enable` is true.

### What the Module Wires Up

**Packages:**
- `oo7-daemon` binary + DBus activation file
- `oo7-pam` PAM module (`.so`)
- `oo7-portal` binary + `.portal` file for xdg-desktop-portal
- `oo7-ssh-agent` binary

**PAM configuration (`security.pam.services.<name>`):**
```nix
security.pam.services.login = {
  text = lib.mkAfter ''
    auth    optional ${pkgs.oo7-pam}/lib/security/pam_oo7.so
    session optional ${pkgs.oo7-pam}/lib/security/pam_oo7.so
  '';
};
```

The `session` line is critical — it runs after the user session is established
and blocks until the collection is confirmed unlocked, preventing the race
condition where systemd user services start before the keyring is ready.

> **Review note — PAM ordering: use `mkOrder`, not `mkAfter`:**
> `mkAfter` is fragile because multiple modules can all claim `mkAfter` and
> the relative ordering between them is undefined. Use `mkOrder` with an
> explicit numeric priority (e.g., `mkOrder 12000`) verified to come after
> `pam_systemd.so` (typically at `mkOrder 10000`). This is more robust and
> auditable.

**Systemd user services:**
```nix
systemd.user.services.oo7-daemon = {
  description   = "oo7 Secret Service daemon";
  after         = [ "graphical-session.target" ];
  serviceConfig = {
    ExecStart = "${pkgs.oo7-daemon}/bin/oo7-daemon";
    Restart   = "on-failure";
  };
};

systemd.user.sockets.oo7-ssh-agent = {
  description   = "oo7 SSH Agent socket";
  listenStreams  = [ "%t/oo7-ssh-agent.sock" ];
  socketConfig.SocketMode = "0600";
  wantedBy      = [ "sockets.target" ];
};

systemd.user.services.oo7-ssh-agent = {
  description = "oo7 SSH Agent";
  after       = [ "oo7-daemon.service" ];
  requires    = [ "oo7-daemon.service" ];
  serviceConfig.ExecStart = "${pkgs.oo7-ssh-agent}/bin/oo7-ssh-agent";
};
```

**DBus activation:**
```nix
services.dbus.packages = [ pkgs.oo7-daemon ];
```

**SSH_AUTH_SOCK environment:**
```nix
environment.sessionVariables.SSH_AUTH_SOCK =
  "/run/user/%U/oo7-ssh-agent.sock";

# Also set via systemd user environment for services
systemd.user.sessionVariables.SSH_AUTH_SOCK =
  "%t/oo7-ssh-agent.sock";
```

> **Review note — `environment.sessionVariables` vs `systemd.user.sessionVariables`:**
> `environment.sessionVariables` writes to `/etc/profile` equivalents — it's
> shell-dependent and only applies to login shells. For Sway launched via
> `greetd`, this usually works. But `systemd.user.sessionVariables` uses the
> `%t` specifier which works in unit files but NOT in `sessionVariables`. The
> path will need to be expanded, likely to `"/run/user/%U/oo7-ssh-agent.sock"`
> or set via `pam_env` or `environment.d`. Test both paths on a real system.

**xdg-desktop-portal config (for Sway):**
```nix
xdg.portal.config.sway = {
  default          = [ "wlr" "gtk" ];
  "org.freedesktop.impl.portal.Secret" = [ "oo7-portal" ];
};
```

### The Race Condition Solution

The classical race condition:
1. User logs in → PAM stack runs
2. `pam_oo7.so` in `auth` phase tries to unlock → `oo7-daemon` not running yet
3. Unlock fails silently → collection stays locked
4. User session starts → apps can't get secrets

The fix is in PAM phase ordering. The `session` module (not `auth`) is the
right hook because it runs after the user's systemd session manager starts.
Specifically:

- `pam_systemd.so` in the `session` phase starts `systemd --user`
- Our `pam_oo7.so` in the `session` phase runs *after* `pam_systemd.so`
- At this point DBus is available and `oo7-daemon` can be activated
- `pam_oo7.so` sends the login password to `oo7-daemon`, which unlocks the
  collection, and returns success only after unlock is confirmed
- Only then does the greeter hand off to the user session

This is exactly how `pam_gnome_keyring.so` works and why gnome-keyring doesn't
have this race condition — we replicate the same model.

In NixOS the ordering is enforced via `lib.mkOrder` on the PAM configuration to
ensure our module appears after `pam_systemd.so`.

---

## Milestones

### Milestone 1 — `oo7-ssh-agent` MVP

**Goal:** `ssh-add`, `ssh-add -l`, and `git push` over SSH work against a
running `gnome-keyring` or `oo7-daemon`.

- [ ] Project scaffold: `cargo new oo7-ssh-agent --bin`
- [ ] Verify `ssh-agent-lib` and `oo7` crate versions and trait shapes
- [ ] `keyring.rs`: connect to Secret Service, list/search/create/delete items
- [ ] `keys.rs`: parse ed25519 + ecdsa keys, compute fingerprints, sign
- [ ] `agent.rs`: implement `REQUEST_IDENTITIES` and `SIGN_REQUEST`
- [ ] `socket.rs`: Unix socket with peer cred check + `0o600` permissions
      (also: detect `LISTEN_FDS` for socket-activated mode)
- [ ] `main.rs`: CLI with `--socket`, basic logging
- [ ] Manual test against `gnome-keyring` on NixOS

### Milestone 2 — Full Protocol + Security Hardening

- [ ] `ADD_IDENTITY` (ssh-add compat)
- [ ] `REMOVE_IDENTITY` / `REMOVE_ALL_IDENTITIES`
- [ ] `ADD_ID_CONSTRAINED`: return `SSH_AGENT_FAILURE` with clear error log
- [ ] `LOCK` / `UNLOCK`
- [ ] Zeroize audit: every code path touching key material reviewed
      (use `Zeroizing<T>` wrapper, not manual `.zeroize()` calls)
- [ ] Unlock-on-demand with timeout
- [ ] RSA support (for legacy keys)
- [ ] Investigate `oo7::Keyring` thread safety — remove `Mutex` if possible
- [ ] Integration tests with mock Secret Service

### Milestone 3 — Systemd Integration

- [ ] Socket activation (`oo7-ssh-agent.socket` + `.service`)
- [ ] Dual-mode socket: inherit fd via `LISTEN_FDS` or create via `--socket`
- [ ] Idle timeout: exit after N seconds of inactivity (socket re-activates)
- [ ] `SSH_AUTH_SOCK` export via systemd user environment
- [ ] Document: idle timeout + re-activation may trigger unlock prompt after
      screen lock

### Milestone 4 — NixOS Flake

- [ ] Package `oo7-ssh-agent` in Nix
- [ ] NixOS module: systemd units, PAM, DBus, environment variable
- [ ] PAM ordering with `mkOrder` (not `mkAfter`), verified after `pam_systemd.so`
- [ ] PAM ordering tested with `greetd` + `tuigreet`
- [ ] PAM ordering tested with screen lock (`swaylock`)
- [ ] `xdg.portal` wiring for `oo7-portal`
- [ ] `programs.ssh.extraConfig` to suppress "too many keys" agent behavior
- [ ] Assertion: conflict with `services.gnome.gnome-keyring.enable`
- [ ] `disableGnomeKeyring` option
- [ ] Verify `SSH_AUTH_SOCK` propagation in both shell and systemd contexts

### Milestone 5 — Upstream Conversation

- [ ] Open issue on `linux-credentials/oo7` with design doc and link to repo
- [ ] Evaluate whether `oo7-ssh-agent` should be proposed as a crate in the
  `oo7` workspace
- [ ] If upstreaming: align attribute schema with any conventions oo7-daemon
  developers want

---

## Open Questions

**Q: Should private key bytes live in the keyring, or just the passphrase?**

Storing the raw private key in the keyring (the approach described here) means
the key file on disk can be removed entirely — the keyring is the only copy.
Storing only the passphrase requires the encrypted key file to remain on disk,
which is the `gcr-ssh-agent` approach. The raw-key approach is cleaner but
requires users to explicitly import keys via `ssh-add` rather than relying on
`~/.ssh/` autodiscovery. This is probably the right trade-off for a system
where the keyring IS the key store.

Optionally, a `--scan-ssh-dir` flag on first run could import existing
`~/.ssh/id_*` keys into the keyring and optionally remove the originals.

> **Review note:** This means passphrase-protected keys are stored
> *unencrypted* in the keyring secret field (protected by the collection's
> encryption at rest, decrypted when unlocked). This is the same trust model
> as `ssh-agent` — just persisted. Document clearly.

**Q: What attribute schema to use for interoperability with KeePassXC?**

KeePassXC stores SSH keys differently (as attachments, not in the secret
field). If interoperability with KeePassXC's SSH agent feature is desired,
the schema and handler for `REQUEST_IDENTITIES` would need to understand both
formats. This is a v2 concern — start with a clean schema and document it.

**Q: How to handle the unlock prompt in a headless/SSH session?**

If `SSH_AUTH_SOCK` is forwarded to a remote machine and a sign request comes
in while the collection is locked, the unlock prompt (pinentry) would need to
appear on the local machine, not the remote. This is a known hard problem with
all keyring-backed SSH agents. For now: return `SSH_AGENT_FAILURE` in headless
contexts rather than hanging. Document this limitation clearly.

**Q: FIDO2 / hardware key support?**

Out of scope for the initial implementation. FIDO2 keys are better handled by
`gpg-agent --enable-ssh-support` with the key on hardware. The bridge is for
software keys stored in the keyring.

**Q: Idle timeout and re-activation behavior?**

When the agent exits after idle timeout and systemd reactivates it on the next
connection, it must reconnect to the Secret Service. If the collection was
locked in the meantime (e.g., screen lock), the next SSH operation triggers
an unlock prompt. This is correct but may surprise users. Document this
interaction and consider whether the agent should log a warning when it
detects a locked collection on startup.

---

## Non-Goals

- This project does not replace Bitwarden or any password manager UI
- This project does not provide a GUI for managing secrets (use Seahorse or a
  future `oo7`-based UI for that)
- This project does not solve GPG/certificate management (that remains `gcr`'s
  responsibility via `gcr-pkcs11` — a separate concern)
- This project does not target non-NixOS distributions (though the
  `oo7-ssh-agent` binary itself is distro-agnostic)

---

## Prior Art and References

- [`linux-credentials/oo7`](https://github.com/linux-credentials/oo7) — the
  Secret Service library and daemons this project builds on
- [`wiktor-k/ssh-agent-lib`](https://github.com/wiktor-k/ssh-agent-lib) — SSH
  agent protocol implementation used by the bridge
- [`RustCrypto/ssh-key`](https://github.com/RustCrypto/SSH/tree/master/ssh-key)
  — SSH key parsing and signing
- [`gcr`](https://gitlab.gnome.org/GNOME/gcr) — the current `gcr-ssh-agent`
  implementation this replaces, written in C/GLib
- [All Systems Go! 2024 talk on `oo7-daemon`](https://cfp.all-systems-go.io/all-systems-go-2024/talk/8TMT9T/)
- [All Systems Go! 2025 followup](https://cfp.all-systems-go.io/all-systems-go-2025/talk/NFNFJS/)
- [NixOS issue: `gcr-ssh-agent` not working on Hyprland](https://github.com/nixos/nixpkgs/issues/420193)
