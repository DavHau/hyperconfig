# SSH over dumbpipe (iroh) — NixOS Setup

Two NixOS modules that let you SSH into a server behind NAT, using
dumbpipe to tunnel the connection over iroh's QUIC network.

No IPFS daemon. No Kubo. No port forwarding on your router.
Works through firewalls, symmetric NATs, and even networks that
block UDP entirely (falls back to WebSocket relay on port 443).

## Architecture

```
┌──────────────┐         iroh (QUIC / relay)       ┌──────────────┐
│    CLIENT     │◄────────────────────────────────►│    SERVER     │
│              │                                   │              │
│  ssh -p 2222 │                                   │  sshd :22    │
│  user@local  │                                   │  (localhost)  │
│       │      │                                   │       ▲      │
│       ▼      │                                   │       │      │
│  dumbpipe    │ ══ encrypted QUIC stream ════════ │  dumbpipe    │
│  connect-tcp │                                   │  listen-tcp  │
│  :2222       │                                   │  → :22       │
└──────────────┘                                   └──────────────┘
```

## Setup

### Server

1. Generate a secret key (one-time):

   ```bash
   nix-shell -p dumbpipe --run "dumbpipe listen"
   ```

   Output:
   ```
   using secret key e72235535d87a3e166df70a60062c189f1e4854d2140e9c67bcbf6558d62021b
   Listening. To connect, use:
   dumbpipe connect endpoint...
   ```

   Ctrl+C. Save the hex key.

2. Store the secret on the server:

   ```bash
   echo "IROH_SECRET=e72235535d..." > /etc/dumbpipe-ssh.secret
   chmod 600 /etc/dumbpipe-ssh.secret
   ```

   (Or use agenix/sops-nix to manage this declaratively.)

3. Import `server.nix` and rebuild:

   ```bash
   sudo nixos-rebuild switch
   ```

4. Grab the ticket from the journal:

   ```bash
   journalctl -u dumbpipe-ssh -n 20 | grep "dumbpipe connect"
   ```

### Client

1. Store the ticket:

   ```bash
   echo "endpointab2t..." > /etc/dumbpipe-ssh-ticket
   chmod 600 /etc/dumbpipe-ssh-ticket
   ```

2. Import `client.nix` and rebuild:

   ```bash
   sudo nixos-rebuild switch
   ```

3. Connect:

   ```bash
   ssh -p 2222 youruser@127.0.0.1
   ```

## FAQ

**The ticket changes on server restart — is that a problem?**

No. The node ID (derived from your secret key) stays the same. Only
the address hints change. Old tickets keep working because iroh
discovers the current addresses via DNS. You never need to update
the client.

**What if hole-punching fails?**

Traffic falls back to iroh's relay servers over WebSocket (HTTPS
port 443). No time limits, no data caps. Your SSH session keeps
working — just with higher latency.

**What if UDP is blocked entirely?**

Still works. The relay uses plain HTTPS/WebSocket (TCP 443), which
gets through virtually any firewall or corporate proxy.

**Can I use agenix/sops-nix for the secrets?**

Yes. For the server, point `EnvironmentFile` at your decrypted
secret path. For the client, adjust the `cat` in the script to
read from wherever your secrets manager places the ticket file.

**Multiple servers?**

Run one dumbpipe-ssh service per server, each with its own ticket
and a different local port (2222, 2223, etc). Or use ~/.ssh/config
to give them friendly names.
