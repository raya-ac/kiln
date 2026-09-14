# host evidence

CURRENT ARCHITECTURE: PostgreSQL via psycopg3. SQLite observations below describe
the stopped, never-public prototype and are retained as history, not deployment
instructions. At hold, counts were0accounts/0sessions/0usageevents/1health-rate-row;
backup hash `ab7d347626652a2af96e00289d8168388768880a89a90630ba1381d7addd32cf`.
Kiln was stopped/disabled and staged domain moved out of domains-direct before
any reload. Layerline diff returned no activation changes, originalPID1688792.

Existing host PostgreSQL is16.15 with localallusers peer auth and loopback TCP
SCRAM. No Kiln database/role previously existed. Dedicated rolekiln-account was
then created as LOGIN/NOSUPERUSER/NOCREATEDB/NOCREATEROLE/NOREPLICATION, temporarily
24connections for isolated tests. Only test databasekiln_account_test_20260914
was provisioned at this stage; OSuserkiln-account peer-auth identity verified.
Existing host autovacuum=on, archive_mode=off, max_wal_size1024MiB,
wal_keep_size0, no replication slots,108Gfree. No global PostgreSQL settings changed.

Observed 2026-09-14 over normal SSH to `root@46.250.246.198`, with batch mode,
strict existing host-key checking, and host-key updates disabled. Secrets were
not printed. Only the explicitly approved random HTTP-01 proof and scoped
certificate issuance departed from read-only inspection; application activation
still requires final command-plan approval.

- Ubuntu 24.04.4 LTS, Python 3.12.3. 11,960 MiB RAM, ~9,435 MiB available;
  root filesystem 193G, 110G available. These are a snapshot, not reservations.
- `127.0.0.1:27480` was free. Layerline owns public80/443. Existing adjacent
  applications listen27280/27390. No Kiln service/domain/release directory existed.
- Active command `/opt/layerline/layerline --config /opt/layerline/layerline-direct.conf`.
  Domain directory `/opt/layerline/domains-direct`. Do not introduce Caddy.
- Active binary and retained `/opt/layerline/releases/28aae4d/layerline` both
  SHA256 `53a779d09de12e8eaa4801194693b89cd0194a11586b7f75719b1460ba698597`.
- `kiln.raya.ac` resolves to Cloudflare104.21.30.189/172.67.173.137. Initial HTTPS
  GET returned200 and a generic Layerline native-H2 page, not Kiln.
- Existing raya.ac certificate is self-issued CN=raya.ac, no SAN,
  2026-06-12..2027-06-12; `openssl x509 -checkhost kiln.raya.ac` explicitly failed.
  SHA256 fingerprint `C2:2C:60:FA:7D:A6:65:86:92:CE:7C:BB:75:FB:6C:49:82:75:B0:7D:A9:FC:8A:72:B5:6E:A6:A4:3D:AB:72:22`.
  Although existing raya.ac/music domain files use it, it must NOT be reused for
  Kiln authentication. Existing private key contents were not read or printed.

## exact Layerline semantics

Retained source is `/opt/layerline/releases/28aae4d/source/src/`.
`app.zig:176` reloadConfigInMemory loads main+domain configs, normalizes/validates,
checks listener compatibility, loads TLS material, then activates an owned
configuration for new connections. Adding a domain and its certificate is
compatible; changing listen/admin sockets is not. No file watcher is assumed.

`admin_runtime.zig:791` accepts `reload` on `/run/layerline-admin.sock`, replies
`OK config reloaded` or an error without activation. `validate` and `diff` are
read-only. A live `status` command succeeded, TLS true, admin true, admin_ui false,
tls_auto false, acme_renew false. Use `tools/layerline_admin.py`, not
`systemctl reload layerline`: the systemd ExecReload validates then sends TERM
and relies on Restart=always. That would restart the shared frontend.

`upstream_runtime.zig:308..329`, `http2_upstream.zig:54..70` copy supplied
forwarding headers. `proxy_utils.zig:39` does NOT remove X-Forwarded-For or
CF-Connecting-IP. No trusted ingress identity is established. The backend
ignores those headers and retains conservative shared peer budgets. Do not
enable header trust merely because the TCP peer is loopback.

## existing ACME path

Certbot2.9.0 at `/usr/bin/certbot`, standard installed webroot/standalone/manual
plugins; no certbot DNS plugin directory observed. Existing Let's Encrypt
production account directory exists; account key was not read. Renewal configs
for existing domains consistently use authenticator=webroot,
webroot_path=/opt/layerline/public. No credential-file paths were referenced.
Global cli.ini sets only max-log-backups and preconfigured-renewal.

Main config `letsencrypt_webroot=/opt/layerline/public`.
`http1_router.zig:136` and `http2_router.zig:150` serve ACME challenges before
domain proxy fallback; HTTP runtime also handles the path before redirect.
Random scoped proof through public HTTP returned the exact body using curl and
was unlinked in finally with absence verified. First Python urllib request
received403 and its proof was also removed; no edge security settings changed.

The global `/etc/letsencrypt/renewal-hooks/deploy/reload-layerline.sh` performs a
shared restart. Approved issuance uses `--no-directory-hooks`; do not invoke
broad renewal. New hostname renewal must retain scoped config and use the
in-memory reload path, with its lifecycle checked during deployment review.

## scoped certificate issued

Approved `certbot certonly` succeeded using existing account/webroot and no
directory hooks. SAN is exactlyDNS:kiln.raya.ac, issuer Let's EncryptYE1,
valid2026-09-14T05:10:26Z..2026-12-13T05:10:25Z. OpenSSL hostname verification
and trust-chain verification both passed. DER SHA256 fingerprint
`27:50:3A:07:A6:01:1B:7A:F5:12:AA:75:3A:0B:53:BD:8A:29:51:CB:D0:73:3E:9C:CF:82:07:FE:AA:48:BB:4F`.
PEM cert SHA256 `2dd3c3d3a0394925aeac85f1dcd1539149b737a264629184741b6f37f878238a`;
fullchain SHA256 `346a76c0b9fd62f5f7d63bcfb282df6df1cbb50762c94c65f8cadb4094155f91`.
Paths `/etc/letsencrypt/live/kiln.raya.ac/{cert,fullchain,chain}.pem`.
No key contents printed. Layerline PID1688792 stayed unchanged, active sinceSep5.

FOLLOW-UP: Certbot did NOT persist `directory_hooks=false` in the new renewal
configuration. A future global scheduled renew therefore still invokes the
existing shared-restart hook. No global hook/config was edited. A separately
reviewed hostname-specific renewal lifecycle must solve that before expiry;
current issuance does not establish restart-free automatic renewal.
