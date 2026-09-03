#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
CODEX_SETUP="$SCRIPT_DIR/../codex-setup.sh"

python3 - "$CODEX_SETUP" <<'PY'
import re
import os
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

# The wrapper owns the transaction and system-skills gate, while feature
# setup details belong to the delegated scripts.
assert re.search(r'CODEX_HARNESS_TRANSACTION_CHILD', source)
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
# feature scripts are isolated logging stubs.  This keeps the test from
# passing when production contains unreachable or incorrect delegation code.
relative_paths = [command.split("$SCRIPT_DIR/", 1)[1][:-1] for command in expected]
with tempfile.TemporaryDirectory(prefix="codex-delegation-test.") as temporary:
    root = Path(temporary)
    log = root / "calls.log"
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
            f"if [ \"${{DELEGATION_FAIL_STAGE:-}}\" = '{stage}' ]; then exit 23; fi\n",
            encoding="utf-8",
        )
        child.chmod(0o755)

    harness = root / "harness"
    (harness / "skills" / ".system").mkdir(parents=True)
    (harness / "skills" / ".system" / ".codex-system-skills.marker").write_text("fixture\n", encoding="utf-8")
    codex_home = root / "home" / ".codex"
    (codex_home / "skills" / ".system").mkdir(parents=True)
    (codex_home / "skills" / ".system" / ".codex-system-skills.marker").write_text("fixture\n", encoding="utf-8")

    environment = os.environ.copy()
    environment.update(
        CODEX_HARNESS_TRANSACTION_CHILD="1",
        CODEX_HARNESS_ROOT_OVERRIDE=str(harness),
        CODEX_HOME_DIR_OVERRIDE=str(codex_home),
        CODEX_SYSTEM_SKILLS_RECOGNITION_COMMAND="true",
        DELEGATION_LOG=str(log),
    )
    environment.pop("DELEGATION_FAIL_STAGE", None)
    stages = ["agents", "skills", "custom-instructions", "hooks"]
    subprocess.run(["/bin/bash", str(script_dir / "codex-setup.sh")], env=environment, check=True)
    assert log.read_text(encoding="utf-8").splitlines() == stages

    log.unlink()
    environment["DELEGATION_FAIL_STAGE"] = "custom-instructions"
    failed = subprocess.run(["/bin/bash", str(script_dir / "codex-setup.sh")], env=environment)
    assert failed.returncode == 23
    assert log.read_text(encoding="utf-8").splitlines() == [
        "agents", "skills", "custom-instructions"
    ]

print("[PASS] codex-setup delegation, order, and responsibility contract")
PY
