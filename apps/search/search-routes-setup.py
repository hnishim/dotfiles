#!/usr/bin/env python3
"""Reproduce Search Browser's 'Send links to a space' rules from dotfiles.

Only two defaults keys in com.officecommun.search are written. All other
preferences, spaces, profiles and user data remain under Search's control.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import uuid

DOMAIN = "com.officecommun.search"
RULES_KEY = "spaces.links.rules"
ENABLED_KEY = "spaces.links"
APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Search"
DEFAULT_CONFIG = Path(__file__).with_name("routes.json")
BACKUP_DIR = Path.home() / "Library" / "Application Support" / "Search Routing Backups"
PERSONAL_PROFILE_ID = "00000000-0000-0000-0000-0000000000A1"
PERSONAL_SPACE_ID = "00000000-0000-0000-0000-000000000001"
HOST = re.compile(r"(?=.{1,253}$)(?:[a-z0-9-]+\.)+[a-z0-9-]+$")


class SetupError(Exception):
    pass


def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SetupError(f"JSONを読み込めません: {path}: {exc}") from exc


def space_records(path: Path) -> list[dict]:
    """Read Search's spaces; do not invent a missing MOLCURE/H2O space."""
    if not path.is_file():
        raise SetupError(f"スペース定義が見つかりません: {path}。Searchでスペースを作成してから実行してください。")
    rows = load_json(path)
    if not isinstance(rows, list):
        raise SetupError("spaces.jsonの形式が想定外です（配列ではありません）")
    spaces: list[dict] = []
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("name"), str) or not row.get("name"):
            raise SetupError("spaces.jsonに不正なスペース定義があります")
        try:
            sid = str(uuid.UUID(row["id"])).upper()
            pid = str(uuid.UUID(row.get("profile") or PERSONAL_PROFILE_ID)).upper()
        except (ValueError, TypeError, KeyError) as exc:
            raise SetupError("spaces.jsonに不正なUUIDがあります") from exc
        spaces.append({"id": sid, "name": row["name"], "profile": pid})
    # Search implicitly restores the initial Personal space if it is absent.
    if not any(s["id"] == PERSONAL_SPACE_ID for s in spaces):
        spaces.append({"id": PERSONAL_SPACE_ID, "name": "Personal", "profile": PERSONAL_PROFILE_ID})
    return spaces


def profile_records(path: Path) -> dict[str, str]:
    # Search's implicit first profile exists even without profiles.json.
    profiles = {PERSONAL_PROFILE_ID: "Personal"}
    if path.is_file():
        rows = load_json(path)
        if not isinstance(rows, list):
            raise SetupError("profiles.jsonの形式が想定外です")
        for row in rows:
            if not isinstance(row, dict):
                raise SetupError("profiles.jsonに不正な要素があります")
            try:
                pid = str(uuid.UUID(row["id"])).upper()
            except (KeyError, ValueError, TypeError) as exc:
                raise SetupError("profiles.jsonのUUIDが不正です") from exc
            if not isinstance(row.get("name"), str):
                raise SetupError("profiles.jsonに不正な名前があります")
            profiles[pid] = row["name"]
    return profiles


def desired_routes(config: dict, spaces: list[dict], profiles: dict[str, str]) -> list[dict[str, str]]:
    groups = config.get("routes") if isinstance(config, dict) else None
    if not isinstance(groups, list) or not groups:
        raise SetupError("routes.jsonのroutesに1件以上のグループが必要です")
    seen: dict[str, str] = {}
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("space"), str):
            raise SetupError("routes.jsonのspaceが不正です")
        name = group["space"]
        profile_name = group.get("profile")
        if profile_name is not None and not isinstance(profile_name, str):
            raise SetupError(f"{name}: profileには文字列を指定してください")
        candidates = [s for s in spaces if s["name"] == name and
                      (profile_name is None or profiles.get(s["profile"]) == profile_name)]
        if len(candidates) != 1:
            raise SetupError(f"スペース {name!r} (profile={profile_name!r}) が一意に見つかりません: {len(candidates)}件。設定を書き換えず停止します。")
        uid = candidates[0]["id"]
        sites = group.get("sites")
        if not isinstance(sites, list) or not sites:
            raise SetupError(f"{name}: sitesに1件以上のドメインが必要です")
        for site in sites:
            if not isinstance(site, str) or not HOST.fullmatch(site):
                raise SetupError(f"{name}: 不正なドメインです: {site!r}（www.は省略してください）")
            if site.startswith("www."):
                raise SetupError(f"{name}: Searchはwww.を除去します: {site}")
            if site in seen:
                raise SetupError(f"重複ドメインです: {site}（{name}と既存ルール）")
            seen[site] = uid
    return [{"site": site, "space": seen[site]} for site in sorted(seen)]


def normalize_rules(value) -> list[dict[str, str]]:
    if not isinstance(value, list):
        raise SetupError(f"{RULES_KEY}が配列ではありません。自動上書きは行いません。")
    out = []
    for item in value:
        if not isinstance(item, dict) or set(item) != {"site", "space"} or not all(isinstance(v, str) for v in item.values()):
            raise SetupError(f"{RULES_KEY}に未知の形式があります。自動上書きは行いません。")
        out.append({"site": item["site"], "space": item["space"].upper()})
    return sorted(out, key=lambda i: i["site"])


def defaults_export() -> tuple[dict, bytes]:
    result = subprocess.run(["defaults", "export", DOMAIN, "-"], capture_output=True, check=False)
    if result.returncode != 0:
        raise SetupError("Searchの設定をdefaults exportで取得できません。Searchを一度起動し、終了してから実行してください。")
    try:
        prefs = plistlib.loads(result.stdout)
    except (ValueError, plistlib.InvalidFileException) as exc:
        raise SetupError("Searchの設定plistを解釈できません") from exc
    if not isinstance(prefs, dict):
        raise SetupError("Searchの設定plistが辞書形式ではありません")
    return prefs, result.stdout


def openstep_rules(rows: list[dict[str, str]]) -> str:
    """Valid old-style property list for `defaults write domain key value`."""
    # Each field is strictly validated in desired_routes().
    return "(" + ", ".join(
        '{ site = "%s"; space = "%s"; }' % (r["site"], r["space"])
        for r in rows
    ) + ")"


def backup_current(prefs: dict) -> Path:
    BACKUP_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    path = BACKUP_DIR / f"search-routing-{stamp}.json"
    data = {"domain": DOMAIN, "enabled": prefs.get(ENABLED_KEY), "rules": prefs.get(RULES_KEY)}
    fd, tmp = tempfile.mkstemp(dir=BACKUP_DIR, prefix=".routing-", suffix=".tmp")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return path


def search_is_running() -> bool:
    result = subprocess.run(["pgrep", "-x", "Search"], capture_output=True, check=False)
    if result.returncode not in (0, 1):
        raise SetupError("Searchの実行状態を確認できません")
    return result.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="変更せず差分のみ表示")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG, help="ドメイン→スペースの対応表")
    parser.add_argument("--support-dir", type=Path, default=APP_SUPPORT, help=argparse.SUPPRESS)
    args = parser.parse_args()

    if sys.platform != "darwin":
        raise SetupError("macOS専用のセットアップです")

    config = load_json(args.config)
    spaces = space_records(args.support_dir / "spaces.json")
    profiles = profile_records(args.support_dir / "profiles.json")
    wanted = desired_routes(config, spaces, profiles)
    if not args.check and search_is_running():
        raise SetupError("Search Browserが起動中です。完全終了してから再実行してください。")

    prefs, _ = defaults_export()
    current = normalize_rules(prefs.get(RULES_KEY, []))
    enabled = prefs.get(ENABLED_KEY, False)
    if not isinstance(enabled, bool):
        raise SetupError(f"{ENABLED_KEY}が真偽値ではありません。自動上書きは行いません。")
    change_rules = current != wanted
    change_enabled = not enabled
    if not change_rules and not change_enabled:
        print(f"[OK] 設定済みです（{len(wanted)}ドメイン）。変更はありません。")
        return 0

    print(f"[INFO] 期待するルール: {len(wanted)}件、現在: {len(current)}件、機能有効: {enabled}")
    if change_rules:
        print("[INFO] spaces.links.rules を更新します（既存ルールは置き換わります）")
    if change_enabled:
        print("[INFO] spaces.links を true にします")
    if args.check:
        print("[CHECK] 変更は行っていません。")
        return 0

    backup = backup_current(prefs)
    print(f"[INFO] 更新前のルールを保存: {backup}")
    if change_rules:
        subprocess.run(["defaults", "write", DOMAIN, RULES_KEY, openstep_rules(wanted)], check=True)
    if change_enabled:
        subprocess.run(["defaults", "write", DOMAIN, ENABLED_KEY, "-bool", "true"], check=True)
    after, _ = defaults_export()
    if normalize_rules(after.get(RULES_KEY, [])) != wanted or after.get(ENABLED_KEY) is not True:
        raise SetupError(f"更新後の検証に失敗しました。バックアップ: {backup}")
    print(f"[OK] 設定を適用しました（{len(wanted)}ドメイン）。Searchを起動して動作を確認してください。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (SetupError, subprocess.CalledProcessError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        sys.exit(1)
