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

A successful `phpvm install` automatically activates the freshly installed
version, so you can skip a separate `phpvm use` for the common case. Pass
`--no-use` to install a version in the background without switching to it.

Long installs report live progress: a download bar on Windows, and a spinner
with elapsed time over the `configure` / `make` / `make install` steps on Linux.
Both are drawn on stderr and are suppressed automatically when output is not a
terminal, so piping and CI logs stay clean.

### CA bundle (Windows)

Windows PHP builds ship without a CA bundle, so out of the box every HTTPS
request from PHP fails with `cURL error 60`. On install, phpvm downloads the
[Mozilla CA bundle](https://curl.se/docs/caextract.html) once to
`~/.phpvm/cacert.pem` and points the new version's `curl.cainfo` and
`openssl.cafile` at it. The bundle is shared, so switching PHP versions never
loses the fix.

```powershell
phpvm cacert               # show bundle status (path + age)
phpvm cacert update        # refresh the bundle from curl.se
phpvm install 8.3 --no-cacert   # opt out if you manage your own bundle
phpvm fix-ini              # re-apply to an existing install
```

If the download fails (offline install), phpvm warns and continues — run
`phpvm cacert update` later. Linux is unaffected: source builds use the
distro's system certificate store.

### Auto-Switch with `.phpvmrc` (Windows)

Drop a `.phpvmrc` file in your project root containing the PHP version you want:

```bash
echo "8.3" > .phpvmrc
```

Then run `phpvm auto` from anywhere in the project — phpvm walks up to find the nearest `.phpvmrc` and prepends that version to your shell `PATH` (session only, your global `phpvm use` is untouched).

For hands-off switching, install the PowerShell prompt hook:

```powershell
phpvm hook install      # adds a snippet to $PROFILE
# restart PowerShell, then `cd` between projects - phpvm auto-switches per directory
phpvm hook status       # check whether the hook is installed
phpvm hook uninstall    # remove the hook
```

`.phpvmrc` accepts a full semver (`8.3.0`), a major.minor (`8.3` — picks the highest installed patch), or a leading `v` (`v8.3.0`). Lines starting with `#` are comments. If the version is not installed locally, phpvm warns but never auto-installs.

### Auto-Switch with `.phpvmrc` (Linux)

Same `.phpvmrc` file works on Linux — the format is identical.

```bash
echo "8.3" > .phpvmrc
phpvm auto          # one-shot switch from the current directory
```

For automatic switching on every `cd`, enable the shell hook:

```bash
phpvm hook enable       # writes $PHPVM_DIR/.auto-hook flag
exec $SHELL             # or restart your terminal
```

phpvm registers the hook in the shell it detects:

| Shell | Mechanism |
|---|---|
| zsh | `add-zsh-hook chpwd _phpvm_auto` — runs on every directory change |
| bash | `PROMPT_COMMAND="_phpvm_auto -s; ..."` — runs before every prompt |

Manage with `phpvm hook status` / `phpvm hook disable`. Because `phpvm.sh` is already sourced into your shell rc, there is no separate file edit step — the hook activates the next time the shell loads.

### Extension Management

```bash
# List / inspect
phpvm ext list             # all bundled extensions (ON/OFF)
phpvm ext loaded           # currently loaded (php -m)
phpvm ext info redis       # details about an extension

# Enable/disable bundled extensions (edit php.ini)
phpvm ext enable  mbstring
phpvm ext enable  pdo_mysql
phpvm ext enable  curl
phpvm ext enable  zip
phpvm ext disable pdo_sqlite

# Install PECL extensions
phpvm ext install redis
phpvm ext install imagick
phpvm ext install mongodb
phpvm ext install mongodb 1.17.0   # specific version

# XDebug (Windows: from xdebug.org | Linux: via PECL)
phpvm ext install xdebug
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

The installer signature is verified against `composer.github.io/installer.sig` (SHA-384) before execution. Composer is installed **once** — `composer.phar` in `~/.phpvm/` and a shim in `~/.phpvm/bin/` (on PATH) that runs whatever PHP is active. Switch versions with `phpvm use <other>` and the same `composer` keeps working; no need to re-run `phpvm composer`. (Composer 2.x requires PHP ≥ 7.2.5, so an extremely old active version won't run the latest composer.)

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

## Repository Structure

```
phpvm/
├── windows/
│   ├── phpvm.ps1          # main script
│   ├── install.ps1        # installer
│   └── uninstall.ps1      # uninstaller
├── linux/
│   ├── phpvm.sh           # main script (sourced in .bashrc)
│   ├── install.sh         # curl installer
│   └── uninstall.sh       # curl uninstaller
└── README.md
```

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
| `PHPVM_AUTO_ACTIVE` | _unset_ | Internal: tracks the version currently pinned by `phpvm auto` in the current shell |

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

---

## License

MIT
