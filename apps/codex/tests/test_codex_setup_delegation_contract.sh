#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
CODEX_SETUP="$SCRIPT_DIR/../codex-setup.sh"

python3 - "$CODEX_SETUP" <<'PY'
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
assert 'SCRIPT_DIR=$(get_script_dir)' in source

expected = [
    '"$SCRIPT_DIR/agents/agents-setup.sh"',
    '"$SCRIPT_DIR/skills/skills-setup.sh"',
    '"$SCRIPT_DIR/custom-instructions/custom-instructions-setup.sh"',
    '"$SCRIPT_DIR/hooks/hooks-setup.sh"',
]
positions = []
for command in expected:
    count = len(re.findall(rf'(?:/bin/bash\s+)?{re.escape(command)}', source))
    assert count == 1, (command, count)
    positions.append(source.index(command))
assert positions == sorted(positions), positions

# The entrypoint directly delegates to component setup scripts.  The
# cross-component transaction layer is not part of this contract.
for forbidden in (
    "CODEX_HARNESS_TRANSACTION_CHILD",
    "transaction.py",
    "--real",
    "--path",
    "--evidence-dir",
    "transaction-evidence",
):
    assert forbidden not in source, forbidden
assert "verify_system_skills_gate" in source
for forbidden in (
    "swiftc",
    "launchctl",
    "PlistBuddy",
    "CustomInstructionsSync",
    "sync-custom-instructions",
    "install-codex-hooks.py",
    "Notion",
):
    assert forbidden not in source, forbidden

# Execute the actual production codex-setup.sh through a temporary
# repository-shaped path.  The production script is not copied or generated:
# its temporary path is a symlink to CODEX_SETUP, while only the delegated
# feature scripts are isolated logging stubs.
relative_paths = [command.split("$SCRIPT_DIR/", 1)[1][:-1] for command in expected]
stages = ["agents", "skills", "custom-instructions", "hooks"]

with tempfile.TemporaryDirectory(prefix="codex-delegation-test.") as temporary:
    root = Path(temporary)
    log = root / "calls.log"
    state = root / "state"
    repository = root / "repository"
    script_dir = repository / "apps" / "codex"
    (repository / "lib").mkdir(parents=True)
    script_dir.mkdir(parents=True)
    source_root = Path(sys.argv[1]).resolve().parents[2]
    (repository / "lib" / "common.sh").symlink_to(source_root / "lib" / "common.sh")
    (script_dir / "codex-setup.sh").symlink_to(Path(sys.argv[1]).resolve())

    for relative in relative_paths:
        child = script_dir / relative
        child.parent.mkdir(parents=True, exist_ok=True)
        stage = relative.split("/", 1)[0]
        child.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            f"printf '%s\\n' '{stage}' >>\"$DELEGATION_LOG\"\n"
            f"if [ \"${{DELEGATION_FAIL_STAGE:-}}\" = '{stage}' ]; then exit 23; fi\n"
            f"printf '%s\\n' success >\"$DELEGATION_STATE_DIR/{stage}.success\"\n",
            encoding="utf-8",
        )
        child.chmod(0o755)

    harness = root / "harness"
    (harness / "skills" / ".system").mkdir(parents=True)
    (harness / "skills" / ".system" / ".codex-system-skills.marker").write_text("fixture\n", encoding="utf-8")
    codex_home = root / "home" / ".codex"
    (codex_home / "skills" / ".system").mkdir(parents=True)
    (codex_home / "skills" / ".system" / ".codex-system-skills.marker").write_text("fixture\n", encoding="utf-8")
    state.mkdir()

    environment = os.environ.copy()
    environment.update(
        CODEX_HARNESS_ROOT_OVERRIDE=str(harness),
        CODEX_HOME_DIR_OVERRIDE=str(codex_home),
        CODEX_SYSTEM_SKILLS_RECOGNITION_COMMAND="true",
        DELEGATION_LOG=str(log),
        DELEGATION_STATE_DIR=str(state),
    )

    def run_setup():
        return subprocess.run(
            ["/bin/bash", str(script_dir / "codex-setup.sh")],
            env=environment,
        )

    def read_log():
        return log.read_text(encoding="utf-8").splitlines() if log.exists() else []

    # A direct successful call proves the real caller's delegation order.
    run_setup_result = run_setup()
    assert run_setup_result.returncode == 0
    assert read_log() == stages

    # A child failure is returned unchanged and later stages are not called.
    log.unlink()
    environment["DELEGATION_FAIL_STAGE"] = "custom-instructions"
    failed = run_setup()
    assert failed.returncode == 23
    assert read_log() == ["agents", "skills", "custom-instructions"]

    # The system-skills gate stops the caller before Hooks.
    log.unlink()
    environment.pop("DELEGATION_FAIL_STAGE")
    (state / "hooks.success").unlink()
    environment["CODEX_SYSTEM_SKILLS_RECOGNITION_COMMAND"] = (
        'printf "%s\\n" system-skills-gate >>"$DELEGATION_LOG"; exit 19'
    )
    gate_failed = run_setup()
    assert gate_failed.returncode == 1
    assert read_log() == ["agents", "skills", "custom-instructions", "system-skills-gate"]
    assert not (state / "hooks.success").exists()

    # Partial success remains after the custom-instructions failure.  Clearing
    # the cause and rerunning the same entrypoint converges all four stages.
    log.unlink()
    for stage in stages:
        (state / f"{stage}.success").unlink(missing_ok=True)
    environment["CODEX_SYSTEM_SKILLS_RECOGNITION_COMMAND"] = "true"
    environment["DELEGATION_FAIL_STAGE"] = "custom-instructions"
    failed_again = run_setup()
    assert failed_again.returncode == 23
    assert read_log() == ["agents", "skills", "custom-instructions"]
    assert (state / "agents.success").read_text(encoding="utf-8").strip() == "success"
    assert (state / "skills.success").read_text(encoding="utf-8").strip() == "success"
    assert not (state / "custom-instructions.success").exists()
    assert not (state / "hooks.success").exists()

    log.unlink()
    environment.pop("DELEGATION_FAIL_STAGE")
    rerun = run_setup()
    assert rerun.returncode == 0
    assert read_log() == stages
    for stage in stages:
        assert (state / f"{stage}.success").read_text(encoding="utf-8").strip() == "success"

print("[PASS] codex-setup direct delegation, gate, failure propagation, and rerun contract")
PY
