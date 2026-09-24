import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from compile_dictionary import CompileFailure, build_grammar, main  # noqa: E402
from octagram import (  # noqa: E402
    FZGram,
    block_prefix,
    GramFormatError,
    decode_key,
    encode_key,
    iterate_gram_entries,
    read_gram_units,
    write_fzgram,
)

FIXTURES = Path(__file__).resolve().parent / "fixtures"
REPOSITORY = Path(__file__).resolve().parents[3]
FIXTURE_TEXT = FIXTURES / "octagram_tests.txt"
FIXTURE_BLOCK_SIZE = 4
COMMITTED_SWIFT_FIXTURE = REPOSITORY / "FlickZhuyinTests" / "Fixtures" / "flickzhuyin-tests.gram"
PRODUCTION_SOURCE = REPOSITORY / "Vendor" / "rime-octagram-data" / "zh-hant-t-essay-bgw.gram"
PRODUCTION_MANIFEST = REPOSITORY / "Vendor" / "rime-octagram-data" / "SOURCE.json"
PRODUCTION_GRAMMAR = REPOSITORY / "Generated" / "flickzhuyin.gram"
PRODUCTION_REPORT = REPOSITORY / "Generated" / "grammar-report.json"


def build_darts(keys: dict[bytes, int]) -> bytes:
    """Build a tiny darts-clone array (no compact offsets) wrapped in a .gram header."""
    units = [0] * 4096
    used = {0}
    # darts-clone gives every node its own base; shared bases would merge
    # the nodes' children.
    bases: set[int] = set()

    def unit_for(offset: int, has_leaf: bool, label: int) -> int:
        assert offset < (1 << 21)
        return (offset << 10) | (0x100 if has_leaf else 0) | label

    def build(node: int, label: int, prefix: bytes) -> None:
        child_labels = sorted({key[len(prefix)] for key in keys if len(key) > len(prefix) and key.startswith(prefix)})
        has_leaf = prefix in keys and prefix != b""
        labels = ([0] if has_leaf else []) + child_labels
        base = 1
        while base in bases or any((base ^ c) in used for c in labels):
            base += 1
        bases.add(base)
        for c in labels:
            used.add(base ^ c)
        offset = node ^ base
        units[node] = unit_for(offset, has_leaf, label)
        if has_leaf:
            units[base] = 0x80000000 | keys[prefix]
        for c in child_labels:
            build(base ^ c, c, prefix + bytes((c,)))

    build(0, 0, b"")
    size = max(used) + 1
    header = b"Rime::Grammar/1.0".ljust(32, b"\x00") + struct.pack("<IIi", 0, size, 4)
    return header + struct.pack(f"<{size}I", *units[:size])


class EncodingTests(unittest.TestCase):
    def test_known_encodings(self):
        self.assertEqual(encode_key("a"), b"a")
        self.assertEqual(encode_key("\x00"), b"\xe0")
        self.assertEqual(encode_key("天"), bytes(((0x5929 >> 8) + 0x40, 0x29)))
        self.assertEqual(encode_key("一"), b"\xe1\x8e")
        self.assertEqual(encode_key("〇"), b"\xe3\x86\x80\xb8")

    def test_round_trips(self):
        for text in ("天氣很好", "〇點", "一鼀", "𠀀字", "a$", "ㄅㄆ", "\x00x"):
            self.assertEqual(decode_key(encode_key(text)), text)

    def test_truncated_key_is_rejected(self):
        with self.assertRaises(GramFormatError):
            decode_key(b"\xe3\x86")


class GramReaderTests(unittest.TestCase):
    def test_reads_every_key_from_a_darts_array(self):
        entries = {"天氣很": 110235, "天氣": 90000, "的$": 188028, "〇點": 69697}
        data = build_darts({encode_key(key): value for key, value in entries.items()})
        decoded = {decode_key(key): value for key, value in iterate_gram_entries(read_gram_units(data))}
        self.assertEqual(decoded, entries)

    def test_rejects_other_formats(self):
        with self.assertRaises(GramFormatError):
            read_gram_units(b"not a grammar".ljust(64, b"\x00"))


class FZGramTests(unittest.TestCase):
    def test_round_trip_across_block_sizes(self):
        entries = [(f"詞{index:03d}", 69077 + index * 97) for index in range(100)]
        for block_size in (1, 3, 16, 200):
            reader = FZGram(write_fzgram(entries, 1, block_size))
            self.assertEqual(reader.key_count, len(entries))
            for key, value in entries:
                decoded = reader.value(key)
                self.assertIsNotNone(decoded, key)
                self.assertLessEqual(value - decoded, (1 << reader.value_shift) - 1)
            self.assertIsNone(reader.value("詞"))
            self.assertIsNone(reader.value("詞999"))
            self.assertIsNone(reader.value("\x01"))
            self.assertEqual([key for key, _ in reader.items()], sorted(key for key, _ in entries))
            self.assertEqual(
                list(reader.block_prefixes),
                [block_prefix(reader._first_key(block)) for block in range(reader.block_count)],
            )

    def test_value_quantization(self):
        reader = FZGram(write_fzgram([("a", 69077), ("b", 198733), ("c", 110235)], 1))
        self.assertEqual(reader.value_shift, 1)
        self.assertEqual(reader.value("a"), 69077)
        self.assertEqual(reader.value("c"), 110235)
        self.assertEqual(reader.value("b"), 198733)

    def test_rejects_duplicates_and_empty_input(self):
        with self.assertRaises(GramFormatError):
            write_fzgram([("a", 1), ("a", 2)], 1)
        with self.assertRaises(GramFormatError):
            write_fzgram([], 1)


class BuildGrammarTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_text_source_build_drops_sentence_start_keys(self):
        output = self.directory / "fixture.gram"
        report_path = self.directory / "report.json"
        result = build_grammar(output, report_path, text_source_path=FIXTURE_TEXT)
        self.assertEqual(result.dropped_keys, 1)
        reader = FZGram(output.read_bytes())
        self.assertIsNone(reader.value("$我"))
        self.assertEqual(reader.value("天氣很"), 110235)
        self.assertLessEqual(188028 - reader.value("的$"), (1 << reader.value_shift) - 1)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(report["keyCount"], result.key_count)

    def test_rejects_malformed_text(self):
        source = self.directory / "bad.txt"
        source.write_text("天氣\tnot-a-number\n", encoding="utf-8")
        with self.assertRaises(CompileFailure):
            build_grammar(self.directory / "o.gram", self.directory / "r.json", text_source_path=source)

    def test_source_requires_manifest_hash_match(self):
        source = self.directory / "zh-hant-t-essay-bgw.gram"
        source.write_bytes(build_darts({encode_key("天氣"): 90000}))
        (self.directory / "LICENSE").write_text("license", encoding="utf-8")
        manifest = self.directory / "SOURCE.json"
        manifest.write_text(
            json.dumps(
                {
                    "repository": "https://example.invalid/octagram",
                    "commit": "0" * 40,
                    "gramPath": source.name,
                    "sha256": "0" * 64,
                    "licensePath": "LICENSE",
                    "licenseSha256": "0" * 64,
                    "formatVersion": 1,
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaises(CompileFailure):
            build_grammar(self.directory / "o.gram", self.directory / "r.json", source, manifest)

    def test_committed_swift_fixture_is_current(self):
        output = self.directory / "fixture.gram"
        code = main(
            [
                "build-grammar",
                "--text-source", str(FIXTURE_TEXT),
                "--block-size", str(FIXTURE_BLOCK_SIZE),
                "--output", str(output),
                "--report", str(self.directory / "report.json"),
            ]
        )
        self.assertEqual(code, 0)
        if not COMMITTED_SWIFT_FIXTURE.exists():
            self.fail("run the grammar fixture build command to generate FlickZhuyinTests/Fixtures/flickzhuyin-tests.gram")
        self.assertEqual(output.read_bytes(), COMMITTED_SWIFT_FIXTURE.read_bytes())


@unittest.skipUnless(PRODUCTION_SOURCE.exists(), "octagram source has not been fetched")
class ProductionGrammarTests(unittest.TestCase):
    GOLDEN = {"天氣很": 110235, "天氣很好": 102272, "我們今": 73065, "我們今天": 122373, "的$": 188028}

    def test_source_contains_golden_values(self):
        wanted = {encode_key(key): key for key in self.GOLDEN}
        entries = {}
        for key, value in iterate_gram_entries(read_gram_units(PRODUCTION_SOURCE.read_bytes())):
            if key in wanted:
                entries[wanted[key]] = value
        for key, value in self.GOLDEN.items():
            self.assertEqual(entries.get(key), value, key)

    @unittest.skipUnless(PRODUCTION_GRAMMAR.exists(), "production grammar has not been built")
    def test_generated_grammar_matches_report_and_golden_values(self):
        data = PRODUCTION_GRAMMAR.read_bytes()
        report = json.loads(PRODUCTION_REPORT.read_text(encoding="utf-8"))
        self.assertEqual(len(data), report["output"]["bytes"])
        reader = FZGram(data)
        self.assertEqual(reader.key_count, report["keyCount"])
        for key, value in self.GOLDEN.items():
            decoded = reader.value(key)
            self.assertIsNotNone(decoded, key)
            self.assertLessEqual(value - decoded, (1 << reader.value_shift) - 1, key)
        self.assertIsNone(reader.value("$我"))


if __name__ == "__main__":
    unittest.main()
