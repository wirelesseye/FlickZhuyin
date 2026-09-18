#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import sys
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from pinyin_to_zhuyin import PinyinError, convert_syllable, strip_tone

REPOSITORY = "https://github.com/rime/rime-terra-pinyin"
RAW_BASE_URL = "https://raw.githubusercontent.com/rime/rime-terra-pinyin"
DICTIONARY_PATH = "terra_pinyin.dict.yaml"
COMPILER_VERSION = "1"
SCHEMA_VERSION = 1
REQUIRED_HEADER_KEYS = ("name", "version")
REQUIRED_METADATA_KEYS = (
    "schema_version",
    "source_repository",
    "source_commit",
    "source_sha256",
    "dictionary_name",
    "dictionary_version",
    "compiler_version",
    "entry_count",
    "max_syllable_count",
)
WEIGHT_PATTERN = re.compile(r"^(\d+(?:\.\d+)?)%$")
SEPARATOR = "\u001f"

SCHEMA = """
CREATE TABLE metadata (
    key   TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE syllable_inventory (
    base TEXT PRIMARY KEY NOT NULL
) WITHOUT ROWID;

CREATE TABLE pronunciation (
    id             INTEGER PRIMARY KEY,
    text           TEXT NOT NULL,
    syllable_count INTEGER NOT NULL,
    base_key       TEXT NOT NULL,
    tone_key       TEXT NOT NULL,
    source_weight  REAL,
    source_line    INTEGER NOT NULL,
    UNIQUE(text, base_key, tone_key)
);

CREATE INDEX pronunciation_base_key
ON pronunciation(base_key, syllable_count);
"""


@dataclass(frozen=True)
class SourceEntry:
    text: str
    pinyin_syllables: tuple[str, ...]
    source_weight: float | None
    source_line: int


@dataclass(frozen=True)
class CompiledEntry:
    text: str
    base_syllables: tuple[str, ...]
    tones: tuple[int, ...]
    source_weight: float | None
    source_line: int

    @property
    def base_key(self) -> str:
        return SEPARATOR.join(self.base_syllables)

    @property
    def tone_key(self) -> str:
        return "".join(str(tone) for tone in self.tones)

    @property
    def syllable_count(self) -> int:
        return len(self.base_syllables)


@dataclass(frozen=True)
class ParsedDictionary:
    header: dict[str, str]
    entries: tuple[SourceEntry, ...]
    errors: tuple[str, ...]


@dataclass(frozen=True)
class BuildOutput:
    compiled_entries: int
    duplicate_entries: int
    distinct_pinyin_syllables: int
    max_syllable_count: int


class CompileFailure(Exception):
    pass


def read_header(text: str) -> tuple[dict[str, str], int]:
    lines = text.splitlines()
    header: dict[str, str] = {}
    start = None
    end = None
    for index, line in enumerate(lines):
        stripped = line.strip()
        if start is None:
            if stripped == "---":
                start = index
            continue
        if stripped == "...":
            end = index
            break
        if not stripped or stripped.startswith("#"):
            continue
        key, separator, value = stripped.partition(":")
        if not separator:
            continue
        header[key.strip()] = value.strip().strip('"').strip("'")
    if start is None:
        raise CompileFailure("missing '---' header opener")
    if end is None:
        raise CompileFailure("missing '...' header terminator")
    return header, end + 1


def parse_weight(raw: str, line_number: int) -> float:
    match = WEIGHT_PATTERN.match(raw)
    if match is None:
        raise CompileFailure(f"line {line_number}: invalid weight {raw!r}")
    value = float(match.group(1)) / 100.0
    if not 0.0 <= value <= 1.0:
        raise CompileFailure(f"line {line_number}: weight out of range {raw!r}")
    return value


def parse_body_line(line: str, line_number: int, errors: list[str]) -> SourceEntry | None:
    columns = line.split("\t")
    if len(columns) not in (2, 3):
        errors.append(f"line {line_number}: expected 2 or 3 tab-separated columns, got {len(columns)}")
        return None
    text = columns[0]
    code = columns[1]
    if not text:
        errors.append(f"line {line_number}: empty text")
        return None
    if not code:
        errors.append(f"line {line_number}: empty code")
        return None
    syllables = code.split(" ")
    if any(not syllable for syllable in syllables):
        errors.append(f"line {line_number}: code {code!r} contains an empty pinyin syllable")
        return None
    weight = None
    if len(columns) == 3:
        try:
            weight = parse_weight(columns[2], line_number)
        except CompileFailure as failure:
            errors.append(str(failure))
            return None
    return SourceEntry(text, tuple(syllables), weight, line_number)


def parse_dictionary(path: Path) -> ParsedDictionary:
    text = Path(path).read_text(encoding="utf-8")
    try:
        header, body_start = read_header(text)
    except CompileFailure as failure:
        return ParsedDictionary({}, (), (str(failure),))
    errors: list[str] = []
    for key in REQUIRED_HEADER_KEYS:
        if not header.get(key):
            errors.append(f"header: missing required key {key!r}")
    entries: list[SourceEntry] = []
    lines = text.splitlines()
    for index in range(body_start, len(lines)):
        line = lines[index]
        if not line.strip():
            continue
        if line.lstrip().startswith("#"):
            continue
        entry = parse_body_line(line, index + 1, errors)
        if entry is not None:
            entries.append(entry)
    return ParsedDictionary(header, tuple(entries), tuple(errors))


def compile_entries(
    entries: tuple[SourceEntry, ...],
    source_path: Path,
) -> tuple[list[CompiledEntry], list[str], list[dict], int, list[str]]:
    errors: list[str] = []
    converted: list[CompiledEntry] = []
    distinct_pinyin: set[str] = set()
    for entry in entries:
        bases: list[str] = []
        tones: list[int] = []
        failed = False
        for syllable in entry.pinyin_syllables:
            if strip_tone(syllable):
                distinct_pinyin.add(strip_tone(syllable))
            try:
                zhuyin = convert_syllable(syllable)
            except PinyinError as error:
                errors.append(f"{source_path}:{entry.source_line}: {error}")
                failed = True
                continue
            bases.append(zhuyin.base)
            tones.append(zhuyin.tone)
        if failed:
            continue
        converted.append(
            CompiledEntry(entry.text, tuple(bases), tuple(tones), entry.source_weight, entry.source_line)
        )

    unique: dict[tuple[str, str, str], CompiledEntry] = {}
    conflicts: list[dict] = []
    duplicates = 0
    for entry in converted:
        key = (entry.text, entry.base_key, entry.tone_key)
        existing = unique.get(key)
        if existing is None:
            unique[key] = entry
            continue
        duplicates += 1
        if entry.source_weight is None:
            continue
        if existing.source_weight is None:
            unique[key] = entry
            continue
        if entry.source_weight == existing.source_weight:
            continue
        if entry.source_weight > existing.source_weight:
            kept, discarded = entry, existing
            unique[key] = entry
        else:
            kept, discarded = existing, entry
        conflicts.append(
            {
                "text": kept.text,
                "baseKey": kept.base_key,
                "toneKey": kept.tone_key,
                "keptWeight": kept.source_weight,
                "discardedWeight": discarded.source_weight,
                "keptLine": kept.source_line,
                "discardedLine": discarded.source_line,
            }
        )
    rows = sorted(unique.values(), key=lambda e: (e.base_key, e.tone_key, e.text, e.source_line))
    return rows, errors, conflicts, duplicates, sorted(distinct_pinyin)


def make_metadata(
    manifest: dict,
    header: dict[str, str],
    source_sha256: str,
    entry_count: int,
    max_syllable_count: int,
) -> dict[str, str]:
    metadata = {
        "schema_version": str(SCHEMA_VERSION),
        "source_repository": str(manifest.get("repository", "")),
        "source_commit": str(manifest.get("commit", "")),
        "source_sha256": source_sha256,
        "dictionary_name": header.get("name", ""),
        "dictionary_version": header.get("version", ""),
        "compiler_version": COMPILER_VERSION,
        "entry_count": str(entry_count),
        "max_syllable_count": str(max_syllable_count),
    }
    missing = [key for key in REQUIRED_METADATA_KEYS if not metadata.get(key)]
    if missing:
        raise CompileFailure(f"missing metadata: {', '.join(missing)}")
    return metadata


def write_database(
    path: Path,
    rows: list[CompiledEntry],
    inventory: list[str],
    metadata: dict[str, str],
) -> bytes:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)
    connection = sqlite3.connect(path, isolation_level=None)
    try:
        connection.execute("PRAGMA page_size = 4096")
        connection.execute("PRAGMA journal_mode = DELETE")
        connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        connection.executescript(SCHEMA)
        connection.executemany(
            "INSERT INTO metadata (key, value) VALUES (?, ?)",
            sorted(metadata.items()),
        )
        connection.executemany(
            "INSERT INTO syllable_inventory (base) VALUES (?)",
            [(base,) for base in inventory],
        )
        connection.executemany(
            "INSERT INTO pronunciation (text, syllable_count, base_key, tone_key, source_weight, source_line)"
            " VALUES (?, ?, ?, ?, ?, ?)",
            [
                (
                    row.text,
                    row.syllable_count,
                    row.base_key,
                    row.tone_key,
                    row.source_weight,
                    row.source_line,
                )
                for row in rows
            ],
        )
        connection.execute("VACUUM")
    finally:
        connection.close()
    for suffix in ("-journal", "-wal", "-shm"):
        Path(f"{path}{suffix}").unlink(missing_ok=True)
    return path.read_bytes()


def build_database(
    source_path: Path,
    manifest_path: Path,
    output_path: Path,
    report_path: Path,
) -> BuildOutput:
    manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    source_bytes = Path(source_path).read_bytes()
    source_sha256 = hashlib.sha256(source_bytes).hexdigest()
    if manifest.get("sha256") != source_sha256:
        raise CompileFailure(
            f"{manifest_path}: sha256 mismatch: manifest has {manifest.get('sha256')!r}, "
            f"source is {source_sha256!r}"
        )
    parsed = parse_dictionary(source_path)
    errors = list(parsed.errors)
    rows: list[CompiledEntry] = []
    conflicts: list[dict] = []
    duplicates = 0
    distinct_pinyin: list[str] = []
    if not errors:
        rows, errors, conflicts, duplicates, distinct_pinyin = compile_entries(parsed.entries, source_path)
    if errors:
        raise CompileFailure("\n".join(errors))
    inventory = sorted({base for row in rows for base in row.base_syllables})
    max_syllables = max((row.syllable_count for row in rows), default=0)
    metadata = make_metadata(manifest, parsed.header, source_sha256, len(rows), max_syllables)
    database_bytes = write_database(output_path, rows, inventory, metadata)
    report = {
        "sourceEntries": len(parsed.entries),
        "compiledEntries": len(rows),
        "duplicateEntries": duplicates,
        "distinctWords": len({row.text for row in rows}),
        "distinctPinyinSyllables": len(distinct_pinyin),
        "distinctZhuyinSyllables": len(inventory),
        "maxSyllableCount": max_syllables,
        "weightedEntries": sum(1 for row in rows if row.source_weight is not None),
        "errors": [],
        "duplicateWeightConflicts": conflicts,
        "source": {
            "path": str(source_path),
            "sha256": source_sha256,
            "dictionaryName": parsed.header.get("name", ""),
            "dictionaryVersion": parsed.header.get("version", ""),
            "sort": parsed.header.get("sort", ""),
            "usePresetVocabulary": parsed.header.get("use_preset_vocabulary", ""),
        },
        "compilerVersion": COMPILER_VERSION,
    }
    report_path = Path(report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return BuildOutput(
        compiled_entries=len(rows),
        duplicate_entries=duplicates,
        distinct_pinyin_syllables=len(distinct_pinyin),
        max_syllable_count=max_syllables,
    )


def command_fetch(args: argparse.Namespace) -> int:
    commit = args.commit
    if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        print("fetch: --commit must be a full 40-character lowercase hex commit", file=sys.stderr)
        return 2
    destination = Path(args.dest)
    destination.mkdir(parents=True, exist_ok=True)
    dictionary_bytes = None
    sha256 = None
    for name in (DICTIONARY_PATH, "LICENSE"):
        url = f"{RAW_BASE_URL}/{commit}/{name}"
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
        (destination / name).write_bytes(data)
        if name == DICTIONARY_PATH:
            dictionary_bytes = data
            sha256 = hashlib.sha256(data).hexdigest()
    header, _ = read_header(dictionary_bytes.decode("utf-8"))
    manifest = {
        "repository": REPOSITORY,
        "commit": commit,
        "dictionaryPath": DICTIONARY_PATH,
        "sha256": sha256,
        "dictionaryVersion": header.get("version", ""),
        "retrievedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    (destination / "SOURCE.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"fetch: wrote {destination / DICTIONARY_PATH} ({sha256})")
    return 0


def command_build(args: argparse.Namespace) -> int:
    if not Path(args.source).exists():
        print(f"build: source not found: {args.source}", file=sys.stderr)
        return 2
    if not Path(args.manifest).exists():
        print(f"build: manifest not found: {args.manifest}", file=sys.stderr)
        return 2
    try:
        result = build_database(
            Path(args.source), Path(args.manifest), Path(args.output), Path(args.report)
        )
    except CompileFailure as failure:
        print("build: failed:", file=sys.stderr)
        for line in str(failure).splitlines():
            print(f"  {line}", file=sys.stderr)
        return 1
    print(f"build: {result.compiled_entries} entries compiled, {result.duplicate_entries} duplicates")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Compile the pinned Rime Terra Pinyin dictionary")
    subparsers = parser.add_subparsers(dest="command", required=True)

    fetch = subparsers.add_parser("fetch", help="download the pinned upstream dictionary and license")
    fetch.add_argument("--commit", required=True)
    fetch.add_argument("--dest", default="Vendor/rime-terra-pinyin")
    fetch.set_defaults(func=command_fetch)

    build = subparsers.add_parser("build", help="build the SQLite dictionary without network access")
    build.add_argument("--source", required=True)
    build.add_argument("--manifest", required=True)
    build.add_argument("--output", required=True)
    build.add_argument("--report", required=True)
    build.set_defaults(func=command_build)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
