"""CLI integration checks. Run: python3 tests/test_cli.py /path/to/kickstart"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="kickstart-test-") as tmp:
    root = Path(tmp).resolve()
    env = dict(os.environ, HOME=tmp, XDG_CONFIG_HOME=str(root / "nested" / "config"))

    def run(*args, status=0, extra_env=None):
        result = subprocess.run([binary, *args], cwd=tmp,
                                env=env | (extra_env or {}), capture_output=True, text=True)
        assert result.returncode == status, (args, result.returncode, result.stderr)
        return result.stderr

    # Default config initialization creates missing parent directories and stops.
    assert "Created sample config" in run("one.txt")
    rc = root / "nested/config/kickstart/kickstartrc"
    assert rc.exists()
    if os.name != "nt":
        assert rc.stat().st_mode & 0o777 == 0o600
    rc.write_text("TXT=/bin/echo --\npdf=/usr/bin/false\ndefault=/bin/echo\n")
    out = run("--dry-run", "--", "-file.TXT", "+file.txt")
    commands = [json.loads(line[6:]) for line in out.splitlines() if line.startswith("argv: ")]
    assert len(commands) == 2
    assert commands[0][-1] == str(root / "-file.TXT")
    assert commands[1][-1] == str(root / "+file.txt")
    run("bad.pdf", status=1)  # Child failure propagates.
    run("--batch", "one.txt", "two.pdf", status=1)
    assert "argv:" in run("one.txt", extra_env={"KICKSTART_VERBOSE": "1"})
    run("--check-config")

    custom = root / "custom.rc"
    custom.write_text("default=/bin/echo\ndefault:edit=/bin/echo --edit\n")
    assert '"--edit"' in run("--config", str(custom), "--with", "edit", "--dry-run", "one.txt")
    run("--config", str(root / "missing.rc"), "one.txt", status=1)
    custom.write_text("default=/bin/echo\ninvalid line\n")
    run("--config", str(custom), "one.txt", status=1)

    # A program override needs no config and shell-looking names stay literal.
    rc.unlink()
    run("--program", "/bin/echo", "$(touch injected).txt")
    assert not (root / "injected").exists()
    assert not rc.exists()
    assert "argv:" in run("--program", "/bin/echo", "--batch", "--dry-run", "a", "b")
print("CLI integration checks passed")

if sys.platform == "darwin":
    with tempfile.TemporaryDirectory(prefix="kickstart-macos-config-") as tmp:
        home = Path(tmp).resolve()
        clean_env = dict(os.environ, HOME=str(home))
        clean_env.pop("XDG_CONFIG_HOME", None)
        native = home / "Library/Application Support/kickstart/kickstartrc"
        legacy = home / ".config/kickstart/kickstartrc"

        def discover(expected, overrides=None, extra_args=(), create=False):
            result = subprocess.run(
                [binary, *extra_args, "--dry-run", "one.txt"],
                env=clean_env | (overrides or {}), capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            config_lines = [line for line in result.stderr.splitlines() if line.startswith("Config: ")]
            assert json.loads(config_lines[0][8:]) == str(expected), result.stderr
            assert ("Created sample config" in result.stderr) == create

        discover(native, create=True)
        native.write_text("default=/bin/echo native\n")
        legacy.parent.mkdir(parents=True)
        legacy.write_text("default=/bin/echo legacy\n")
        discover(native)  # Native wins when both exist.
        native.unlink()
        discover(legacy)  # Existing Unix configs continue to work.
        discover(legacy, {"XDG_CONFIG_HOME": "relative/path"})
        discover(legacy, {"XDG_CONFIG_HOME": ""})
        native.write_text("default=/bin/echo native\n")
        xdg = home / "explicit-xdg"
        discover(xdg / "kickstart/kickstartrc", {"XDG_CONFIG_HOME": str(xdg)}, create=True)
        discover(legacy, extra_args=("--config", str(legacy)))
        assert native.read_text() == "default=/bin/echo native\n"
        assert legacy.read_text() == "default=/bin/echo legacy\n"
    print("macOS config discovery checks passed")

with tempfile.TemporaryDirectory(prefix="kickstart-generation-") as tmp:
    root = Path(tmp).resolve()
    env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(root / "xdg"))
    preferred = root / "xdg/kickstart/kickstartrc"

    def operation(*args, status=0):
        result = subprocess.run([binary, *args], env=env, cwd=root,
                                capture_output=True, text=True)
        assert result.returncode == status, (args, result.stderr)
        return result

    assert operation("--show-config-path").stdout == str(preferred) + "\n"
    assert not preferred.exists()
    operation("--gen-config")
    original = preferred.read_bytes()
    operation("--gen-config", status=1)
    assert preferred.read_bytes() == original
    operation("--config", "nested/custom.rc", "--gen-config")
    assert (root / "nested/custom.rc").read_bytes() == original
    assert operation("--config", "nested/custom.rc", "--show-config-path").stdout == "nested/custom.rc\n"
    operation("--gen-config", "file.txt", status=1)
    operation("--gen-config", "--show-config-path", status=1)
    operation("--gen-config", "--program", "/bin/echo", status=1)
    operation("--show-config-path", "--check-config", status=1)
    if os.name != "nt":
        link = root / "link.rc"
        link.symlink_to(preferred)
        operation("--config", str(link), "--gen-config", status=1)
        assert preferred.read_bytes() == original
    if sys.platform == "darwin":
        env["XDG_CONFIG_HOME"] = ""
        legacy = root / ".config/kickstart/kickstartrc"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("default=/bin/echo\n")
        assert operation("--show-config-path").stdout.strip() == str(legacy)
        operation("--gen-config")
        native = root / "Library/Application Support/kickstart/kickstartrc"
        assert native.exists()
        assert operation("--show-config-path").stdout.strip() == str(native)
        assert legacy.read_text() == "default=/bin/echo\n"
print("Config generation checks passed")
