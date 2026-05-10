# phpvm — PHP Version Manager

Install and switch PHP versions on **Windows** (CMD + PowerShell) and **Linux** (bash/zsh), without admin rights.

---

## Installation

### Windows

```powershell
# Download both files (phpvm.ps1 + install.ps1) to the same folder, then:
.\install.ps1
```

Restart your terminal. No admin required.

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/phpvm/main/linux/install.sh | bash
source ~/.bashrc
```

Or manually:

```bash
git clone https://github.com/YOUR_USERNAME/phpvm.git ~/.phpvm-src
source ~/.phpvm-src/linux/phpvm.sh
```

---

## Usage

### Version Management

```bash
phpvm install 8.3.0        # install a PHP version
phpvm install 8.1.29       # install another version
phpvm use 8.3.0            # switch active version
phpvm use 8.1.29           # switch to another
phpvm list                 # list installed versions
phpvm current              # show active version
phpvm uninstall 8.1.29     # remove a version
phpvm which                # path to active php binary
phpvm ini                  # open php.ini in editor
```

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
│   └── install.ps1        # installer
├── linux/
│   ├── phpvm.sh           # main script (sourced in .bashrc)
│   └── install.sh         # curl installer
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
├── bin/               # Windows: phpvm.cmd + phpvm.ps1 shim
├── phpvm.ps1          # Windows: main script
└── phpvm.sh           # Linux: main script (sourced in .bashrc)
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PHPVM_DIR` | `~/.phpvm` | phpvm home directory |
| `EDITOR` | `nano` | Editor used by `phpvm ini` (Linux) |

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
