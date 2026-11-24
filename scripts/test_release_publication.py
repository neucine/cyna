import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch

import release_distribution


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("publish_release", ROOT / ".buildkite/scripts/publish-release.py")
publish_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publish_release)


class RemoteTagTests(unittest.TestCase):
    def test_prefers_peeled_annotated_tag_commit(self):
        output = "\n".join([
            "aaa\trefs/tags/v0.5.4",
            "bbb\trefs/tags/v0.5.4^{}",
        ])
        self.assertEqual(publish_release.parse_remote_tag(output, "v0.5.4"), "bbb")

    def test_accepts_lightweight_tag(self):
        output = "aaa\trefs/tags/v0.5.4"
        self.assertEqual(publish_release.parse_remote_tag(output, "v0.5.4"), "aaa")

    def test_ignores_unrelated_tags(self):
        output = "aaa\trefs/tags/v0.5.3\nbbb\trefs/tags/v0.5.4-beta.1"
        self.assertIsNone(publish_release.parse_remote_tag(output, "v0.5.4"))


class ReleaseLookupTests(unittest.TestCase):
    @patch.object(publish_release.time, "sleep")
    @patch.object(publish_release.time, "monotonic", side_effect=[0, 0, 5])
    @patch.object(publish_release, "run")
    def test_waits_for_new_draft_release_to_appear(self, run, monotonic, sleep):
        run.side_effect = ["[]", json.dumps([{"tag_name": "v0.5.4", "id": 1}])]
        self.assertEqual(publish_release.find_release("v0.5.4", wait_seconds=5), {"tag_name": "v0.5.4", "id": 1})
        sleep.assert_called_once_with(1)

    @patch.object(publish_release.time, "sleep")
    @patch.object(publish_release, "run", return_value="[]")
    def test_does_not_wait_when_polling_is_disabled(self, run, sleep):
        self.assertIsNone(publish_release.find_release("v0.5.4"))
        sleep.assert_not_called()


class HomepageVersionTests(unittest.TestCase):
    def test_homepage_accepts_hero_version(self):
        homepage = '<h1 class="heading"><span>Cyna 0.5.4</span></h1>'
        self.assertTrue(release_distribution.homepage_mentions_version(homepage, "0.5.4"))

    def test_homepage_accepts_navigation_version(self):
        homepage = '<a href="https://github.com/neucine/cyna/releases/tag/v0.5.4">v0.5.4</a>'
        self.assertTrue(release_distribution.homepage_mentions_version(homepage, "0.5.4"))

    def test_homepage_rejects_previous_release(self):
        homepage = "<span>Cyna 0.5.3</span><span>v0.5.3</span>"
        self.assertFalse(release_distribution.homepage_mentions_version(homepage, "0.5.4"))


if __name__ == "__main__":
    unittest.main()
