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
    normalize_frequency,
    parse_dictionary,
    parse_essay,
)
from pinyin_to_zhuyin import convert_syllable  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"
REPOSITORY = Path(__file__).resolve().parents[3]
PRODUCTION_TERRA_SOURCE = REPOSITORY / "Vendor" / "rime-terra-pinyin" / "terra_pinyin.dict.yaml"
PRODUCTION_TERRA_MANIFEST = REPOSITORY / "Vendor" / "rime-terra-pinyin" / "SOURCE.json"
PRODUCTION_ESSAY_SOURCE = REPOSITORY / "Vendor" / "rime-essay" / "essay.txt"
PRODUCTION_ESSAY_MANIFEST = REPOSITORY / "Vendor" / "rime-essay" / "SOURCE.json"
PRODUCTION_DATABASE = REPOSITORY / "Generated" / "flickzhuyin.sqlite3"
PRODUCTION_REPORT = REPOSITORY / "Generated" / "dictionary-report.json"

HEADER = 'name: test_dict\nversion: "1.0"\nsort: by_weight\nuse_preset_vocabulary: true\n'
SEPARATOR = "\u001f"


class CompilerTestCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def write_license(self):
        license_path = self.directory / "LICENSE"
        license_path.write_text("Fixture license for dictionary compiler tests.\n", encoding="utf-8")
        return license_path

    def write_dictionary(self, body, header=HEADER):
        license_path = self.write_license()
        source = self.directory / "test.dict.yaml"
        source.write_text(f"---\n{header}...\n{body}", encoding="utf-8")
        manifest = self.directory / "terra.SOURCE.json"
        manifest.write_text(
            json.dumps(
                {
                    "repository": "https://example.invalid/terra",
                    "commit": "0" * 40,
                    "dictionaryPath": "test.dict.yaml",
                    "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                    "licensePath": license_path.name,
                    "licenseSha256": hashlib.sha256(license_path.read_bytes()).hexdigest(),
                    "dictionaryVersion": "1.0",
                    "retrievedAt": "2026-01-01T00:00:00Z",
                }
            ),
            encoding="utf-8",
        )
        return source, manifest

    def write_essay(self, body):
        license_path = self.write_license()
        source = self.directory / "test.essay.txt"
        source.write_text(body, encoding="utf-8")
        parsed = parse_essay(source)
        manifest = self.directory / "essay.SOURCE.json"
        manifest.write_text(
            json.dumps(
                {
                    "repository": "https://example.invalid/essay",
                    "commit": "1" * 40,
                    "essayPath": "test.essay.txt",
                    "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                    "licensePath": license_path.name,
                    "licenseSha256": hashlib.sha256(license_path.read_bytes()).hexdigest(),
                    "formatVersion": 1,
                    "entryCount": len(parsed.entries),
                    "frequencyMax": max((entry.frequency for entry in parsed.entries), default=0),
                    "retrievedAt": "2026-01-01T00:00:00Z",
                }
            ),
            encoding="utf-8",
        )
        return source, manifest

    def build(self, body, essay_body="", header=HEADER):
        source, manifest = self.write_dictionary(body, header)
        essay_source, essay_manifest = self.write_essay(essay_body)
        return self.build_with(source, manifest, essay_source, essay_manifest)

    def build_with(self, source, manifest, essay_source, essay_manifest, name="out"):
        output = self.directory / f"{name}.sqlite3"
        report = self.directory / f"{name}.json"
        build_database(source, manifest, essay_source, essay_manifest, output, report)
        return output, json.loads(report.read_text(encoding="utf-8"))

    def assert_build_fails(self, body, essay_body="", header=HEADER):
        source, manifest = self.write_dictionary(body, header)
        essay_source, essay_manifest = self.write_essay(essay_body)
        with self.assertRaises(CompileFailure) as context:
            build_database(
                source,
                manifest,
                essay_source,
                essay_manifest,
                self.directory / "out.sqlite3",
                self.directory / "report.json",
            )
        return str(context.exception)

    def query(self, database, sql):
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        try:
            return connection.execute(sql).fetchall()
        finally:
            connection.close()

    def database_snapshot(self, database):
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
                    "SELECT id, text, syllable_count, base_key, tone_key, initial_key, source_weight, "
                    "source_kind, terra_source_line, terra_source_lines, essay_source_line, raw_frequency "
                    "FROM pronunciation ORDER BY id"
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


class EssayParsingTests(CompilerTestCase):
    def test_comments_blank_lines_and_entries(self):
        essay, _ = self.write_essay("\n# comment\n你好\t100\n\n   \n世界\t0\n")
        parsed = parse_essay(essay)
        self.assertEqual(parsed.errors, ())
        self.assertEqual([(entry.text, entry.frequency) for entry in parsed.entries], [("你好", 100), ("世界", 0)])

    def test_invalid_rows_are_reported_with_line_numbers(self):
        essay, _ = self.write_essay("你好\t100\n壞\t-1\n空\t\n\t12\n太多\ta\tb\n")
        parsed = parse_essay(essay)
        self.assertEqual([entry.text for entry in parsed.entries], ["你好"])
        self.assertEqual(len(parsed.errors), 4)
        self.assertIn(":2:", parsed.errors[0])
        self.assertIn("invalid frequency", parsed.errors[0])
        self.assertIn(":3:", parsed.errors[1])
        self.assertIn("invalid frequency", parsed.errors[1])
        self.assertIn(":4:", parsed.errors[2])
        self.assertIn("empty text", parsed.errors[2])
        self.assertIn(":5:", parsed.errors[3])
        self.assertIn("expected 2", parsed.errors[3])

    def test_frequency_out_of_range_is_rejected(self):
        essay, _ = self.write_essay(f"大\t{2**63}\n")
        parsed = parse_essay(essay)
        self.assertEqual(parsed.entries, ())
        self.assertIn("out of range", parsed.errors[0])

    def test_duplicate_texts_merge_to_highest_frequency(self):
        output, report = self.build("中\tzhong1\n", essay_body="中\t10\n中\t99\n中\t5\n")
        self.assertEqual(report["duplicateEssayEntries"], 2)
        rows = self.query(
            output,
            "SELECT raw_frequency, source_kind FROM pronunciation WHERE text = '中'",
        )
        self.assertEqual(rows, [(99, "terra+essay")])

    def test_invalid_essay_fails_build(self):
        message = self.assert_build_fails("中\tzhong1\n", essay_body="中\tzhong1\n")
        self.assertIn("invalid frequency", message)

    def test_essay_sha256_mismatch_fails(self):
        source, manifest = self.write_dictionary("中\tzhong1\n")
        essay_source, essay_manifest = self.write_essay("中\t10\n")
        essay_source.write_text("中\t11\n", encoding="utf-8")
        with self.assertRaises(CompileFailure) as context:
            build_database(
                source,
                manifest,
                essay_source,
                essay_manifest,
                self.directory / "out.sqlite3",
                self.directory / "report.json",
            )
        self.assertIn("sha256 mismatch", str(context.exception))

    def test_manifest_commit_must_be_pinned(self):
        source, manifest = self.write_dictionary("中\tzhong1\n")
        essay_source, essay_manifest = self.write_essay("")
        body = json.loads(manifest.read_text(encoding="utf-8"))
        body["commit"] = "master"
        manifest.write_text(json.dumps(body), encoding="utf-8")
        with self.assertRaises(CompileFailure) as context:
            build_database(
                source,
                manifest,
                essay_source,
                essay_manifest,
                self.directory / "out.sqlite3",
                self.directory / "report.json",
            )
        self.assertIn("40-character lowercase hex", str(context.exception))

    def test_unsupported_essay_format_version_fails(self):
        source, manifest = self.write_dictionary("中\tzhong1\n")
        essay_source, essay_manifest = self.write_essay("中\t10\n")
        body = json.loads(essay_manifest.read_text(encoding="utf-8"))
        body["formatVersion"] = 99
        essay_manifest.write_text(json.dumps(body), encoding="utf-8")
        with self.assertRaises(CompileFailure) as context:
            build_database(
                source,
                manifest,
                essay_source,
                essay_manifest,
                self.directory / "out.sqlite3",
                self.directory / "report.json",
            )
        self.assertIn("unsupported essay formatVersion", str(context.exception))

    def test_license_sha256_mismatch_fails(self):
        source, manifest = self.write_dictionary("中\tzhong1\n")
        essay_source, essay_manifest = self.write_essay("中\t10\n")
        (self.directory / "LICENSE").write_text("not the licensed text", encoding="utf-8")
        body = json.loads(essay_manifest.read_text(encoding="utf-8"))
        body["licenseSha256"] = "f" * 64
        essay_manifest.write_text(json.dumps(body), encoding="utf-8")
        with self.assertRaises(CompileFailure) as context:
            build_database(
                source,
                manifest,
                essay_source,
                essay_manifest,
                self.directory / "out.sqlite3",
                self.directory / "report.json",
            )
        self.assertIn("license sha256 mismatch", str(context.exception))

    def test_license_metadata_is_required(self):
        source, manifest = self.write_dictionary("中\tzhong1\n")
        essay_source, essay_manifest = self.write_essay("中\t10\n")
        body = json.loads(essay_manifest.read_text(encoding="utf-8"))
        body.pop("licenseSha256")
        essay_manifest.write_text(json.dumps(body), encoding="utf-8")
        with self.assertRaises(CompileFailure) as context:
            build_database(
                source,
                manifest,
                essay_source,
                essay_manifest,
                self.directory / "out.sqlite3",
                self.directory / "report.json",
            )
        self.assertIn("licenseSha256", str(context.exception))

    def test_manifest_statistics_must_match_essay(self):
        source, manifest = self.write_dictionary("中\tzhong1\n")
        essay_source, essay_manifest = self.write_essay("中\t10\n")
        body = json.loads(essay_manifest.read_text(encoding="utf-8"))
        body["entryCount"] = 99
        essay_manifest.write_text(json.dumps(body), encoding="utf-8")
        with self.assertRaises(CompileFailure) as context:
            build_database(
                source,
                manifest,
                essay_source,
                essay_manifest,
                self.directory / "out.sqlite3",
                self.directory / "report.json",
            )
        self.assertIn("entryCount", str(context.exception))


class AnnotationTests(CompilerTestCase):
    def test_terra_explicit_pronunciation_takes_priority(self):
        body = "中文\tzhong1 wen2\t97%\n中\tzhong4\n文\twen2\n"
        output, report = self.build(body, essay_body="中文\t1000\n")
        rows = self.query(
            output,
            "SELECT tone_key, source_weight, source_kind, terra_source_line, essay_source_line, raw_frequency "
            "FROM pronunciation WHERE text = '中文'",
        )
        self.assertEqual(len(rows), 1)
        tone_key, weight, kind, terra_line, essay_line, frequency = rows[0]
        self.assertEqual(tone_key, "12")
        self.assertEqual(kind, "terra+essay")
        self.assertEqual(weight, 1.0)
        self.assertEqual(frequency, 1000)
        self.assertIsNotNone(terra_line)
        self.assertIsNotNone(essay_line)
        self.assertEqual(report["essayExplicitEntries"], 1)
        self.assertEqual(report["essayComposedEntries"], 0)
        self.assertEqual(report["mergedTerraEssayEntries"], 1)

    def test_single_character_composition(self):
        output, report = self.build("甲\tjia3\n文\twen2\n", essay_body="甲文\t100\n")
        rows = self.query(
            output,
            "SELECT base_key, tone_key, source_kind, terra_source_lines, essay_source_line, raw_frequency "
            "FROM pronunciation WHERE text = '甲文'",
        )
        self.assertEqual(
            rows,
            [(SEPARATOR.join(["ㄐㄧㄚ", "ㄨㄣ"]), "32", "essay", "[7,8]", 1, 100)],
        )
        self.assertEqual(report["essayComposedEntries"], 1)
        self.assertEqual(report["generatedPronunciations"], 1)

    def test_polyphone_generates_multiple_pronunciations(self):
        body = "中\tzhong1\t50%\n中\tzhong4\t30%\n"
        output, report = self.build(body, essay_body="中中\t100\n")
        rows = self.query(output, "SELECT tone_key FROM pronunciation WHERE text = '中中' ORDER BY tone_key")
        self.assertEqual([row[0] for row in rows], ["11", "14", "41", "44"])
        self.assertEqual(report["generatedPronunciations"], 4)
        self.assertEqual(report["essayTruncatedEntries"], 0)

    def test_combination_limit_truncates_stably(self):
        body = "".join(f"中\tzhong{tone}\t5%\n" for tone in range(1, 6))
        first, first_report = self.build(body, essay_body="中中\t100\n")
        second, second_report = self.build(body, essay_body="中中\t100\n", header=HEADER)
        rows = self.query(first, "SELECT tone_key FROM pronunciation WHERE text = '中中'")
        self.assertEqual(len(rows), 16)
        self.assertEqual(first_report["essayTruncatedEntries"], 1)
        self.assertEqual(first_report["generatedPronunciations"], 16)
        self.assertEqual(len(first_report["truncatedExamples"]), 1)
        self.assertEqual(first_report["truncatedExamples"][0]["retained"], 16)
        self.assertEqual(
            self.database_snapshot(first)["pronunciation"],
            self.database_snapshot(second)["pronunciation"],
        )

    def test_unannotated_entries_are_reported(self):
        output, report = self.build("中\tzhong1\n", essay_body="中文\t5\n中\t3\n")
        self.assertEqual(report["essayUnannotatedEntries"], 1)
        self.assertEqual(report["unannotatedExamples"][0]["text"], "中文")
        self.assertEqual(report["unannotatedExamples"][0]["missingCharacters"], "文")
        self.assertEqual(report["essayAnnotatedEntries"], 1)

    def test_oversized_entries_are_skipped(self):
        body = "中\tzhong1\n"
        output, report = self.build(body, essay_body=f"{'中' * 17}\t9\n")
        self.assertEqual(report["essayOversizedEntries"], 1)
        self.assertEqual(report["oversizedExamples"][0]["length"], 17)
        self.assertEqual(report["generatedPronunciations"], 0)


class NormalizationTests(unittest.TestCase):
    def test_boundaries(self):
        self.assertEqual(normalize_frequency(0, 100), 0.0)
        self.assertEqual(normalize_frequency(100, 100), 1.0)
        self.assertEqual(normalize_frequency(50, 0), 0.0)
        self.assertEqual(normalize_frequency(-5, 100), 0.0)

    def test_monotonicity_and_range(self):
        previous = -1.0
        for frequency in (1, 2, 10, 99, 100):
            value = normalize_frequency(frequency, 100)
            self.assertGreater(value, previous)
            self.assertGreaterEqual(value, 0.0)
            self.assertLessEqual(value, 1.0)
            previous = value


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
        row = self.query(output, "SELECT base_key, tone_key, initial_key, syllable_count FROM pronunciation")[0]
        self.assertEqual(row[0], "ㄓㄨㄥ\u001fㄨㄣ")
        self.assertEqual(row[1], "12")
        self.assertEqual(row[2], "\u001f".join(["ㄓ", "ㄨ"]))
        self.assertEqual(row[3], 2)

    def test_initial_keys_for_single_and_multi_syllable_readings(self):
        output, _ = self.build(
            "爸爸\tba4 ba5\n注音\tzhu4 yin1\n中\tzhong1\n",
        )
        rows = self.query(output, "SELECT text, initial_key, syllable_count FROM pronunciation ORDER BY text")
        self.assertEqual(
            rows,
            [
                ("中", "ㄓ", 1),
                ("注音", "\u001f".join(["ㄓ", "ㄧ"]), 2),
                ("爸爸", "\u001f".join(["ㄅ", "ㄅ"]), 2),
            ],
        )

    def test_initial_key_segments_match_syllable_count(self):
        output, report = self.build(
            "你好\tni3 hao3\n中國\tzhong1 guo2\n中\tzhong1\n",
            essay_body="你好\t100\n",
        )
        rows = self.query(output, "SELECT initial_key, syllable_count FROM pronunciation")
        self.assertFalse(rows == [])
        for initial_key, syllable_count in rows:
            segments = initial_key.split(SEPARATOR)
            self.assertEqual(len(segments), syllable_count)
            self.assertTrue(all(len(segment) == 1 for segment in segments))
        self.assertEqual(report["initialKeyIntegrity"]["checkedEntries"], len(rows))
        self.assertEqual(report["initialKeyIntegrity"]["syllableCountMismatches"], 0)
        self.assertGreater(report["distinctInitialKeys"], 0)

    def test_schema_creates_initial_key_index(self):
        output, _ = self.build("中文\tzhong1 wen2\n")
        indexes = dict(
            self.query(
                output,
                "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'pronunciation'",
            )
        )
        self.assertIn("pronunciation_initial_key", indexes)
        self.assertIn("initial_key", indexes["pronunciation_initial_key"])
        plan = self.query(
            output,
            "EXPLAIN QUERY PLAN SELECT text, tone_key, source_weight FROM pronunciation "
            "WHERE initial_key = 'x' AND syllable_count = 2",
        )
        detail = " ".join(str(row[-1]) for row in plan).lower()
        self.assertIn("pronunciation_initial_key", detail)
        self.assertIn("search", detail)

    def test_terra_only_rows_keep_terra_weight(self):
        output, _ = self.build("中\tzhong1\t42%\n")
        rows = self.query(
            output,
            "SELECT source_weight, source_kind, terra_source_line, essay_source_line, raw_frequency "
            "FROM pronunciation",
        )
        self.assertEqual(rows, [(0.42, "terra", 7, None, None)])

    def test_essay_weight_overrides_terra_weight(self):
        output, _ = self.build("中\tzhong1\t42%\n", essay_body="中\t100\n")
        rows = self.query(
            output,
            "SELECT source_weight, source_kind, essay_source_line, raw_frequency FROM pronunciation",
        )
        self.assertEqual(rows, [(1.0, "terra+essay", 1, 100)])

    def test_metadata_and_inventory(self):
        output, report = self.build("中\tzhong1\n文\twen2\n", essay_body="中文\t100\n")
        metadata = dict(self.query(output, "SELECT key, value FROM metadata"))
        self.assertEqual(metadata["schema_version"], "3")
        self.assertEqual(metadata["terra_source_commit"], "0" * 40)
        self.assertEqual(metadata["terra_source_sha256"], report["sources"]["terra"]["sha256"])
        self.assertEqual(metadata["essay_source_commit"], "1" * 40)
        self.assertEqual(metadata["essay_source_sha256"], report["sources"]["essay"]["sha256"])
        self.assertEqual(metadata["entry_count"], str(report["compiledEntries"]))
        self.assertEqual(metadata["dictionary_version"], "1.0")
        self.assertEqual(metadata["compiler_version"], "3")
        self.assertEqual(metadata["essay_entry_count"], "1")
        self.assertEqual(metadata["essay_annotated_entry_count"], "1")
        self.assertEqual(metadata["essay_frequency_max"], "100")
        self.assertEqual(metadata["weight_normalization"], "log1p(frequency)/log1p(max_frequency)")
        self.assertEqual(report["schemaVersion"], 3)
        self.assertEqual(report["compilerVersion"], "3")
        inventory = [row[0] for row in self.query(output, "SELECT base FROM syllable_inventory ORDER BY base")]
        self.assertEqual(inventory, sorted({"ㄓㄨㄥ", "ㄨㄣ"}))
        self.assertEqual(self.query(output, "PRAGMA user_version")[0][0], 3)
        self.assertEqual(self.query(output, "PRAGMA page_size")[0][0], 4096)
        self.assertEqual(self.query(output, "PRAGMA integrity_check")[0][0], "ok")

    def test_sha256_mismatch_blocks_build(self):
        source, manifest = self.write_dictionary("中\tzhong1\n")
        essay_source, essay_manifest = self.write_essay("")
        source.write_text(source.read_text(encoding="utf-8") + "文\twen2\n", encoding="utf-8")
        with self.assertRaises(CompileFailure) as context:
            build_database(
                source,
                manifest,
                essay_source,
                essay_manifest,
                self.directory / "out.sqlite3",
                self.directory / "report.json",
            )
        self.assertIn("sha256 mismatch", str(context.exception))

    def test_build_is_byte_for_byte_reproducible(self):
        body = "中\tzhong1\n中\tzhong4\n中文\tzhong1 wen2\t97%\n你好\tni3 hao3\n"
        source, manifest = self.write_dictionary(body)
        essay_source, essay_manifest = self.write_essay("中\t10\n你好\t500\n")
        first = self.directory / "first.sqlite3"
        second = self.directory / "second.sqlite3"
        _, first_report = self.build_with(source, manifest, essay_source, essay_manifest, name="first")
        _, second_report = self.build_with(source, manifest, essay_source, essay_manifest, name="second")
        self.assertEqual(
            hashlib.sha256(first.read_bytes()).hexdigest(),
            hashlib.sha256(second.read_bytes()).hexdigest(),
        )
        self.assertEqual(first_report, second_report)

    def test_rows_are_inserted_in_sorted_order(self):
        output, _ = self.build("文\twen2\n中\tzhong4\n中\tzhong1\n")
        rows = self.query(output, "SELECT base_key, tone_key, text FROM pronunciation")
        self.assertEqual(rows, sorted(rows))

    def test_main_returns_non_zero_on_unknown_pinyin(self):
        source, manifest = self.write_dictionary("怪\tzzong1\n")
        essay_source, essay_manifest = self.write_essay("")
        exit_code = main(
            [
                "build",
                "--terra-source",
                str(source),
                "--terra-manifest",
                str(manifest),
                "--essay-source",
                str(essay_source),
                "--essay-manifest",
                str(essay_manifest),
                "--output",
                str(self.directory / "out.sqlite3"),
                "--report",
                str(self.directory / "report.json"),
            ]
        )
        self.assertEqual(exit_code, 1)
        self.assertFalse((self.directory / "out.sqlite3").exists())

    def test_main_returns_non_zero_on_invalid_essay(self):
        source, manifest = self.write_dictionary("中\tzhong1\n")
        essay_source, essay_manifest = self.write_essay("壞\tnot-a-number\n")
        exit_code = main(
            [
                "build",
                "--terra-source",
                str(source),
                "--terra-manifest",
                str(manifest),
                "--essay-source",
                str(essay_source),
                "--essay-manifest",
                str(essay_manifest),
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
        fixture_essay = FIXTURES / "zhuyin_tests.essay.txt"
        fixture_essay_manifest = FIXTURES / "zhuyin_tests.essay.SOURCE.json"
        committed = REPOSITORY / "FlickZhuyinTests" / "Fixtures" / "flickzhuyin-tests.sqlite3"
        output = self.directory / "fixture.sqlite3"
        build_database(
            fixture_source,
            fixture_manifest,
            fixture_essay,
            fixture_essay_manifest,
            output,
            self.directory / "fixture.json",
        )
        if not committed.exists():
            self.fail("run the fixture build command to generate FlickZhuyinTests/Fixtures/flickzhuyin-tests.sqlite3")
        self.assertEqual(self.database_snapshot(output), self.database_snapshot(committed))


@unittest.skipUnless(
    PRODUCTION_TERRA_SOURCE.exists() and PRODUCTION_ESSAY_SOURCE.exists(),
    "production sources are not vendored",
)
class ProductionDictionaryTests(CompilerTestCase):
    def test_full_corpus_converts_and_rebuilds(self):
        parsed_terra = parse_dictionary(PRODUCTION_TERRA_SOURCE)
        parsed_essay = parse_essay(PRODUCTION_ESSAY_SOURCE)
        self.assertEqual(parsed_terra.errors, ())
        self.assertEqual(parsed_essay.errors, ())
        self.assertGreater(len(parsed_essay.entries), 400_000)
        syllables = {
            syllable for entry in parsed_terra.entries for syllable in entry.pinyin_syllables
        }
        self.assertGreater(len(syllables), 1000)
        for syllable in syllables:
            convert_syllable(syllable)
        inventory = {convert_syllable(syllable).base for syllable in syllables}
        report = json.loads(PRODUCTION_REPORT.read_text(encoding="utf-8"))
        self.assertEqual(report["errors"], [])
        self.assertEqual(report["essayEntries"], len(parsed_essay.entries))
        self.assertGreater(report["essayAnnotatedEntries"], 400_000)
        self.assertGreaterEqual(report["distinctZhuyinSyllables"], len(inventory))
        self.assertLessEqual(report["database"]["bytes"], report["database"]["limitBytes"])

    def test_production_build_is_deterministic(self):
        first = self.directory / "first.sqlite3"
        second = self.directory / "second.sqlite3"
        _, first_report = self.build_with(
            PRODUCTION_TERRA_SOURCE,
            PRODUCTION_TERRA_MANIFEST,
            PRODUCTION_ESSAY_SOURCE,
            PRODUCTION_ESSAY_MANIFEST,
            name="first",
        )
        _, second_report = self.build_with(
            PRODUCTION_TERRA_SOURCE,
            PRODUCTION_TERRA_MANIFEST,
            PRODUCTION_ESSAY_SOURCE,
            PRODUCTION_ESSAY_MANIFEST,
            name="second",
        )
        self.assertEqual(
            hashlib.sha256(first.read_bytes()).hexdigest(),
            hashlib.sha256(second.read_bytes()).hexdigest(),
        )
        self.assertEqual(first_report, second_report)

    def test_metadata_matches_both_manifests(self):
        terra_manifest = json.loads(PRODUCTION_TERRA_MANIFEST.read_text(encoding="utf-8"))
        essay_manifest = json.loads(PRODUCTION_ESSAY_MANIFEST.read_text(encoding="utf-8"))
        metadata = dict(self.query(PRODUCTION_DATABASE, "SELECT key, value FROM metadata"))
        self.assertEqual(metadata["schema_version"], "3")
        self.assertEqual(metadata["compiler_version"], "3")
        self.assertEqual(metadata["terra_source_repository"], terra_manifest["repository"])
        self.assertEqual(metadata["terra_source_commit"], terra_manifest["commit"])
        self.assertEqual(metadata["terra_source_sha256"], terra_manifest["sha256"])
        self.assertEqual(metadata["essay_source_repository"], essay_manifest["repository"])
        self.assertEqual(metadata["essay_source_commit"], essay_manifest["commit"])
        self.assertEqual(metadata["essay_source_sha256"], essay_manifest["sha256"])
        self.assertEqual(metadata["essay_entry_count"], str(essay_manifest["entryCount"]))
        self.assertEqual(metadata["essay_frequency_max"], str(essay_manifest["frequencyMax"]))
        self.assertEqual(metadata["weight_normalization"], "log1p(frequency)/log1p(max_frequency)")
        self.assertEqual(self.query(PRODUCTION_DATABASE, "PRAGMA integrity_check")[0][0], "ok")

    def test_representative_words_are_weighted(self):
        zhuyin = self.query(
            PRODUCTION_DATABASE,
            "SELECT base_key, tone_key, initial_key, source_weight, source_kind, raw_frequency "
            "FROM pronunciation WHERE text = '注音'",
        )
        self.assertEqual(len(zhuyin), 1)
        self.assertEqual(zhuyin[0][0], SEPARATOR.join(["ㄓㄨ", "ㄧㄣ"]))
        self.assertEqual(zhuyin[0][1], "41")
        self.assertEqual(zhuyin[0][2], SEPARATOR.join(["ㄓ", "ㄧ"]))
        self.assertIsNotNone(zhuyin[0][3])
        self.assertEqual(zhuyin[0][4], "essay")
        self.assertIsNotNone(zhuyin[0][5])
        nihao = self.query(
            PRODUCTION_DATABASE,
            "SELECT COUNT(*) FROM pronunciation WHERE text = '你好' AND source_weight IS NOT NULL",
        )
        self.assertGreater(nihao[0][0], 0)
        missing_weights = self.query(
            PRODUCTION_DATABASE,
            "SELECT COUNT(*) FROM pronunciation WHERE source_kind != 'terra' AND source_weight IS NULL",
        )
        self.assertEqual(missing_weights[0][0], 0)

    def test_all_rows_are_well_formed(self):
        rows = self.query(
            PRODUCTION_DATABASE,
            "SELECT base_key, tone_key, initial_key, syllable_count FROM pronunciation",
        )
        self.assertFalse(rows == [])
        for base_key, tone_key, initial_key, syllable_count in rows:
            bases = base_key.split(SEPARATOR)
            self.assertEqual(len(bases), syllable_count)
            self.assertTrue(all(bases))
            self.assertEqual(len(tone_key), syllable_count)
            self.assertTrue(all(character in "12345" for character in tone_key))
            initials = initial_key.split(SEPARATOR)
            self.assertEqual(len(initials), syllable_count)
            self.assertTrue(all(len(initial) == 1 for initial in initials))
            self.assertEqual(initials, [base[0] for base in bases])

    def test_lookup_uses_index(self):
        plan = self.query(
            PRODUCTION_DATABASE,
            "EXPLAIN QUERY PLAN SELECT text, tone_key, source_weight FROM pronunciation "
            "WHERE base_key = 'x' AND syllable_count = 2",
        )
        detail = " ".join(str(row[-1]) for row in plan).lower()
        self.assertIn("pronunciation_base_key", detail)
        self.assertIn("search", detail)

        initial_plan = self.query(
            PRODUCTION_DATABASE,
            "EXPLAIN QUERY PLAN SELECT text, base_key, tone_key, source_weight FROM pronunciation "
            "WHERE initial_key = 'x' AND syllable_count = 2 ORDER BY source_weight DESC, id LIMIT 64",
        )
        initial_detail = " ".join(str(row[-1]) for row in initial_plan).lower()
        self.assertIn("pronunciation_initial_key", initial_detail)
        self.assertIn("search", initial_detail)


if __name__ == "__main__":
    unittest.main()
