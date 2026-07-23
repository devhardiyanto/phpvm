# phpvm — PHP Version Manager

Install and switch PHP versions on **Windows** (CMD + PowerShell) and **Linux** (bash/zsh), without admin rights.

---

## Installation

### Windows

```powershell
irm https://raw.githubusercontent.com/devhardiyanto/phpvm/main/windows/install.ps1 | iex
```

Restart your terminal. No admin required.

Or, if you would rather read the script before running it:

```powershell
# Download both files (phpvm.ps1 + install.ps1) to the same folder, then:
.\install.ps1
```

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/devhardiyanto/phpvm/main/linux/install.sh | bash
source ~/.bashrc
```

Or manually:

```bash
git clone https://github.com/devhardiyanto/phpvm.git ~/.phpvm-src
source ~/.phpvm-src/linux/phpvm.sh
```

---

## Uninstall

Removes `~/.phpvm` and the phpvm entry from your shell config (PATH on Windows,
the `# phpvm` source block on Linux). It does **not** touch anything else.

### Windows

```powershell
.\uninstall.ps1                 # removes everything (asks to confirm)
.\uninstall.ps1 -KeepVersions   # keep built PHP versions
.\uninstall.ps1 -Yes            # no prompt
```

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/devhardiyanto/phpvm/main/linux/uninstall.sh | bash -s -- --yes
# or, from a clone:
bash linux/uninstall.sh                 # removes everything (asks to confirm)
bash linux/uninstall.sh --keep-versions # keep built PHP versions
```

By default the uninstaller removes all built PHP versions too; pass
`--keep-versions` / `-KeepVersions` to retain them. The `phpvm` function stays
loaded in the current shell until you restart it.

---

## Usage

### Version Management

```bash
phpvm install 8.3.0        # install a specific PHP version
phpvm install 8.3          # install latest 8.3.x patch (auto-resolves)
phpvm install 8            # install latest 8.x patch (e.g. 8.5.x)
phpvm install 7.4          # works for older lines (7.x, 5.x)
phpvm install 8.4.16 --no-use   # install but keep the current version active
phpvm use 8.3.0            # switch active version
phpvm list                 # list installed versions
phpvm current              # show active version
phpvm uninstall 8.1.29     # remove a version
phpvm which                # path to active php binary
phpvm ini                  # open php.ini in editor
```

A successful `phpvm install` activates the new version automatically — pass
`--no-use` to skip. Long installs show live progress (download bar on Windows,
build spinner on Linux), suppressed when output is not a terminal.

### CA bundle (Windows)

Windows PHP builds ship without a CA bundle, so HTTPS from PHP fails with
`cURL error 60`. phpvm downloads the [Mozilla CA bundle](https://curl.se/docs/caextract.html)
once to `~/.phpvm/cacert.pem` and wires every installed version to it (details
under Troubleshooting). Linux is unaffected — source builds use the distro's
cert store.

```powershell
phpvm cacert               # show bundle status (path + age)
phpvm cacert update        # refresh the bundle from curl.se
phpvm install 8.3 --no-cacert   # opt out if you manage your own bundle
```

### Diagnostics

`phpvm doctor` runs a read-only health check and points at the command that
fixes each finding — it never changes anything.

```bash
phpvm doctor
```

Checks: active version, whether `php` on PATH resolves to phpvm (catches
XAMPP/Laragon/WAMP shadowing), `extension_dir` vs the active build, and —
per OS — the CA bundle + VC++ runtime (Windows) or openssl + build toolchain
(Linux). Start here when something behaves unexpectedly.

### Auto-Switch with `.phpvmrc`

Drop a `.phpvmrc` file in your project root containing the PHP version you want:

```bash
echo "8.3" > .phpvmrc
phpvm auto                 # one-shot switch from anywhere in the project
```

`phpvm auto` walks up to the nearest `.phpvmrc` and prepends that version to the shell `PATH` (session only — your global `phpvm use` is untouched). It accepts a full semver (`8.3.0`), a major.minor (`8.3` — picks the highest installed patch), or a leading `v` (`v8.3.0`); lines starting with `#` are comments. If the version is not installed locally, phpvm warns but never auto-installs.

For hands-off switching on every directory change, enable the hook:

```bash
phpvm hook enable          # Windows: prompt hook in $PROFILE | Linux: chpwd (zsh) / PROMPT_COMMAND (bash)
phpvm hook status          # check whether the hook is enabled
phpvm hook disable         # remove the hook
```

Restart your terminal after enabling (Linux: or `exec $SHELL`).

### Extension Management

```bash
phpvm ext list             # all bundled extensions (ON/OFF)
phpvm ext loaded           # currently loaded (php -m)
phpvm ext info redis       # details about an extension
phpvm ext enable mbstring  # enable a bundled extension (edits php.ini)
phpvm ext disable pdo_sqlite
phpvm ext install redis    # install from PECL
phpvm ext install mongodb 1.17.0   # specific version
phpvm ext install xdebug   # Windows: from xdebug.org | Linux: via PECL
```

### Laravel quick setup

One command enables the extensions a typical Laravel app needs:

```bash
phpvm ext laravel              # full preset: minimal + intl, gd, opcache, pdo_pgsql, Redis (PECL)
phpvm ext laravel minimal      # required only: openssl, pdo_mysql, mbstring, tokenizer, xml, ctype, fileinfo, bcmath, curl, zip, sodium
phpvm ext laravel full         # explicit full (same as bare `phpvm ext laravel`)
```

Already-loaded extensions are reported as `already ON` and skipped. On Linux, extensions that aren't built into the active PHP are skipped with a `not built into this PHP` note rather than failed.

### Composer

```bash
phpvm composer                 # installs a single global composer that follows the active PHP version
```

Installed **once**: `composer.phar` in `~/.phpvm/` plus a shim in `~/.phpvm/bin/` (on PATH) that runs whatever PHP is active, so `composer` follows `phpvm use` without reinstalling. The installer is verified against `composer.github.io/installer.sig` (SHA-384). Composer 2.x requires PHP ≥ 7.2.5.

### WP-CLI

```bash
phpvm wp-cli                   # installs a single global `wp` command that follows the active PHP version
```

Same global model as Composer: `wp-cli.phar` plus a `wp` shim that follows the active PHP version. The phar is verified against the upstream `wp-cli.phar.sha512` checksum (SHA-512 — not a copy-paste error; WP-CLI publishes SHA-512 where Composer uses SHA-384). WP-CLI requires PHP ≥ 7.2.24.

### Fix `php.ini` extension_dir

```bash
phpvm fix-ini                  # rewrites extension_dir to match PHP's compiled-in path
```

Useful when `extension_dir` was set by a previous install or copied from another machine. On Linux, the value comes from `PHP_EXTENSION_DIR`; on Windows, from `$VERSIONS_DIR\<ver>\ext`.

---

## How It Works

### Windows
- Downloads PHP binaries from [windows.php.net](https://windows.php.net/downloads/releases/)
- Stores versions in `%USERPROFILE%\.phpvm\versions\<version>\`
- Switches via a **directory junction** (`mklink /J`) — no admin needed
- Extensions installed from [windows.php.net PECL](https://windows.php.net/downloads/pecl/releases/)
- XDebug fetched directly from [xdebug.org](https://xdebug.org/files/)

### Linux
- Builds PHP from source ([php.net](https://www.php.net/distributions/))
- Stores versions in `~/.phpvm/versions/<version>/`
- Switches via symlink (`~/.phpvm/current`) prepended to `$PATH`
- Extensions installed via `pecl`, enabled via per-version `conf.d/` drop-ins
- `phpvm composer` / `phpvm fix-ini` / `phpvm ext laravel` work the same as Windows since 1.7.0

---

## Linux: Build Dependencies

Run `phpvm deps` to print the install command for your distro.

**Ubuntu / Debian:**
```bash
sudo apt-get install -y \
  build-essential autoconf bison re2c pkg-config \
  libxml2-dev libsqlite3-dev libssl-dev libcurl4-openssl-dev \
  libonig-dev libzip-dev zlib1g-dev libreadline-dev \
  libpng-dev libjpeg-dev libwebp-dev libfreetype6-dev \
  libgmp-dev libmysqlclient-dev libpq-dev
```

---

## Install Directory Structure

```
~/.phpvm/
├── versions/
│   ├── 8.3.0/         # Windows: php.exe lives here
│   │                  # Linux:   bin/php lives here
│   └── 8.1.29/
├── current -> versions/8.3.0   (junction on Windows, symlink on Linux)
├── cache/             # Linux: cached source tarballs
├── composer.phar      # global Composer (follows the active version)
├── bin/               # on PATH: composer shim (+ phpvm.cmd / phpvm.ps1 on Windows)
├── phpvm.ps1          # Windows: main script
└── phpvm.sh           # Linux: main script (sourced in .bashrc)
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PHPVM_DIR` | `~/.phpvm` | phpvm home directory |
| `EDITOR` | `nano` | Editor used by `phpvm ini` (Linux) |
| `PHPVM_SKIP_HASH` | _unset_ | When set to `1`, skip SHA-256 verification on Windows installs (use for content-rewriting corporate proxies) |
| `PHPVM_NO_UPDATE_CHECK` | _unset_ | When set, skip the daily phpvm update check |

---

## Troubleshooting

### `cURL error 60: SSL certificate problem` (Windows)

Windows PHP builds ship no CA bundle, so HTTPS from PHP (Guzzle, Laravel HTTP
client, API calls) fails TLS verification even though `curl.exe` works fine
(it uses the Windows cert store). phpvm ≥ 1.10.0 configures a shared bundle
automatically on install. For versions installed earlier, run:

```powershell
phpvm fix-ini        # wires curl.cainfo / openssl.cafile to ~/.phpvm/cacert.pem
```

Do **not** work around this with `verify => false` in application code — that
disables TLS verification and tends to leak into production.

### `VCRUNTIME140.dll was not found` / php.exe won't start (Windows)

PHP needs the matching Visual C++ Redistributable (see the matrix below —
vs16/vs17 builds need the 2015–2022 x64 redist). Download:
<https://aka.ms/vs/17/release/vc_redist.x64.exe>

### `php -v` shows the wrong version (Windows)

Another PHP on PATH (XAMPP, Laragon, Herd) is shadowing phpvm. Run
`phpvm doctor` to detect it, or check with
`phpvm which` — if the path isn't `~\.phpvm\current\php.exe`, move
`%USERPROFILE%\.phpvm\current` above the other entry in your User PATH, or
remove the other entry.

### Extensions won't load / `Unable to load dynamic library`

`extension_dir` in php.ini may point somewhere else (typically after copying
an ini from another install). Run `phpvm fix-ini` to re-pin it to the active
version's `ext\` folder, then verify with `phpvm ext list`.

### `running scripts is disabled on this system` (Windows install)

PowerShell's ExecutionPolicy blocks the installer. Allow local scripts for
your user, then re-run:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### `Configure failed` / `Build failed` (Linux)

A dev library is missing. Run `phpvm deps` for the exact install command for
your distro, and check the tail of `~/.phpvm/build.log` for the first error.

### `.phpvmrc` doesn't auto-switch

The shell hook isn't active. Windows: `phpvm hook enable`, then open a new
terminal. Linux: make sure your `~/.bashrc` / `~/.zshrc` sources
`~/.phpvm/phpvm.sh`. Note that auto-switch never installs missing versions —
it only switches between installed ones.

### `ext install sqlsrv` / `pdo_sqlsrv` fails or won't connect

This is **not** a phpvm bug. The PHP extension is only half of the stack — at
runtime it also needs Microsoft's ODBC Driver for SQL Server, installed
system-wide (one-off, outside phpvm). phpvm prints this note after install.

- Windows: [Download the ODBC Driver](https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server)
- Linux/macOS: [Install the ODBC driver](https://learn.microsoft.com/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server)

**Driver 18 vs 17 gotcha:** the PHP extension works with either, but Driver 18
changed the `Encrypt` default from `no` to **`yes`** — so a connection that
worked before now fails TLS against a local/dev SQL Server with a self-signed
certificate. Either add `Encrypt=yes;TrustServerCertificate=yes` (or
`Encrypt=no`) to your connection string, or install Driver 17. Driver 18 also
requires SQL Server 2012+; older servers (2008/R2) need Driver 17.

If the PECL build itself fails, it's a toolchain/driver-header gap on your
machine (`unixODBC-devel` / ODBC SDK), not something phpvm can bundle.

---

## Known limitations

- **PECL extensions on Windows are not hash-verified.** phpvm enforces SHA-256
  on the PHP core zip and the Xdebug DLL, but `windows.php.net` does not publish
  checksums for its [PECL release archives](https://windows.php.net/downloads/pecl/releases/),
  so there is nothing to verify against. Downloads still go over HTTPS. If your
  threat model requires it, build the extension from source instead of pulling
  the prebuilt DLL. (Linux/macOS build extensions via PECL from source, so this
  gap is Windows-only.)
- **macOS is experimental.** Building PHP from source relies on Homebrew deps
  and is exercised only in CI (non-gating). FPM user/group defaults assume
  Linux. See the Compatibility table.

---

## Compatibility

| Platform | Shell | Status |
|---|---|---|
| Windows 10/11 | CMD | ✅ |
| Windows 10/11 | PowerShell 5+ | ✅ |
| Ubuntu 20.04+ | bash / zsh | ✅ |
| Debian 11+ | bash / zsh | ✅ |
| Fedora / RHEL | bash / zsh | ✅ |
| Arch Linux | bash / zsh | ✅ |
| macOS 13+ | bash / zsh | 🧪 experimental — CI-tested only, `brew` deps; FPM defaults assume Linux |

### PHP × compiler toolchain (Windows builds)

Which Visual Studio toolchain each PHP line is built with on windows.php.net,
and therefore which VC++ Redistributable it needs at runtime. phpvm resolves
this automatically; the table is here for debugging download or DLL issues.

| PHP | Toolchain | VC++ Redistributable |
|---|---|---|
| 5.x | vc11 | Visual C++ 2012 |
| 7.0 – 7.1 | vc14 | Visual C++ 2015 |
| 7.2 – 7.4 | vc15 | Visual C++ 2015–2019 |
| 8.0 – 8.3 | vs16 | Visual C++ 2015–2022 |
| 8.4+ | vs17 | Visual C++ 2015–2022 |

Both TS (Thread Safe) and NTS builds are supported; phpvm prefers the TS zip
and falls back to NTS. `phpvm ext install` detects the active build's
TS/NTS + toolchain and downloads matching extension DLLs.

---

## License

MIT
