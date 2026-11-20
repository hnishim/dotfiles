"""Run with `python3 -m unittest discover -s apps/search/tests -v`."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "search-setup.py"
spec = importlib.util.spec_from_file_location("search_setup", SCRIPT)
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)

A = "11111111-1111-4111-8111-111111111111"
B = "22222222-2222-4222-8222-222222222222"
C = "33333333-3333-4333-8333-333333333333"


class RoutingTests(unittest.TestCase):
    def setUp(self):
        self.spaces = [
            {"id": A, "name": "Personal", "profile": setup.PERSONAL_PROFILE_ID},
            {"id": B, "name": "MOLCURE", "profile": setup.PERSONAL_PROFILE_ID},
            {"id": C, "name": "H2O", "profile": setup.PERSONAL_PROFILE_ID},
        ]
        self.profiles = {setup.PERSONAL_PROFILE_ID: "Personal"}

    def test_resolves_ids_by_name(self):
        config = {"routes": [
            {"space": "Personal", "sites": ["example.com", "x.com"]},
            {"space": "MOLCURE", "sites": ["molcure.slack.com"]},
        ]}
        rows = setup.desired_routes(config, self.spaces, self.profiles)
        self.assertEqual(rows, [
            {"site": "example.com", "space": A},
            {"site": "molcure.slack.com", "space": B},
            {"site": "x.com", "space": A},
        ])
        self.assertIn('site = "example.com"; space = "' + A + '"', setup.openstep_rules(rows))

    def test_invalid_site_and_duplicate_rejected(self):
        for site in ["https://foo.com", "foo.com/path", "*.foo.com", "www.foo.com", "x y.com"]:
            with self.subTest(site=site), self.assertRaises(setup.SetupError):
                setup.desired_routes({"routes": [{"space": "Personal", "sites": [site]}]}, self.spaces, self.profiles)
        with self.assertRaises(setup.SetupError):
            setup.desired_routes({"routes": [{"space": "Personal", "sites": ["example.com"]}, {"space": "H2O", "sites": ["example.com"]}]}, self.spaces, self.profiles)

    def test_missing_and_ambiguous_space_rejected(self):
        with self.assertRaises(setup.SetupError):
            setup.desired_routes({"routes": [{"space": "Other", "sites": ["example.com"]}]}, self.spaces, self.profiles)
        with self.assertRaises(setup.SetupError):
            setup.desired_routes({"routes": [{"space": "MOLCURE", "sites": ["example.com"]}]}, self.spaces + [dict(self.spaces[1], id="44444444-4444-4444-8444-444444444444")], self.profiles)

    def test_profile_disambiguation(self):
        pid = "55555555-5555-4555-8555-555555555555"
        spaces = self.spaces + [{"id": "44444444-4444-4444-8444-444444444444", "name": "Personal", "profile": pid}]
        profs = dict(self.profiles, **{pid: "Work"})
        wanted = setup.desired_routes({"routes": [{"space": "Personal", "profile": "Work", "sites": ["example.com"]}]}, spaces, profs)
        self.assertEqual(wanted[0]["space"], "44444444-4444-4444-8444-444444444444")

    def test_reads_spaced_json_and_default_personal(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "spaces.json"
            path.write_text(json.dumps([{"id": B.lower(), "name": "MOLCURE", "colour": 1}]))
            rows = setup.space_records(path)
            self.assertEqual([x["name"] for x in rows], ["MOLCURE", "Personal"])
            self.assertEqual(rows[0]["id"], B)
            self.assertEqual(rows[1]["id"], setup.PERSONAL_SPACE_ID)

    def test_current_rules_normalization_and_forward_compatibility(self):
        rows = setup.normalize_rules([{"site": "x.com", "space": B.lower()}, {"site": "example.com", "space": A}])
        self.assertEqual(rows[0]["site"], "example.com")
        self.assertEqual(rows[1]["space"], B)
        with self.assertRaises(setup.SetupError):
            setup.normalize_rules([{"site": "x.com", "space": B, "new-field": "unknown"}])

    def test_actual_config_validates(self):
        config = setup.load_json(SCRIPT.with_name("routes.json"))
        spaces = [
            {"id": A, "name": "Personal", "profile": setup.PERSONAL_PROFILE_ID},
            {"id": B, "name": "MOLCURE", "profile": setup.PERSONAL_PROFILE_ID},
            {"id": C, "name": "H2O", "profile": setup.PERSONAL_PROFILE_ID},
        ]
        rows = setup.desired_routes(config, spaces, self.profiles)
        self.assertEqual(len(rows), 37)
        self.assertNotIn("notion.so", {x["site"] for x in rows})
        self.assertNotIn("notion.com", {x["site"] for x in rows})


if __name__ == "__main__":
    unittest.main()
