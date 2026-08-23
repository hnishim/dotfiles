"""Tests for the PowerPoint shortcut shell/Python boundary.

The shell block is executed in temporary harnesses with fake ``pgrep`` and
``python3`` commands. No real defaults command, plist, or PowerPoint process
is accessed.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULTS_DIR = REPO_ROOT / "defaults"
SHELL_SCRIPT = DEFAULTS_DIR / "defaults-setup.sh"


def _shell_text() -> str:
    return SHELL_SCRIPT.read_text(encoding="utf-8")


def _powerpoint_block(shell: str) -> str:
    match = re.search(
        r"(?ms)^# PowerPointでオブジェクト整列メニューのショートカットを設定\n"
        r".*?(?=^# --- 変更の反映 ---$)",
        shell,
    )
    assert match, "PowerPoint shell block is missing"
    return match.group(0)


def _script_dir_assignment(shell: str) -> str:
    match = re.search(r"(?m)^SCRIPT_DIR=.*BASH_SOURCE\[0\].*$", shell)
    assert match, "SCRIPT_DIR must be derived from BASH_SOURCE[0]"
    return match.group(0)


def _write_fake_commands(bin_dir: Path) -> None:
    (bin_dir / "pgrep").write_text(
        "#!/bin/sh\n"
        "if [ \"${FAKE_POWERPOINT_RUNNING:-0}\" = 1 ]; then exit 0; fi\n"
        "exit 1\n",
        encoding="utf-8",
    )
    (bin_dir / "python3").write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' \"$@\" > \"$FAKE_PYTHON_LOG\"\n"
        "exit \"${FAKE_PYTHON_STATUS:-1}\"\n",
        encoding="utf-8",
    )
    for command in (bin_dir / "pgrep", bin_dir / "python3"):
        command.chmod(0o755)


def _run_powerpoint_harness(
    shell: str,
    tmp_path: Path,
    *,
    python_status: int = 0,
    powerpoint_running: bool = False,
) -> subprocess.CompletedProcess[str]:
    """Run the production PowerPoint block, isolated from other setup code."""
    harness_dir = tmp_path / "harness"
    bin_dir = harness_dir / "bin"
    harness_dir.mkdir(parents=True)
    bin_dir.mkdir()
    python_log = harness_dir / "python-args.log"
    _write_fake_commands(bin_dir)

    harness = "#!/usr/bin/env bash\nset -u\n"
    harness += "DEFAULTS_FAILURES=0\nDEFAULTS_CHANGED=0\n"
    harness += "mark_changed() { DEFAULTS_CHANGED=1; }\n"
    harness += _script_dir_assignment(shell) + "\n"
    harness += _powerpoint_block(shell)
    harness += 'printf "failures=%s changed=%s\\n" "$DEFAULTS_FAILURES" "$DEFAULTS_CHANGED"\n'
    harness_path = harness_dir / "run.sh"
    harness_path.write_text(harness, encoding="utf-8")
    harness_path.chmod(0o755)
    unrelated_cwd = tmp_path / "unrelated-cwd"
    unrelated_cwd.mkdir()

    environment = os.environ.copy()
    environment["PATH"] = f"{bin_dir}:/usr/bin:/bin"
    environment["FAKE_PYTHON_LOG"] = str(python_log)
    environment["FAKE_PYTHON_STATUS"] = str(python_status)
    environment["FAKE_POWERPOINT_RUNNING"] = "1" if powerpoint_running else "0"

    return subprocess.run(
        [str(harness_path)],
        cwd=unrelated_cwd,
        env=environment,
        capture_output=True,
        text=True,
    )


def test_powerpoint_block_has_only_external_python_call_and_is_parseable() -> None:
    shell = _shell_text()
    block = _powerpoint_block(shell)

    assert "<<" not in block
    assert not re.search(
        r"(?m)^\s*(?:import |from |def |try:|except |class |raise SystemExit|plistlib|Path\(|os\.replace)",
        block,
    ), "inline Python implementation remains in the shell block"

    python_calls = re.findall(r"(?m)^\s*python3\s+.*$", block)
    assert len(python_calls) == 1, "PowerPoint must have one external Python call"
    assert "configure-powerpoint-shortcuts.py" in python_calls[0]

    syntax = subprocess.run(
        ["bash", "-n", str(SHELL_SCRIPT)], capture_output=True, text=True
    )
    assert syntax.returncode == 0, syntax.stderr


def test_script_dir_call_works_from_an_unrelated_cwd_and_uses_bash_source() -> None:
    shell = _shell_text()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        result = _run_powerpoint_harness(shell, root, python_status=0)
        assert result.returncode == 0, result.stderr
        assert "failures=0 changed=0" in result.stdout
        log = root / "harness" / "python-args.log"
        assert log.read_text(encoding="utf-8").strip().endswith(
            "configure-powerpoint-shortcuts.py"
        )


def test_shell_executes_10_zero_and_other_status_branches() -> None:
    shell = _shell_text()
    expected = {10: (0, 1), 0: (0, 0), 1: (1, 0)}
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for status, (failures, changed) in expected.items():
            result = _run_powerpoint_harness(
                shell, root / str(status), python_status=status
            )
            assert result.returncode == 0, result.stderr
            assert f"failures={failures} changed={changed}" in result.stdout


def test_running_powerpoint_skips_helper_and_counts_failure() -> None:
    shell = _shell_text()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        result = _run_powerpoint_harness(
            shell, root, python_status=10, powerpoint_running=True
        )
        assert result.returncode == 0, result.stderr
        assert "failures=1 changed=0" in result.stdout
        assert not (root / "harness" / "python-args.log").exists()
