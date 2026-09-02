# Notion同期ミラーの配置を検証する共通処理。
# 呼び出し元でlib/common.shをsourceしてから読み込む。

path_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

preflight_mirror_root() {
    local mirror_root=$1
    if [ -L "$mirror_root" ]; then
        log_error "Notion同期ミラーrootがsymlinkのため停止します: $mirror_root"
        return 1
    fi
    if [ -e "$mirror_root" ] && [ ! -d "$mirror_root" ]; then
        log_error "Notion同期ミラーrootが通常のフォルダーではありません: $mirror_root"
        return 1
    fi
}

preflight_mirror_tree() {
    local mirror_path=$1
    local kind=$2
    local entry
    local relative

    if ! path_exists "$mirror_path"; then
        return 0
    fi
    if [ -L "$mirror_path" ] || [ ! -d "$mirror_path" ]; then
        log_error "Notion同期ミラーが通常のフォルダーではありません: $mirror_path"
        return 1
    fi

    while IFS= read -r -d '' entry; do
        log_error "Notion同期ミラー内にsymlinkがあるため停止します: $entry"
        return 1
    done < <(find -P "$mirror_path" -type l -print0)

    if [ "$kind" = custom ]; then
        while IFS= read -r -d '' entry; do
            relative=${entry#"$mirror_path"/}
            case "$relative" in
                custom-instructions.md|user-profile.md) ;;
                *)
                    log_error "Notion同期ミラー内に想定外のファイルがあります: $entry"
                    return 1
                    ;;
            esac
        done < <(find -P "$mirror_path" -type f -print0)

        if find -P "$mirror_path" -mindepth 1 -type d -print -quit | grep -q .; then
            log_error "Notion同期ミラー内に想定外のサブフォルダーがあります: $mirror_path"
            return 1
        fi
        return 0
    fi

    while IFS= read -r -d '' entry; do
        relative=${entry#"$mirror_path"/}
        if [[ "$relative" == */* ]]; then
            log_error "Skills同期ミラー内に想定外の階層があります: $entry"
            return 1
        fi
        if [ "$relative" != writing-references ] && [ ! -f "$entry/SKILL.md" ]; then
            log_error "Skills同期ミラー内のスキルフォルダーにSKILL.mdがありません: $entry"
            return 1
        fi
    done < <(find -P "$mirror_path" -mindepth 1 -type d -print0)

    while IFS= read -r -d '' entry; do
        relative=${entry#"$mirror_path"/}
        case "$relative" in
            */SKILL.md|writing-references/*.md) ;;
            *)
                log_error "Skills同期ミラー内に想定外のファイルがあります: $entry"
                return 1
                ;;
        esac
    done < <(find -P "$mirror_path" -type f -print0)
}

validate_generated_mirrors() {
    local source_root=$1
    local skills_source=$2
    local custom_mirror=$3
    local skills_mirror=$4

    /usr/bin/python3 - "$source_root" "$skills_source" "$custom_mirror" "$skills_mirror" <<'PY'
from pathlib import Path
import stat
import sys


source_root = Path(sys.argv[1])
skills_source = Path(sys.argv[2])
custom_mirror = Path(sys.argv[3])
skills_mirror = Path(sys.argv[4])


def fail(message):
    print(f"[ERROR] {message}", file=sys.stderr)
    raise SystemExit(1)


def check_tree(root):
    if root.is_symlink() or not root.is_dir():
        fail(f"生成されたNotion同期ミラーが通常のフォルダーではありません: {root}")
    for path in [root, *sorted(root.rglob("*"))]:
        if path.is_symlink():
            fail(f"生成されたNotion同期ミラーにsymlinkがあります: {path}")
        if path.is_dir():
            mode = stat.S_IMODE(path.stat().st_mode)
            if mode != 0o700:
                fail(f"生成されたNotion同期ミラーのdirectory権限が不正です: {path} ({mode:04o})")
        elif path.is_file():
            mode = stat.S_IMODE(path.stat().st_mode)
            if mode != 0o600:
                fail(f"生成されたNotion同期ミラーのfile権限が不正です: {path} ({mode:04o})")
        else:
            fail(f"生成されたNotion同期ミラーに不明な種別があります: {path}")


check_tree(custom_mirror)
check_tree(skills_mirror)

actual_custom = {
    path.relative_to(custom_mirror).as_posix()
    for path in custom_mirror.rglob("*")
}
if actual_custom != {"custom-instructions.md", "user-profile.md"}:
    fail("生成されたcustom-instructions同期ミラーの構造が正本の想定と一致しません")

custom_source = source_root / "custom-instructions.md"
openai_source = source_root / "openai-instructions.md"
custom_expected = custom_source.read_bytes()
if not custom_expected.endswith(b"\n"):
    custom_expected += b"\n"
custom_expected += b"\n" + openai_source.read_bytes()
if not custom_expected.endswith(b"\n"):
    custom_expected += b"\n"

custom_actual = custom_mirror / "custom-instructions.md"
if custom_actual.read_bytes() != custom_expected:
    fail(f"生成されたcustom-instructions.mdが正本と一致しません: {custom_actual}")
profile_source = source_root / "user-profile.md"
profile_actual = custom_mirror / "user-profile.md"
if profile_actual.read_bytes() != profile_source.read_bytes():
    fail(f"生成されたuser-profile.mdが正本と一致しません: {profile_actual}")

expected_skills = {}
for child in skills_source.iterdir():
    if child.name.startswith(".") or not child.is_dir():
        continue
    skill = child / "SKILL.md"
    if skill.is_file():
        expected_skills[f"{child.name}/SKILL.md"] = skill.read_bytes()

references = skills_source / "writing-references"
for reference in references.iterdir():
    if reference.name.startswith(".") or not reference.is_file():
        continue
    if reference.suffix.lower() == ".md":
        expected_skills[f"writing-references/{reference.name}"] = reference.read_bytes()

actual_skills = {
    path.relative_to(skills_mirror).as_posix(): path.read_bytes()
    for path in skills_mirror.rglob("*")
    if path.is_file()
}
expected_skill_entries = set(expected_skills)
for relative in expected_skills:
    expected_skill_entries.add(relative.split("/", 1)[0])
actual_skill_entries = {
    path.relative_to(skills_mirror).as_posix()
    for path in skills_mirror.rglob("*")
}
if actual_skill_entries != expected_skill_entries:
    fail("生成されたSkills同期ミラーの構造が正本の想定と一致しません")
if set(actual_skills) != set(expected_skills):
    fail("生成されたSkills同期ミラーのファイル一覧が正本と一致しません")
for relative, expected in expected_skills.items():
    if actual_skills[relative] != expected:
        fail(f"生成されたSkills同期ミラーが正本と一致しません: {relative}")
PY
}
