#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sqlite3
import sys
import urllib.request
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path

from pinyin_to_zhuyin import PinyinError, convert_syllable, strip_tone

TERRA_REPOSITORY = "https://github.com/rime/rime-terra-pinyin"
TERRA_RAW_BASE_URL = "https://raw.githubusercontent.com/rime/rime-terra-pinyin"
TERRA_DICTIONARY_PATH = "terra_pinyin.dict.yaml"
ESSAY_REPOSITORY = "https://github.com/rime/rime-essay"
ESSAY_RAW_BASE_URL = "https://raw.githubusercontent.com/rime/rime-essay"
ESSAY_PATH = "essay.txt"
ESSAY_FORMAT_VERSION = 1
COMPILER_VERSION = "4"
SCHEMA_VERSION = 3
REQUIRED_HEADER_KEYS = ("name", "version")
REQUIRED_METADATA_KEYS = (
    "schema_version",
    "terra_source_repository",
    "terra_source_commit",
    "terra_source_sha256",
    "essay_source_repository",
    "essay_source_commit",
    "essay_source_sha256",
    "dictionary_name",
    "dictionary_version",
    "compiler_version",
    "entry_count",
    "max_syllable_count",
    "essay_entry_count",
    "essay_annotated_entry_count",
    "essay_frequency_max",
    "weight_normalization",
)
WEIGHT_PATTERN = re.compile(r"^(\d+(?:\.\d+)?)%$")
INTEGER_PATTERN = re.compile(r"^\d+$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SEPARATOR = "\u001f"
MAXIMUM_PRONUNCIATIONS_PER_WORD = 16
MAXIMUM_ESSAY_WORD_LENGTH = 16
MAXIMUM_DATABASE_BYTES = 256 * 1024 * 1024
MAXIMUM_STORED_INTEGER = 9_223_372_036_854_775_807
REPORT_EXAMPLE_LIMIT = 8
WEIGHT_NORMALIZATION = "log1p(frequency)/log1p(max_frequency)"
SOURCE_KIND_TERRA = "terra"
SOURCE_KIND_ESSAY = "essay"
SOURCE_KIND_MERGED = "terra+essay"

SCHEMA = """
CREATE TABLE metadata (
    key   TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE syllable_inventory (
    base TEXT PRIMARY KEY NOT NULL
) WITHOUT ROWID;

CREATE TABLE pronunciation (
    id                INTEGER PRIMARY KEY,
    text              TEXT NOT NULL,
    syllable_count    INTEGER NOT NULL,
    base_key          TEXT NOT NULL,
    tone_key          TEXT NOT NULL,
    initial_key       TEXT NOT NULL,
    source_weight     REAL,
    source_kind       TEXT NOT NULL CHECK (source_kind IN ('terra', 'essay', 'terra+essay')),
    terra_source_line INTEGER,
    terra_source_lines TEXT NOT NULL,
    essay_source_line INTEGER,
    raw_frequency     INTEGER,
    UNIQUE(text, base_key, tone_key)
);

CREATE INDEX pronunciation_base_key
ON pronunciation(base_key, syllable_count);

CREATE INDEX pronunciation_initial_key
ON pronunciation(initial_key, syllable_count, source_weight DESC);
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
class EssayEntry:
    text: str
    frequency: int
    source_line: int


@dataclass(frozen=True)
class ParsedEssay:
    entries: tuple[EssayEntry, ...]
    errors: tuple[str, ...]


@dataclass(frozen=True)
class TerraReading:
    base_syllables: tuple[str, ...]
    tones: tuple[int, ...]
    source_weight: float | None
    source_line: int


@dataclass(frozen=True)
class TerraIndex:
    words: dict[str, tuple[TerraReading, ...]]
    characters: dict[str, tuple[TerraReading, ...]]


@dataclass(frozen=True)
class AnnotatedReading:
    base_syllables: tuple[str, ...]
    tones: tuple[int, ...]
    explicit: bool
    terra_lines: tuple[int, ...]


@dataclass(frozen=True)
class AnnotatedEssayEntry:
    text: str
    frequency: int
    source_line: int
    readings: tuple[AnnotatedReading, ...]
    truncated: bool


@dataclass(frozen=True)
class EssayAnnotation:
    entries: tuple[AnnotatedEssayEntry, ...]
    annotated_entries: int
    explicit_entries: int
    composed_entries: int
    unannotated_entries: int
    oversized_entries: int
    truncated_entries: int
    generated_pronunciations: int
    excluded_zero_weight_readings: int
    unannotated_examples: tuple[dict, ...]
    truncated_examples: tuple[dict, ...]
    oversized_examples: tuple[dict, ...]


@dataclass(frozen=True)
class MergedEntry:
    text: str
    base_syllables: tuple[str, ...]
    tones: tuple[int, ...]
    source_weight: float | None
    source_kind: str
    terra_source_line: int | None
    terra_source_lines: tuple[int, ...]
    essay_source_line: int | None
    raw_frequency: int | None

    @property
    def base_key(self) -> str:
        return SEPARATOR.join(self.base_syllables)

    @property
    def tone_key(self) -> str:
        return "".join(str(tone) for tone in self.tones)

    @property
    def initial_key(self) -> str:
        return SEPARATOR.join(base[0] for base in self.base_syllables)

    @property
    def syllable_count(self) -> int:
        return len(self.base_syllables)


@dataclass(frozen=True)
class BuildOutput:
    compiled_entries: int
    duplicate_entries: int
    merged_terra_essay_entries: int
    essay_entries: int
    essay_annotated_entries: int
    essay_unannotated_entries: int
    essay_truncated_entries: int
    database_bytes: int


class CompileFailure(Exception):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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
        return ParsedDictionary({}, (), (f"{path}: {failure}",))
    errors: list[str] = []
    for key in REQUIRED_HEADER_KEYS:
        if not header.get(key):
            errors.append(f"{path}: header: missing required key {key!r}")
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


def parse_essay_text(text: str, source_label: str) -> ParsedEssay:
    errors: list[str] = []
    entries: list[EssayEntry] = []
    for index, raw in enumerate(text.splitlines(), start=1):
        if not raw.strip():
            continue
        if raw.lstrip().startswith("#"):
            continue
        columns = raw.split("\t")
        if len(columns) != 2:
            errors.append(f"{source_label}:{index}: expected 2 tab-separated columns, got {len(columns)}")
            continue
        word = columns[0]
        if not word:
            errors.append(f"{source_label}:{index}: empty text")
            continue
        raw_frequency = columns[1]
        if INTEGER_PATTERN.match(raw_frequency) is None:
            errors.append(f"{source_label}:{index}: invalid frequency {raw_frequency!r}")
            continue
        frequency = int(raw_frequency)
        if frequency > MAXIMUM_STORED_INTEGER:
            errors.append(f"{source_label}:{index}: frequency out of range {raw_frequency!r}")
            continue
        entries.append(EssayEntry(word, frequency, index))
    return ParsedEssay(tuple(entries), tuple(errors))


def parse_essay(path: Path) -> ParsedEssay:
    path = Path(path)
    return parse_essay_text(path.read_text(encoding="utf-8"), str(path))


def compile_terra_entries(
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


def terra_reading_sort_key(reading: TerraReading) -> tuple:
    return (
        0 if reading.source_weight is not None else 1,
        -(reading.source_weight or 0.0),
        reading.source_line,
        reading.base_syllables,
        reading.tones,
    )


def build_terra_index(rows: list[CompiledEntry]) -> TerraIndex:
    words: dict[str, list[TerraReading]] = {}
    characters: dict[str, list[TerraReading]] = {}
    for row in rows:
        reading = TerraReading(row.base_syllables, row.tones, row.source_weight, row.source_line)
        words.setdefault(row.text, []).append(reading)
        if len(row.text) == 1:
            characters.setdefault(row.text, []).append(reading)
    return TerraIndex(
        words={text: tuple(sorted(readings, key=terra_reading_sort_key)) for text, readings in words.items()},
        characters={
            text: tuple(sorted(readings, key=terra_reading_sort_key)) for text, readings in characters.items()
        },
    )


def merge_essay_entries(entries: tuple[EssayEntry, ...]) -> tuple[list[EssayEntry], int]:
    merged: dict[str, EssayEntry] = {}
    duplicates = 0
    for entry in entries:
        existing = merged.get(entry.text)
        if existing is None:
            merged[entry.text] = entry
            continue
        duplicates += 1
        if entry.frequency > existing.frequency:
            merged[entry.text] = entry
    return list(merged.values()), duplicates


def readings_for_composition(readings: tuple[TerraReading, ...]) -> tuple[TerraReading, ...]:
    has_positive_weight = any(
        reading.source_weight is not None and reading.source_weight > 0.0
        for reading in readings
    )
    if not has_positive_weight:
        return readings
    return tuple(
        reading
        for reading in readings
        if reading.source_weight is None or reading.source_weight > 0.0
    )


def compose_readings(
    reading_lists: list[tuple[TerraReading, ...]],
    limit: int,
) -> list[AnnotatedReading]:
    results: list[AnnotatedReading] = []
    bases: list[tuple[str, ...]] = []
    tones: list[tuple[int, ...]] = []
    lines: list[tuple[int, ...]] = []

    def visit(position: int) -> None:
        if len(results) >= limit:
            return
        if position == len(reading_lists):
            results.append(
                AnnotatedReading(
                    tuple(base for part in bases for base in part),
                    tuple(tone for part in tones for tone in part),
                    False,
                    tuple(line for part in lines for line in part),
                )
            )
            return
        for reading in reading_lists[position]:
            if len(results) >= limit:
                return
            bases.append(reading.base_syllables)
            tones.append(reading.tones)
            lines.append((reading.source_line,))
            visit(position + 1)
            bases.pop()
            tones.pop()
            lines.pop()

    visit(0)
    return results


def deduplicate_readings(readings: list[AnnotatedReading]) -> list[AnnotatedReading]:
    unique: list[AnnotatedReading] = []
    seen: set[tuple[tuple[str, ...], tuple[int, ...]]] = set()
    for reading in readings:
        key = (reading.base_syllables, reading.tones)
        if key in seen:
            continue
        seen.add(key)
        unique.append(reading)
    return unique


def annotate_essay(entries: list[EssayEntry], index: TerraIndex) -> EssayAnnotation:
    annotated: list[AnnotatedEssayEntry] = []
    explicit_entries = 0
    composed_entries = 0
    unannotated_entries = 0
    oversized_entries = 0
    truncated_entries = 0
    generated_pronunciations = 0
    excluded_zero_weight_readings = 0
    unannotated_examples: list[dict] = []
    truncated_examples: list[dict] = []
    oversized_examples: list[dict] = []

    for entry in entries:
        if len(entry.text) > MAXIMUM_ESSAY_WORD_LENGTH:
            oversized_entries += 1
            if len(oversized_examples) < REPORT_EXAMPLE_LIMIT:
                oversized_examples.append(
                    {"text": entry.text, "essaySourceLine": entry.source_line, "length": len(entry.text)}
                )
            continue

        explicit = index.words.get(entry.text)
        if explicit is not None:
            readings = [
                AnnotatedReading(reading.base_syllables, reading.tones, True, (reading.source_line,))
                for reading in explicit
            ]
            truncated = len(readings) > MAXIMUM_PRONUNCIATIONS_PER_WORD
            readings = deduplicate_readings(readings)[:MAXIMUM_PRONUNCIATIONS_PER_WORD]
            explicit_entries += 1
        else:
            missing = "".join(character for character in entry.text if character not in index.characters)
            if missing:
                unannotated_entries += 1
                if len(unannotated_examples) < REPORT_EXAMPLE_LIMIT:
                    unannotated_examples.append(
                        {
                            "text": entry.text,
                            "essaySourceLine": entry.source_line,
                            "missingCharacters": missing,
                        }
                    )
                continue
            reading_lists = []
            for character in entry.text:
                character_readings = index.characters[character]
                composed_readings = readings_for_composition(character_readings)
                excluded_zero_weight_readings += len(character_readings) - len(composed_readings)
                reading_lists.append(composed_readings)
            combinations = math.prod(len(readings) for readings in reading_lists)
            truncated = combinations > MAXIMUM_PRONUNCIATIONS_PER_WORD
            readings = compose_readings(reading_lists, MAXIMUM_PRONUNCIATIONS_PER_WORD + 1)
            readings = deduplicate_readings(readings)[:MAXIMUM_PRONUNCIATIONS_PER_WORD]
            composed_entries += 1

        if truncated:
            truncated_entries += 1
            if len(truncated_examples) < REPORT_EXAMPLE_LIMIT:
                truncated_examples.append(
                    {
                        "text": entry.text,
                        "essaySourceLine": entry.source_line,
                        "retained": len(readings),
                        "limit": MAXIMUM_PRONUNCIATIONS_PER_WORD,
                    }
                )
        generated_pronunciations += len(readings)
        annotated.append(
            AnnotatedEssayEntry(entry.text, entry.frequency, entry.source_line, tuple(readings), truncated)
        )

    return EssayAnnotation(
        entries=tuple(annotated),
        annotated_entries=explicit_entries + composed_entries,
        explicit_entries=explicit_entries,
        composed_entries=composed_entries,
        unannotated_entries=unannotated_entries,
        oversized_entries=oversized_entries,
        truncated_entries=truncated_entries,
        generated_pronunciations=generated_pronunciations,
        excluded_zero_weight_readings=excluded_zero_weight_readings,
        unannotated_examples=tuple(unannotated_examples),
        truncated_examples=tuple(truncated_examples),
        oversized_examples=tuple(oversized_examples),
    )


def normalize_frequency(frequency: int, maximum_frequency: int) -> float:
    if frequency <= 0 or maximum_frequency <= 0:
        return 0.0
    return min(1.0, math.log1p(frequency) / math.log1p(maximum_frequency))


def merge_rows(
    terra_rows: list[CompiledEntry],
    annotated_entries: tuple[AnnotatedEssayEntry, ...],
    maximum_frequency: int,
) -> tuple[list[MergedEntry], int, int]:
    rows: dict[tuple[str, str, str], MergedEntry] = {}
    for row in terra_rows:
        entry = MergedEntry(
            row.text,
            row.base_syllables,
            row.tones,
            row.source_weight,
            SOURCE_KIND_TERRA,
            row.source_line,
            (row.source_line,),
            None,
            None,
        )
        rows[(entry.text, entry.base_key, entry.tone_key)] = entry
    merged_count = 0
    duplicate_pronunciations = 0
    for entry in annotated_entries:
        weight = normalize_frequency(entry.frequency, maximum_frequency)
        for reading in entry.readings:
            base_key = SEPARATOR.join(reading.base_syllables)
            tone_key = "".join(str(tone) for tone in reading.tones)
            key = (entry.text, base_key, tone_key)
            existing = rows.get(key)
            if existing is None:
                rows[key] = MergedEntry(
                    entry.text,
                    reading.base_syllables,
                    reading.tones,
                    weight,
                    SOURCE_KIND_ESSAY,
                    None,
                    reading.terra_lines,
                    entry.source_line,
                    entry.frequency,
                )
                continue
            if existing.essay_source_line is not None:
                duplicate_pronunciations += 1
                if entry.frequency <= (existing.raw_frequency or 0):
                    continue
                rows[key] = replace(
                    existing,
                    source_weight=weight,
                    essay_source_line=entry.source_line,
                    raw_frequency=entry.frequency,
                )
                continue
            merged_count += 1
            rows[key] = replace(
                existing,
                source_weight=weight,
                source_kind=SOURCE_KIND_MERGED,
                essay_source_line=entry.source_line,
                raw_frequency=entry.frequency,
            )
    ordered = sorted(
        rows.values(),
        key=lambda entry: (
            entry.base_key,
            entry.tone_key,
            entry.text,
            entry.source_kind,
            entry.terra_source_line or 0,
            entry.essay_source_line or 0,
        ),
    )
    return ordered, merged_count, duplicate_pronunciations


def load_manifest(path: Path) -> dict:
    try:
        manifest = json.loads(Path(path).read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise CompileFailure(f"{path}: invalid JSON manifest ({error})") from error
    if not isinstance(manifest, dict):
        raise CompileFailure(f"{path}: manifest must be a JSON object")
    commit = manifest.get("commit")
    if not isinstance(commit, str) or COMMIT_PATTERN.fullmatch(commit) is None:
        raise CompileFailure(f"{path}: commit must be a full 40-character lowercase hex string")
    return manifest


def verify_manifest_contract(
    manifest: dict,
    manifest_path: Path,
    source_path: Path,
    source_path_key: str,
) -> None:
    repository = manifest.get("repository")
    if not isinstance(repository, str) or not repository:
        raise CompileFailure(f"{manifest_path}: missing repository")
    declared_path = manifest.get(source_path_key)
    if declared_path != Path(source_path).name:
        raise CompileFailure(
            f"{manifest_path}: {source_path_key} is {declared_path!r}, "
            f"expected {Path(source_path).name!r}"
        )
    license_path = manifest.get("licensePath")
    if not isinstance(license_path, str) or not license_path:
        raise CompileFailure(f"{manifest_path}: missing licensePath")
    license_sha256 = manifest.get("licenseSha256")
    if not isinstance(license_sha256, str) or SHA256_PATTERN.fullmatch(license_sha256) is None:
        raise CompileFailure(f"{manifest_path}: licenseSha256 must be a lowercase SHA-256")


def verify_essay_format(manifest: dict, manifest_path: Path) -> None:
    format_version = manifest.get("formatVersion")
    if format_version != ESSAY_FORMAT_VERSION:
        raise CompileFailure(
            f"{manifest_path}: unsupported essay formatVersion {format_version!r}, "
            f"expected {ESSAY_FORMAT_VERSION}"
        )


def verify_source_hash(manifest: dict, manifest_path: Path, source_path: Path) -> str:
    expected = manifest.get("sha256")
    if not isinstance(expected, str) or SHA256_PATTERN.fullmatch(expected) is None:
        raise CompileFailure(f"{manifest_path}: sha256 must be a lowercase SHA-256")
    source_bytes = Path(source_path).read_bytes()
    actual = sha256_bytes(source_bytes)
    if expected != actual:
        raise CompileFailure(
            f"{manifest_path}: sha256 mismatch: manifest has {expected!r}, source is {actual!r}"
        )
    return actual


def verify_license_hash(manifest: dict, manifest_path: Path, source_path: Path) -> None:
    expected = manifest.get("licenseSha256")
    license_path = Path(source_path).parent / manifest["licensePath"]
    if not license_path.exists():
        raise CompileFailure(f"{manifest_path}: license not found: {license_path}")
    actual = sha256_bytes(license_path.read_bytes())
    if expected != actual:
        raise CompileFailure(
            f"{manifest_path}: license sha256 mismatch: manifest has {expected!r}, license is {actual!r}"
        )


def make_metadata(
    terra_manifest: dict,
    terra_header: dict[str, str],
    terra_sha256: str,
    essay_manifest: dict,
    essay_sha256: str,
    essay_entry_count: int,
    essay_annotated_entry_count: int,
    essay_frequency_max: int,
    entry_count: int,
    max_syllable_count: int,
) -> dict[str, str]:
    metadata = {
        "schema_version": str(SCHEMA_VERSION),
        "terra_source_repository": str(terra_manifest.get("repository", "")),
        "terra_source_commit": str(terra_manifest.get("commit", "")),
        "terra_source_sha256": terra_sha256,
        "essay_source_repository": str(essay_manifest.get("repository", "")),
        "essay_source_commit": str(essay_manifest.get("commit", "")),
        "essay_source_sha256": essay_sha256,
        "dictionary_name": terra_header.get("name", ""),
        "dictionary_version": terra_header.get("version", ""),
        "compiler_version": COMPILER_VERSION,
        "entry_count": str(entry_count),
        "max_syllable_count": str(max_syllable_count),
        "essay_entry_count": str(essay_entry_count),
        "essay_annotated_entry_count": str(essay_annotated_entry_count),
        "essay_frequency_max": str(essay_frequency_max),
        "weight_normalization": WEIGHT_NORMALIZATION,
    }
    missing = [key for key in REQUIRED_METADATA_KEYS if not metadata.get(key)]
    if missing:
        raise CompileFailure(f"missing metadata: {', '.join(missing)}")
    return metadata


def validate_initial_keys(rows: list[MergedEntry]) -> int:
    for row in rows:
        if any(not base for base in row.base_syllables):
            raise CompileFailure(f"entry {row.text!r} has an empty base syllable")
        segments = row.initial_key.split(SEPARATOR)
        if len(segments) != row.syllable_count or any(len(segment) != 1 for segment in segments):
            raise CompileFailure(
                f"entry {row.text!r} initial_key {row.initial_key!r} does not match "
                f"{row.syllable_count} syllable(s)"
            )
    return len(rows)


def write_database(
    path: Path,
    rows: list[MergedEntry],
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
        connection.execute("BEGIN")
        connection.executemany(
            "INSERT INTO metadata (key, value) VALUES (?, ?)",
            sorted(metadata.items()),
        )
        connection.executemany(
            "INSERT INTO syllable_inventory (base) VALUES (?)",
            [(base,) for base in inventory],
        )
        connection.executemany(
            "INSERT INTO pronunciation ("
            "text, syllable_count, base_key, tone_key, initial_key, source_weight, source_kind,"
            " terra_source_line, terra_source_lines, essay_source_line, raw_frequency"
            ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (
                    row.text,
                    row.syllable_count,
                    row.base_key,
                    row.tone_key,
                    row.initial_key,
                    row.source_weight,
                    row.source_kind,
                    row.terra_source_line,
                    json.dumps(row.terra_source_lines, separators=(",", ":")),
                    row.essay_source_line,
                    row.raw_frequency,
                )
                for row in rows
            ],
        )
        connection.execute("COMMIT")
        connection.execute("VACUUM")
        integrity = connection.execute("PRAGMA integrity_check").fetchone()
        if integrity is None or integrity[0] != "ok":
            raise CompileFailure(f"integrity_check failed: {integrity!r}")
    finally:
        connection.close()
    for suffix in ("-journal", "-wal", "-shm"):
        Path(f"{path}{suffix}").unlink(missing_ok=True)
    return path.read_bytes()


def build_database(
    terra_source_path: Path,
    terra_manifest_path: Path,
    essay_source_path: Path,
    essay_manifest_path: Path,
    output_path: Path,
    report_path: Path,
) -> BuildOutput:
    terra_manifest = load_manifest(terra_manifest_path)
    essay_manifest = load_manifest(essay_manifest_path)
    verify_manifest_contract(
        terra_manifest, terra_manifest_path, terra_source_path, "dictionaryPath"
    )
    verify_manifest_contract(
        essay_manifest, essay_manifest_path, essay_source_path, "essayPath"
    )
    verify_essay_format(essay_manifest, essay_manifest_path)
    terra_sha256 = verify_source_hash(terra_manifest, terra_manifest_path, terra_source_path)
    essay_sha256 = verify_source_hash(essay_manifest, essay_manifest_path, essay_source_path)
    verify_license_hash(terra_manifest, terra_manifest_path, terra_source_path)
    verify_license_hash(essay_manifest, essay_manifest_path, essay_source_path)

    parsed_terra = parse_dictionary(terra_source_path)
    parsed_essay = parse_essay(essay_source_path)
    errors = list(parsed_terra.errors) + list(parsed_essay.errors)
    terra_rows: list[CompiledEntry] = []
    terra_conflicts: list[dict] = []
    terra_duplicates = 0
    distinct_pinyin: list[str] = []
    if not errors:
        terra_rows, errors, terra_conflicts, terra_duplicates, distinct_pinyin = compile_terra_entries(
            parsed_terra.entries, terra_source_path
        )
    if errors:
        raise CompileFailure("\n".join(errors))

    if terra_manifest.get("dictionaryVersion") != parsed_terra.header.get("version"):
        raise CompileFailure(
            f"{terra_manifest_path}: dictionaryVersion does not match the Terra header"
        )
    essay_entry_count = len(parsed_essay.entries)
    essay_frequency_max = max((entry.frequency for entry in parsed_essay.entries), default=0)
    if essay_manifest.get("entryCount") != essay_entry_count:
        raise CompileFailure(
            f"{essay_manifest_path}: entryCount is {essay_manifest.get('entryCount')!r}, "
            f"expected {essay_entry_count}"
        )
    if essay_manifest.get("frequencyMax") != essay_frequency_max:
        raise CompileFailure(
            f"{essay_manifest_path}: frequencyMax is {essay_manifest.get('frequencyMax')!r}, "
            f"expected {essay_frequency_max}"
        )

    merged_essay, essay_duplicates = merge_essay_entries(parsed_essay.entries)
    maximum_frequency = max((entry.frequency for entry in merged_essay), default=0)
    index = build_terra_index(terra_rows)
    annotation = annotate_essay(merged_essay, index)
    rows, merged_count, duplicate_pronunciations = merge_rows(
        terra_rows, annotation.entries, maximum_frequency
    )

    inventory = sorted({base for row in rows for base in row.base_syllables})
    max_syllables = max((row.syllable_count for row in rows), default=0)
    checked_initial_keys = validate_initial_keys(rows)
    metadata = make_metadata(
        terra_manifest,
        parsed_terra.header,
        terra_sha256,
        essay_manifest,
        essay_sha256,
        len(parsed_essay.entries),
        annotation.annotated_entries,
        maximum_frequency,
        len(rows),
        max_syllables,
    )
    database_bytes = write_database(output_path, rows, inventory, metadata)
    if len(database_bytes) > MAXIMUM_DATABASE_BYTES:
        Path(output_path).unlink(missing_ok=True)
        raise CompileFailure(
            f"database size {len(database_bytes)} bytes exceeds limit {MAXIMUM_DATABASE_BYTES} bytes"
        )

    report = {
        "sourceEntries": len(parsed_terra.entries),
        "compiledEntries": len(rows),
        "terraCompiledEntries": len(terra_rows),
        "duplicateEntries": terra_duplicates,
        "duplicateEssayEntries": essay_duplicates,
        "duplicatePronunciations": duplicate_pronunciations,
        "mergedTerraEssayEntries": merged_count,
        "essayEntries": len(parsed_essay.entries),
        "essayMergedEntries": len(merged_essay),
        "essayAnnotatedEntries": annotation.annotated_entries,
        "essayExplicitEntries": annotation.explicit_entries,
        "essayComposedEntries": annotation.composed_entries,
        "essayUnannotatedEntries": annotation.unannotated_entries,
        "essayOversizedEntries": annotation.oversized_entries,
        "essayTruncatedEntries": annotation.truncated_entries,
        "generatedPronunciations": annotation.generated_pronunciations,
        "excludedZeroWeightReadings": annotation.excluded_zero_weight_readings,
        "distinctWords": len({row.text for row in rows}),
        "distinctPinyinSyllables": len(distinct_pinyin),
        "distinctZhuyinSyllables": len(inventory),
        "distinctInitialKeys": len({row.initial_key for row in rows}),
        "initialKeyIntegrity": {
            "checkedEntries": checked_initial_keys,
            "syllableCountMismatches": 0,
        },
        "maxSyllableCount": max_syllables,
        "weightedEntries": sum(1 for row in rows if row.source_weight is not None),
        "essayWeightedEntries": sum(1 for row in rows if row.raw_frequency is not None),
        "normalization": {
            "formula": WEIGHT_NORMALIZATION,
            "maximumFrequency": maximum_frequency,
        },
        "database": {
            "bytes": len(database_bytes),
            "limitBytes": MAXIMUM_DATABASE_BYTES,
        },
        "errors": [],
        "duplicateWeightConflicts": terra_conflicts,
        "unannotatedExamples": list(annotation.unannotated_examples),
        "truncatedExamples": list(annotation.truncated_examples),
        "oversizedExamples": list(annotation.oversized_examples),
        "sources": {
            "terra": {
                "path": str(terra_manifest["dictionaryPath"]),
                "sha256": terra_sha256,
                "repository": str(terra_manifest.get("repository", "")),
                "commit": str(terra_manifest.get("commit", "")),
                "dictionaryName": parsed_terra.header.get("name", ""),
                "dictionaryVersion": parsed_terra.header.get("version", ""),
                "sort": parsed_terra.header.get("sort", ""),
                "usePresetVocabulary": parsed_terra.header.get("use_preset_vocabulary", ""),
            },
            "essay": {
                "path": str(essay_manifest["essayPath"]),
                "sha256": essay_sha256,
                "repository": str(essay_manifest.get("repository", "")),
                "commit": str(essay_manifest.get("commit", "")),
                "formatVersion": str(essay_manifest.get("formatVersion", "")),
                "entryCount": len(parsed_essay.entries),
                "frequencyMax": maximum_frequency,
            },
        },
        "compilerVersion": COMPILER_VERSION,
        "schemaVersion": SCHEMA_VERSION,
    }
    report_path = Path(report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return BuildOutput(
        compiled_entries=len(rows),
        duplicate_entries=terra_duplicates,
        merged_terra_essay_entries=merged_count,
        essay_entries=len(parsed_essay.entries),
        essay_annotated_entries=annotation.annotated_entries,
        essay_unannotated_entries=annotation.unannotated_entries,
        essay_truncated_entries=annotation.truncated_entries,
        database_bytes=len(database_bytes),
    )


def download(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read()


def validate_commit(commit: str) -> bool:
    return COMMIT_PATTERN.fullmatch(commit) is not None


def command_fetch_terra(args: argparse.Namespace) -> int:
    if not validate_commit(args.commit):
        print("fetch-terra: --commit must be a full 40-character lowercase hex commit", file=sys.stderr)
        return 2
    destination = Path(args.dest)
    files = {
        name: download(f"{TERRA_RAW_BASE_URL}/{args.commit}/{name}")
        for name in (TERRA_DICTIONARY_PATH, "LICENSE")
    }
    try:
        header, _ = read_header(files[TERRA_DICTIONARY_PATH].decode("utf-8"))
    except CompileFailure as failure:
        print(f"fetch-terra: invalid dictionary: {failure}", file=sys.stderr)
        return 1
    manifest = {
        "repository": TERRA_REPOSITORY,
        "commit": args.commit,
        "dictionaryPath": TERRA_DICTIONARY_PATH,
        "sha256": sha256_bytes(files[TERRA_DICTIONARY_PATH]),
        "licensePath": "LICENSE",
        "licenseSha256": sha256_bytes(files["LICENSE"]),
        "dictionaryVersion": header.get("version", ""),
        "retrievedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (destination / name).write_bytes(data)
    (destination / "SOURCE.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"fetch-terra: wrote {destination / TERRA_DICTIONARY_PATH} ({manifest['sha256']})")
    return 0


def command_fetch_essay(args: argparse.Namespace) -> int:
    if not validate_commit(args.commit):
        print("fetch-essay: --commit must be a full 40-character lowercase hex commit", file=sys.stderr)
        return 2
    destination = Path(args.dest)
    files = {
        name: download(f"{ESSAY_RAW_BASE_URL}/{args.commit}/{name}")
        for name in (ESSAY_PATH, "LICENSE")
    }
    essay_text = files[ESSAY_PATH].decode("utf-8")
    parsed = parse_essay_text(essay_text, f"{ESSAY_REPOSITORY}/{args.commit}/{ESSAY_PATH}")
    if parsed.errors:
        print("fetch-essay: invalid essay data:", file=sys.stderr)
        for line in parsed.errors[:REPORT_EXAMPLE_LIMIT]:
            print(f"  {line}", file=sys.stderr)
        print(f"fetch-essay: {len(parsed.errors)} format errors", file=sys.stderr)
        return 1
    maximum_frequency = max((entry.frequency for entry in parsed.entries), default=0)
    manifest = {
        "repository": ESSAY_REPOSITORY,
        "commit": args.commit,
        "essayPath": ESSAY_PATH,
        "sha256": sha256_bytes(files[ESSAY_PATH]),
        "licensePath": "LICENSE",
        "licenseSha256": sha256_bytes(files["LICENSE"]),
        "formatVersion": ESSAY_FORMAT_VERSION,
        "entryCount": len(parsed.entries),
        "frequencyMax": maximum_frequency,
        "retrievedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (destination / name).write_bytes(data)
    (destination / "SOURCE.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(
        f"fetch-essay: wrote {destination / ESSAY_PATH} "
        f"({manifest['sha256']}, {len(parsed.entries)} entries)"
    )
    return 0


def command_build(args: argparse.Namespace) -> int:
    required_paths = {
        "terra source": args.terra_source,
        "terra manifest": args.terra_manifest,
        "essay source": args.essay_source,
        "essay manifest": args.essay_manifest,
    }
    for label, path in required_paths.items():
        if not Path(path).exists():
            print(f"build: {label} not found: {path}", file=sys.stderr)
            return 2
    try:
        result = build_database(
            Path(args.terra_source),
            Path(args.terra_manifest),
            Path(args.essay_source),
            Path(args.essay_manifest),
            Path(args.output),
            Path(args.report),
        )
    except CompileFailure as failure:
        print("build: failed:", file=sys.stderr)
        for line in str(failure).splitlines():
            print(f"  {line}", file=sys.stderr)
        return 1
    print(
        f"build: {result.compiled_entries} entries compiled, "
        f"{result.essay_annotated_entries}/{result.essay_entries} essay entries annotated, "
        f"{result.merged_terra_essay_entries} terra+essay merges, "
        f"{result.database_bytes} bytes"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Compile the pinned Rime Terra Pinyin and Rime Essay sources into a SQLite dictionary"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    fetch_terra = subparsers.add_parser(
        "fetch-terra", help="download the pinned Terra dictionary and license"
    )
    fetch_terra.add_argument("--commit", required=True)
    fetch_terra.add_argument("--dest", default="Vendor/rime-terra-pinyin")
    fetch_terra.set_defaults(func=command_fetch_terra)

    fetch_essay = subparsers.add_parser(
        "fetch-essay", help="download the pinned Essay vocabulary and license"
    )
    fetch_essay.add_argument("--commit", required=True)
    fetch_essay.add_argument("--dest", default="Vendor/rime-essay")
    fetch_essay.set_defaults(func=command_fetch_essay)

    build = subparsers.add_parser("build", help="build the SQLite dictionary without network access")
    build.add_argument("--terra-source", required=True)
    build.add_argument("--terra-manifest", required=True)
    build.add_argument("--essay-source", required=True)
    build.add_argument("--essay-manifest", required=True)
    build.add_argument("--output", required=True)
    build.add_argument("--report", required=True)
    build.set_defaults(func=command_build)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
