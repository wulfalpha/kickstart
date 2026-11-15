# Kickstart

Open files using your own extension rules, without changing system file associations.
Commands launch directly as argument arrays; no shell is inserted.

Requires Zig 0.15.2. Build with `zig build -Doptimize=ReleaseSafe`; test with
`zig build test`. Run CLI integration checks on Linux/macOS with
`python3 tests/test_cli.py zig-out/bin/kickstart`. The executable is installed to `zig-out/bin/kickstart`.

```sh
kickstart document.pdf
kickstart --program 'code --wait' notes.txt
kickstart --with edit document.pdf
kickstart --config ./my-openers.rc --dry-run image.png
kickstart --terminal current notes.txt
kickstart --batch one.txt two.txt
kickstart -- -filename.txt
```

`--program` accepts a command with arguments and bypasses the default config.
Use `--config` alongside it if you need custom terminal settings. It conflicts
with `--with`, which selects a named action in your config.

## macOS 27 with Zig 0.15.2

On this combination, `zig build` can fail while linking Zig's own build runner
with undefined symbols such as `_abort` and `_getenv`, before compiling
Kickstart. Setting `-Dtarget` does not change the build runner's native target.
Use the direct compiler workaround:

```sh
./scripts/build-macos.sh
./scripts/build-macos.sh test
python3 tests/test_cli.py zig-out/bin/kickstart
```

The script bypasses the build runner, targets macOS 13 or later, and builds
`zig-out/bin/kickstart` in ReleaseSafe mode. It does not modify your Zig
installation, SDK, or shell configuration. Plain `zig build` remains affected
by the host toolchain issue.

## Configuration

On Linux/macOS, an explicitly set, absolute `XDG_CONFIG_HOME` takes precedence:
`$XDG_CONFIG_HOME/kickstart/kickstartrc`. An empty or relative value is ignored.
Without that override, Linux uses `~/.config/kickstart/kickstartrc`.

On macOS, Kickstart first checks
`~/Library/Application Support/kickstart/kickstartrc`, then an existing
`~/.config/kickstart/kickstartrc`. If neither exists, it creates the sample in
Application Support. Existing configs are never moved or merged. If both files
exist, Application Support wins; use `--config` to select either explicitly.
An explicit XDG location is authoritative even when its config is missing.

On Windows it lives at `%LOCALAPPDATA%\kickstart\kickstartrc`, with a fallback
to `%USERPROFILE%\AppData\Local`. `--config PATH` overrides discovery and accepts
relative paths. No config is loaded from the current directory automatically.

Config discovery follows one policy: `--config` wins, then an explicit absolute
XDG override on Unix, then the platform default, then any supported legacy file.
Only a missing preferred file permits legacy fallback; errors reading or parsing
it never select another config. Windows retains LocalAppData as its default.

```sh
kickstart --show-config-path
kickstart --gen-config
kickstart --config ./openers.rc --gen-config
```

`--show-config-path` prints the path selected for reading to stdout, without
creating anything or parsing the config. `--gen-config` creates the sample in
the preferred location (or `--config` override), recursively creating parents.
On macOS, generation targets Application Support even when an existing
`~/.config` file is used for reading. This makes migration explicit: after
generation, Application Support takes precedence; the old file is untouched.
Generation refuses to overwrite any existing file, including symlinks, and uses
mode 0600 on POSIX. Edit the sample to choose your apps; generation does not
launch anything or require those apps to be installed. Config operations
(`--gen-config`, `--show-config-path`, `--check-config`) are mutually exclusive
and reject file arguments and launch options. `--config`, `--verbose`, and
`--help` are allowed with them.

When the default config is missing, Kickstart creates a sample and exits
successfully with instructions to edit it. Explicitly selected missing configs
are errors. Sample creation never overwrites an existing file. The sample uses
example apps; replace them with programs installed on your machine.

```ini
# Full-line comments only. Arguments after '=' are literal, not shell code.
txt=code --wait
pdf=evince
tar.gz=file-roller
default=code

# Named actions; --with edit selects these, falling back to default:edit.
pdf:edit=inkscape
default:edit=code

# Exact basename rules (case-sensitive), including dotfiles.
name:.bashrc=nvim
name:Makefile:edit=nvim

termPrograms=nvim, vim, nano, less
myTerm=kitty --title Kickstart
myArg=-e
```

Extension rules are case-insensitive. Longest compound suffix wins (`tar.gz`
before `gz`). A leading dot alone is not an extension: `.pdf` uses the default
unless configured with `name:.pdf`. Exact basename rules precede extension rules.
A bare argument such as `py` is a filename, not an extension selector.
Duplicate rules and malformed lines fail with line numbers. Configs are limited
to 1 MiB. A named action never silently falls back to the ordinary default.

Single or double quotes group arguments; empty quoted arguments are preserved.
Outside single quotes, backslash escapes quotes, backslash, and unquoted
whitespace. Other backslashes are preserved, so quoted Windows paths work.
Use single quotes for paths with literal repeated backslashes, including UNC
paths. Unclosed quotes and trailing escape backslashes are errors. There is no
variable expansion, tilde expansion, inline comment syntax, pipe, or redirection.
Use absolute executable paths or names discoverable through PATH.

## Launch behavior

`--terminal auto` opens recognized terminal programs in a new terminal.
`current` inherits the existing terminal; `new` always wraps the command in a
terminal; `gui` launches directly. Current and gui construct identical commands
but communicate your intended mode. For Yazi/Ranger, use current with the file
manager's blocking/wait option for interactive editors. Auto recognizes absolute
paths to terminal programs too. Configure myTerm/myArg for custom terminals;
otherwise Kickstart checks Alacritty, Kitty, Ghostty, WezTerm, GNOME Terminal,
and xterm. Missing terminals produce an error. Windows new-terminal mode needs
a configured terminal, for example `myTerm=wt` and `myArg=new-tab --`.

Multiple files launch separately by default. `--batch` launches one process with
all files, and requires every file to select the same command. Launches wait
for their child; a GUI application may itself detach. Kickstart returns the last
nonzero child exit code, or 1 for abnormal termination. All commands are prepared
before any child starts.

`--dry-run` (alias `--explain`) prints the config, matching rules, and JSON argv,
with control characters escaped. It resolves executables but launches nothing.
`-v` or `KICKSTART_VERBOSE=1` shows the same details during real launches.
`--check-config` checks every configured executable without opening files.
Ordinary launches only resolve the selected commands and required terminal.

## Security boundaries

Config files specify executable commands: only use configs you trust. File
extensions choose a program; they do not verify the contents or make opening an
untrusted document safe. Files are passed as absolute paths to prevent filename
prefixes from being interpreted as options. Add `--` in a rule if the target
application supports an option terminator; it is not inserted universally.

Executable lookup skips empty and relative PATH entries and launches the resolved
absolute executable. Writable absolute PATH directories still require trust.
Windows automatically discovers `.exe` and `.com`; `.bat`/`.cmd` require an
explicit shell command configured by the user. Filenames are never interpolated
into shell code. Avoid shell commands that reinterpret their arguments as code.

The sample config is created exclusively with mode 0600 on POSIX. Existing config
permissions and symlinks are not changed. Do not run Kickstart with elevated
privileges or use it as a sandbox. Programs inherit the environment and working
directory, so their own project/plugin loading rules still apply.
