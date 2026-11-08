import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class StickerCatalogTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = json.loads((ROOT / "scripts/sticker-labels.json").read_text(encoding="utf-8"))
        cls.server = json.loads((ROOT / "server/internal/handlers/sticker_assets/catalog.json").read_text(encoding="utf-8-sig"))

    def test_all_official_packs_match_source_ids_names_and_order(self):
        self.assertEqual(set(self.source), {group["id"] for group in self.server})
        for group in self.server:
            with self.subTest(pack=group["id"]):
                actual = [{"id": item["id"], "name": item["label"]} for item in group["items"]]
                self.assertEqual(actual, self.source[group["id"]]["items"])
                self.assertEqual(len(actual), 16)
                self.assertEqual(len({item["id"] for item in actual}), len(actual))

    def test_builtin_client_catalog_matches_source_ids_names_and_order(self):
        text = (ROOT / "client/lib/widgets/emoji/sticker_catalog.dart").read_text(encoding="utf-8")
        entries = re.findall(
            r"AppSticker\(id: '([0-9a-f]{32})', label: '([^']*)', thumbnailAsset: '([^']+)'\)",
            text,
        )
        expected = self.source["mingfeng-daily"]["items"]
        self.assertEqual([{"id": key, "name": name} for key, name, _ in entries], expected)
        for asset_id, _, thumbnail in entries:
            self.assertEqual(thumbnail, f"assets/images/stickers/mingfeng-daily/{asset_id}.png")
            self.assertTrue((ROOT / "client" / thumbnail).is_file())


if __name__ == "__main__":
    unittest.main()
