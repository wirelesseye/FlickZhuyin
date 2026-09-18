import hashlib
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from compile_dictionary import (  # noqa: E402
    CompileFailure,
    build_database,
    main,
    parse_dictionary,
)
from pinyin_to_zhuyin import convert_syllable  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"
REPOSITORY = Path(__file__).resolve().parents[3]
PRODUCTION_SOURCE = REPOSITORY / "Vendor" / "rime-terra-pinyin" / "terra_pinyin.dict.yaml"
PRODUCTION_MANIFEST = REPOSITORY / "Vendor" / "rime-terra-pinyin" / "SOURCE.json"

HEADER = 'name: test_dict\nversion: "1.0"\nsort: by_weight\nuse_preset_vocabulary: true\n'


class CompilerTestCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def write_dictionary(self, body, header=HEADER):
        source = self.directory / "test.dict.yaml"
        source.write_text(f"---\n{header}...\n{body}", encoding="utf-8")
        manifest = self.directory / "SOURCE.json"
        manifest.write_text(
            json.dumps(
                {
                    "repository": "https://example.invalid/test",
                    "commit": "0" * 40,
                    "dictionaryPath": "test.dict.yaml",
                    "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                    "dictionaryVersion": "1.0",
                    "retrievedAt": "2026-01-01T00:00:00Z",
                }
            ),
            encoding="utf-8",
        )
        return source, manifest

    def build(self, body, header=HEADER):
        source, manifest = self.write_dictionary(body, header)
        output = self.directory / "out.sqlite3"
        report = self.directory / "report.json"
        build_database(source, manifest, output, report)
        return output, json.loads(report.read_text(encoding="utf-8"))

    def assert_build_fails(self, body, header=HEADER):
        source, manifest = self.write_dictionary(body, header)
        with self.assertRaises(CompileFailure) as context:
            build_database(source, manifest, self.directory / "out.sqlite3", self.directory / "report.json")
        return str(context.exception)

    def query(self, database, sql):
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        try:
            return connection.execute(sql).fetchall()
        finally:
            connection.close()

    def database_snapshot(self, database):
        """Return logical content without depending on SQLite page layout."""
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        try:
            schema = connection.execute(
                "SELECT type, name, tbl_name, sql FROM sqlite_master "
                "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
            ).fetchall()
            return {
                "user_version": connection.execute("PRAGMA user_version").fetchone()[0],
                "schema": schema,
                "metadata": connection.execute(
                    "SELECT key, value FROM metadata ORDER BY key"
                ).fetchall(),
                "inventory": connection.execute(
                    "SELECT base FROM syllable_inventory ORDER BY base"
                ).fetchall(),
                "pronunciation": connection.execute(
                    "SELECT id, text, syllable_count, base_key, tone_key, "
                    "source_weight, source_line FROM pronunciation ORDER BY id"
                ).fetchall(),
                "integrity": connection.execute("PRAGMA integrity_check").fetchone()[0],
            }
        finally:
            connection.close()


class ParsingTests(CompilerTestCase):
    def test_header_comments_and_blank_lines(self):
        body = "\n# comment\n中\tzhong1\n\n# another\n文\twen2\n"
        parsed = parse_dictionary(self.write_dictionary(body)[0])
        self.assertEqual(parsed.errors, ())
        self.assertEqual([entry.text for entry in parsed.entries], ["中", "文"])
        self.assertEqual(parsed.header["name"], "test_dict")
        self.assertEqual(parsed.header["version"], "1.0")

    def test_two_and_three_column_rows(self):
        output, report = self.build("中\tzhong1\n文\twen2\t97%\n")
        rows = self.query(output, "SELECT text, syllable_count, base_key, tone_key, source_weight FROM pronunciation")
        by_text = {row[0]: row for row in rows}
        self.assertEqual(by_text["中"][4], None)
        self.assertEqual(by_text["文"][4], 0.97)
        self.assertEqual(report["weightedEntries"], 1)

    def test_percentage_weight_normalization(self):
        output, _ = self.build("好\thao3\t33.33%\n壞\thuai4\t0%\n")
        weights = dict(self.query(output, "SELECT text, source_weight FROM pronunciation"))
        self.assertAlmostEqual(weights["好"], 0.3333)
        self.assertEqual(weights["壞"], 0.0)

    def test_missing_header_terminator(self):
        source = self.directory / "broken.dict.yaml"
        source.write_text("---\nname: broken\nversion: \"1\"\n中\tzhong1\n", encoding="utf-8")
        parsed = parse_dictionary(source)
        self.assertEqual(len(parsed.errors), 1)
        self.assertIn("...", parsed.errors[0])

    def test_invalid_rows_are_reported(self):
        message = self.assert_build_fails(
            "中\tzhong1\n"
            "empty\t\n"
            "\tzhong1\n"
            "weight\tzhong1\t12\n"
            "many\tzhong1\t50%\textra\n"
            "   \n"
        )
        self.assertIn("line 8", message)
        self.assertIn("empty code", message)
        self.assertIn("line 9", message)
        self.assertIn("empty text", message)
        self.assertIn("line 10", message)
        self.assertIn("invalid weight", message)
        self.assertIn("line 11", message)
        self.assertIn("expected 2 or 3", message)

    def test_unknown_pinyin_reports_source_line(self):
        message = self.assert_build_fails("中\tzhong1\n怪\tzzong1\n")
        self.assertIn(":8:", message)
        self.assertIn("zzong", message)


class CompilationTests(CompilerTestCase):
    def test_polyphones_and_duplicates(self):
        body = "中\tzhong1\n中\tzhong4\n好\thao3\t50%\n好\thao4\t20%\n"
        output, report = self.build(body)
        self.assertEqual(report["sourceEntries"], 4)
        self.assertEqual(report["compiledEntries"], 4)
        self.assertEqual(report["duplicateEntries"], 0)

    def test_identical_pronunciation_deduplicates(self):
        body = "好\thao3\t50%\n好\thao3\t20%\n好\thao3\n"
        output, report = self.build(body)
        self.assertEqual(report["compiledEntries"], 1)
        self.assertEqual(report["duplicateEntries"], 2)
        rows = self.query(output, "SELECT text, source_weight FROM pronunciation")
        self.assertEqual(rows, [("好", 0.5)])
        self.assertEqual(len(report["duplicateWeightConflicts"]), 1)
        self.assertEqual(report["duplicateWeightConflicts"][0]["keptWeight"], 0.5)

    def test_distinct_pronunciations_are_kept(self):
        output, report = self.build("中\tzhong1\n中\tzhong4\n")
        rows = self.query(output, "SELECT tone_key FROM pronunciation ORDER BY tone_key")
        self.assertEqual([row[0] for row in rows], ["1", "4"])

    def test_base_and_tone_keys(self):
        output, _ = self.build("中文\tzhong1 wen2\n")
        row = self.query(output, "SELECT base_key, tone_key, syllable_count FROM pronunciation")[0]
        self.assertEqual(row[0], "ㄓㄨㄥ\u001fㄨㄣ")
        self.assertEqual(row[1], "12")
        self.assertEqual(row[2], 2)

    def test_metadata_and_inventory(self):
        output, report = self.build("中\tzhong1\n文\twen2\n")
        metadata = dict(self.query(output, "SELECT key, value FROM metadata"))
        self.assertEqual(metadata["schema_version"], "1")
        self.assertEqual(metadata["source_commit"], "0" * 40)
        self.assertEqual(metadata["entry_count"], str(report["compiledEntries"]))
        self.assertEqual(metadata["dictionary_version"], "1.0")
        inventory = [row[0] for row in self.query(output, "SELECT base FROM syllable_inventory ORDER BY base")]
        self.assertEqual(inventory, sorted({"ㄓㄨㄥ", "ㄨㄣ"}))
        self.assertEqual(self.query(output, "PRAGMA user_version")[0][0], 1)
        self.assertEqual(self.query(output, "PRAGMA page_size")[0][0], 4096)

    def test_sha256_mismatch_blocks_build(self):
        source, manifest = self.write_dictionary("中\tzhong1\n")
        source.write_text(source.read_text(encoding="utf-8") + "文\twen2\n", encoding="utf-8")
        with self.assertRaises(CompileFailure) as context:
            build_database(source, manifest, self.directory / "out.sqlite3", self.directory / "report.json")
        self.assertIn("sha256 mismatch", str(context.exception))

    def test_build_is_byte_for_byte_reproducible(self):
        body = "中\tzhong1\n中\tzhong4\n中文\tzhong1 wen2\t97%\n你好\tni3 hao3\n"
        source, manifest = self.write_dictionary(body)
        first = self.directory / "first.sqlite3"
        second = self.directory / "second.sqlite3"
        build_database(source, manifest, first, self.directory / "first.json")
        build_database(source, manifest, second, self.directory / "second.json")
        self.assertEqual(hashlib.sha256(first.read_bytes()).hexdigest(), hashlib.sha256(second.read_bytes()).hexdigest())
        self.assertEqual(
            (self.directory / "first.json").read_text(encoding="utf-8"),
            (self.directory / "second.json").read_text(encoding="utf-8"),
        )

    def test_rows_are_inserted_in_sorted_order(self):
        output, _ = self.build("文\twen2\n中\tzhong4\n中\tzhong1\n")
        rows = self.query(output, "SELECT base_key, tone_key, text FROM pronunciation")
        self.assertEqual(rows, sorted(rows))

    def test_main_returns_non_zero_on_unknown_pinyin(self):
        source, manifest = self.write_dictionary("怪\tzzong1\n")
        exit_code = main(
            [
                "build",
                "--source",
                str(source),
                "--manifest",
                str(manifest),
                "--output",
                str(self.directory / "out.sqlite3"),
                "--report",
                str(self.directory / "report.json"),
            ]
        )
        self.assertEqual(exit_code, 1)
        self.assertFalse((self.directory / "out.sqlite3").exists())


class FixtureTests(CompilerTestCase):
    def test_committed_swift_fixture_is_current(self):
        fixture_source = FIXTURES / "zhuyin_tests.dict.yaml"
        fixture_manifest = FIXTURES / "zhuyin_tests.SOURCE.json"
        committed = REPOSITORY / "FlickZhuyinTests" / "Fixtures" / "flickzhuyin-tests.sqlite3"
        output = self.directory / "fixture.sqlite3"
        build_database(fixture_source, fixture_manifest, output, self.directory / "fixture.json")
        if not committed.exists():
            self.fail("run the fixture build command to generate FlickZhuyinTests/Fixtures/flickzhuyin-tests.sqlite3")
        self.assertEqual(self.database_snapshot(output), self.database_snapshot(committed))


@unittest.skipUnless(PRODUCTION_SOURCE.exists(), "production dictionary is not vendored")
class ProductionDictionaryTests(CompilerTestCase):
    def test_full_corpus_converts_and_rebuilds(self):
        parsed = parse_dictionary(PRODUCTION_SOURCE)
        self.assertEqual(parsed.errors, ())
        syllables = {syllable for entry in parsed.entries for syllable in entry.pinyin_syllables}
        self.assertGreater(len(syllables), 1000)
        for syllable in syllables:
            convert_syllable(syllable)
        inventory = {convert_syllable(syllable).base for syllable in syllables}
        report = json.loads((REPOSITORY / "Generated" / "dictionary-report.json").read_text(encoding="utf-8"))
        self.assertEqual(report["errors"], [])
        self.assertGreaterEqual(report["distinctZhuyinSyllables"], len(inventory))

    def test_production_build_is_deterministic(self):
        first = self.directory / "first.sqlite3"
        second = self.directory / "second.sqlite3"
        build_database(PRODUCTION_SOURCE, PRODUCTION_MANIFEST, first, self.directory / "first.json")
        build_database(PRODUCTION_SOURCE, PRODUCTION_MANIFEST, second, self.directory / "second.json")
        self.assertEqual(
            hashlib.sha256(first.read_bytes()).hexdigest(),
            hashlib.sha256(second.read_bytes()).hexdigest(),
        )


if __name__ == "__main__":
    unittest.main()
