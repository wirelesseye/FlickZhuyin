"""Read librime-octagram `.gram` files and write FlickZhuyin's FZGram format.

The upstream file is a darts-clone double-array trie behind a small header
(see librime-octagram src/gram_db.cc). Keys are stored in octagram's compact
encoding (src/gram_encoding.cc); values are `max(0, int(ln(x) * 10000))`.

FZGram v1 (little-endian, sections 4-byte aligned):

    header (64 bytes)
      0  magic               8 bytes  b"FZGRAM\\0\\0"
      8  formatVersion       u32
     12  compilerVersion     u32
     16  keyCount            u32
     20  valueBase           u32
     24  valueShift          u32
     28  blockSize           u32   keys per front-coded block
     32  blockCount          u32
     36  blockOffsetsOffset  u32   (blockCount + 1) x u32, relative to blocks
     40  blocksOffset        u32
     44  blocksSize          u32
     48  valuesOffset        u32   keyCount x u16, in key order
     52  blockPrefixesOffset u32   blockCount x u64, see below
     56  reserved            8 bytes (zero)

Keys are UTF-8, sorted bytewise and split into blocks of `blockSize`. A
block's first key is stored as `len:u8, bytes`; each following key as
`shared:u8, suffixLength:u8, suffix`, where `shared` is the length of the
prefix it has in common with the previous key.

`blockPrefixes[i]` is the first 8 bytes of block i's first key, zero-padded
and read as a big-endian integer, so comparing integers orders blocks like
their keys (keys never contain NUL). Binary search runs over this compact
array and touches the large block area only to break ties and to scan.

A stored value decodes as `valueBase + (stored << valueShift)`.
"""
from __future__ import annotations

import struct
import sys
from array import array
from collections.abc import Iterable, Iterator
from pathlib import Path

GRAM_FORMAT_PREFIX = b"Rime::Grammar/"
GRAM_HEADER_BYTES = 44
MAX_ENCODED_UNICODE = 8

FZGRAM_MAGIC = b"FZGRAM\x00\x00"
FZGRAM_FORMAT_VERSION = 1
FZGRAM_HEADER_BYTES = 64
FZGRAM_HEADER = struct.Struct("<8s12I8x")
FZGRAM_DEFAULT_BLOCK_SIZE = 16


class GramFormatError(Exception):
    pass


# --- octagram key encoding -------------------------------------------------

def encode_key(text: str) -> bytes:
    """Port of grammar::encode."""
    out = bytearray()
    for character in text:
        u = ord(character)
        if u < 0x80:
            out.append(0xE0 if u == 0 else u)
        elif 0x4000 <= u < 0xA000:
            if u & 0xFF == 0:
                out += bytes((0xE1, (u >> 8) + 0x40))
            else:
                out += bytes(((u >> 8) + 0x40, u & 0xFF))
        else:
            bits = 32
            while bits > 0 and u & 0xFE000000 == 0:
                bits -= 7
                u = (u << 7) & 0xFFFFFFFF
            count = (bits + 6) // 7
            out.append(0xE0 | count)
            while count > 0:
                count -= 1
                out.append(((u >> 25) & 0x7F) | 0x80)
                u = (u << 7) & 0xFFFFFFFF
    return bytes(out)


def decode_key(data: bytes) -> str:
    """Inverse of encode_key."""
    characters = []
    index = 0
    length = len(data)
    while index < length:
        lead = data[index]
        if lead & 0x80 == 0:
            characters.append(chr(lead))
            index += 1
        elif lead == 0xE0:
            characters.append("\x00")
            index += 1
        elif lead == 0xE1:
            if index + 1 >= length:
                raise GramFormatError(f"truncated key {data!r}")
            characters.append(chr((data[index + 1] - 0x40) << 8))
            index += 2
        elif lead & 0xF0 == 0xE0:
            count = lead & 0x0F
            if count == 0 or index + count >= length:
                raise GramFormatError(f"truncated key {data!r}")
            groups = 0
            for byte in data[index + 1:index + 1 + count]:
                if byte & 0x80 == 0:
                    raise GramFormatError(f"malformed key {data!r}")
                groups = (groups << 7) | (byte & 0x7F)
            bits = 7 * count
            aligned = (groups << (32 - bits)) if bits <= 32 else (groups >> (bits - 32))
            aligned &= 0xFFFFFFFF
            characters.append(chr(aligned >> (7 * (5 - count))))
            index += 1 + count
        else:
            if index + 1 >= length:
                raise GramFormatError(f"truncated key {data!r}")
            characters.append(chr(((lead - 0x40) << 8) | data[index + 1]))
            index += 2
    return "".join(characters)


# --- upstream .gram reader ------------------------------------------------

def read_gram_units(data: bytes) -> array:
    if len(data) < GRAM_HEADER_BYTES or not data.startswith(GRAM_FORMAT_PREFIX):
        raise GramFormatError("not a Rime::Grammar file")
    unit_count, relative_offset = struct.unpack_from("<Ii", data, 36)
    start = 40 + relative_offset
    end = start + unit_count * 4
    if unit_count == 0 or start < GRAM_HEADER_BYTES or end > len(data):
        raise GramFormatError("double array out of bounds")
    units = array("I")
    units.frombytes(data[start:end])
    if units.itemsize != 4:
        raise GramFormatError("unsupported platform: array('I') is not 32-bit")
    if sys.byteorder != "little":
        units.byteswap()
    return units


def iterate_gram_entries(units: array) -> Iterator[tuple[bytes, int]]:
    """Yield (encoded key, value) for every key in a darts-clone array."""
    count = len(units)

    def offset(unit: int) -> int:
        return (unit >> 10) << ((unit & 0x200) >> 6)

    # A child with label c lives at `base ^ c`, which only flips the low 8
    # bits, so every child of `base` sits in base's 256-unit block and
    # satisfies `(index & 0xFF) ^ label == base & 0xFF`. Precomputing that
    # byte per unit lets bytes.find locate children at C speed instead of
    # probing 255 labels per node, in one byte per unit of memory. Units that
    # are not children (unused, or value units with bit 31 set) get
    # `index & 0xFF`, which can only match index == base, excluded below.
    parent_low = bytearray(index & 0xFF for index in range(256)) * ((count + 255) // 256)
    del parent_low[count:]
    for index, unit in enumerate(units):
        label = unit & 0x800000FF
        if 0 < label < 0x100:
            parent_low[index] = (index & 0xFF) ^ label

    stack: list[tuple[int, bytes]] = [(0, b"")]
    while stack:
        node, key = stack.pop()
        unit = units[node]
        base = node ^ offset(unit)
        if base >= count:
            raise GramFormatError("node offset out of bounds")
        if (unit >> 8) & 1 and key:
            yield key, units[base] & 0x7FFFFFFF
        block_start = base & ~0xFF
        block_end = min(block_start + 256, count)
        target = base & 0xFF
        children = []
        position = parent_low.find(target, block_start, block_end)
        while position >= 0:
            if position != base:
                children.append(position)
            position = parent_low.find(target, position + 1, block_end)
        # Push in descending label order so keys come out sorted.
        for child in sorted(children, key=lambda index: index ^ base, reverse=True):
            stack.append((child, key + bytes((child ^ base,))))


def read_gram(path: Path) -> Iterator[tuple[str, int]]:
    units = read_gram_units(Path(path).read_bytes())
    for key, value in iterate_gram_entries(units):
        yield decode_key(key), value


# --- FZGram writer / reader -----------------------------------------------

def value_shift_for(minimum: int, maximum: int) -> int:
    shift = 0
    while (maximum - minimum) >> shift > 0xFFFF:
        shift += 1
    return shift


def _aligned(size: int) -> int:
    return (size + 3) & ~3


def _aligned8(size: int) -> int:
    return (size + 7) & ~7


def block_prefix(key: bytes) -> int:
    return int.from_bytes(key[:8].ljust(8, b"\x00"), "big")


def _shared_prefix_length(a: bytes, b: bytes) -> int:
    limit = min(len(a), len(b))
    index = 0
    while index < limit and a[index] == b[index]:
        index += 1
    return index


def write_fzgram(
    entries: Iterable[tuple[str, int]],
    compiler_version: int,
    block_size: int = FZGRAM_DEFAULT_BLOCK_SIZE,
) -> bytes:
    """Serialize (key, value) pairs; keys must be unique, non-empty, free of
    NUL and at most 255 UTF-8 bytes. `entries` is consumed once, so it can be
    a generator over millions of keys."""
    if not 1 <= block_size <= 0xFFFF:
        raise GramFormatError(f"invalid block size {block_size}")
    # One bytes object per entry, `key NUL value`, keeps memory to roughly
    # the key bytes. NUL sorts below every UTF-8 byte of a NUL-free key, so
    # these sort exactly like the keys alone.
    records = []
    for key, value in entries:
        encoded = key.encode("utf-8")
        if not encoded or len(encoded) > 0xFF or b"\x00" in encoded:
            raise GramFormatError(f"key is empty, contains NUL or is too long: {key!r}")
        if not 0 <= value <= 0xFFFFFFFF:
            raise GramFormatError(f"value out of range for {key!r}: {value}")
        records.append(encoded + b"\x00" + value.to_bytes(4, "little"))
    if not records:
        raise GramFormatError("no entries")
    records.sort()

    values = array("I")
    previous = None
    for record in records:
        key = record[:-5]
        if key == previous:
            raise GramFormatError(f"duplicate key {key.decode('utf-8')!r}")
        previous = key
        values.append(int.from_bytes(record[-4:], "little"))
    value_base = min(values)
    value_shift = value_shift_for(value_base, max(values))

    blocks = bytearray()
    block_offsets = array("I")
    for start in range(0, len(records), block_size):
        block_offsets.append(len(blocks))
        previous = b""
        for index, record in enumerate(records[start:start + block_size]):
            key = record[:-5]
            if index == 0:
                blocks.append(len(key))
                blocks += key
            else:
                shared = _shared_prefix_length(previous, key)
                blocks += bytes((shared, len(key) - shared))
                blocks += key[shared:]
            previous = key
    block_offsets.append(len(blocks))
    block_prefixes = array("Q")
    for start in range(0, len(records), block_size):
        block_prefixes.append(block_prefix(records[start][:-5]))
    stored = array("H", ((value - value_base) >> value_shift for value in values))
    if sys.byteorder != "little":
        block_offsets.byteswap()
        block_prefixes.byteswap()
        stored.byteswap()

    block_offsets_offset = FZGRAM_HEADER_BYTES
    blocks_offset = block_offsets_offset + len(block_offsets) * 4
    values_offset = _aligned(blocks_offset + len(blocks))
    block_prefixes_offset = _aligned8(values_offset + len(stored) * 2)
    header = FZGRAM_HEADER.pack(
        FZGRAM_MAGIC,
        FZGRAM_FORMAT_VERSION,
        compiler_version,
        len(records),
        value_base,
        value_shift,
        block_size,
        len(block_offsets) - 1,
        block_offsets_offset,
        blocks_offset,
        len(blocks),
        values_offset,
        block_prefixes_offset,
    )
    output = bytearray(header)
    output += block_offsets.tobytes()
    output += blocks
    output += b"\x00" * (values_offset - len(output))
    output += stored.tobytes()
    output += b"\x00" * (block_prefixes_offset - len(output))
    output += block_prefixes.tobytes()
    return bytes(output)


class FZGram:
    """Pure-Python reader that mirrors the Swift lookup, for tests and reports."""

    def __init__(self, data: bytes) -> None:
        if len(data) < FZGRAM_HEADER_BYTES:
            raise GramFormatError("truncated header")
        (
            magic,
            format_version,
            self.compiler_version,
            self.key_count,
            self.value_base,
            self.value_shift,
            self.block_size,
            self.block_count,
            block_offsets_offset,
            blocks_offset,
            blocks_size,
            values_offset,
            block_prefixes_offset,
        ) = FZGRAM_HEADER.unpack_from(data)
        if magic != FZGRAM_MAGIC or format_version != FZGRAM_FORMAT_VERSION:
            raise GramFormatError("not an FZGram v1 file")
        if values_offset + self.key_count * 2 > len(data):
            raise GramFormatError("values out of bounds")
        self.block_offsets = struct.unpack_from(
            f"<{self.block_count + 1}I", data, block_offsets_offset
        )
        self.blocks = data[blocks_offset:blocks_offset + blocks_size]
        self.values = struct.unpack_from(f"<{self.key_count}H", data, values_offset)
        if block_prefixes_offset + self.block_count * 8 > len(data):
            raise GramFormatError("block prefixes out of bounds")
        self.block_prefixes = struct.unpack_from(f"<{self.block_count}Q", data, block_prefixes_offset)

    def _block_keys(self, block: int) -> Iterator[bytes]:
        position = self.block_offsets[block]
        end = self.block_offsets[block + 1]
        length = self.blocks[position]
        key = self.blocks[position + 1:position + 1 + length]
        position += 1 + length
        yield key
        while position < end:
            shared, suffix = self.blocks[position], self.blocks[position + 1]
            key = key[:shared] + self.blocks[position + 2:position + 2 + suffix]
            position += 2 + suffix
            yield key

    def _first_key(self, block: int) -> bytes:
        position = self.block_offsets[block]
        return self.blocks[position + 1:position + 1 + self.blocks[position]]

    def items(self) -> Iterator[tuple[str, int]]:
        index = 0
        for block in range(self.block_count):
            for key in self._block_keys(block):
                yield key.decode("utf-8"), self._decoded_value(index)
                index += 1

    def _decoded_value(self, index: int) -> int:
        return self.value_base + (self.values[index] << self.value_shift)

    def value(self, key: str) -> int | None:
        target = key.encode("utf-8")
        low, high = 0, self.block_count
        while low < high:
            middle = (low + high) // 2
            if self._first_key(middle) <= target:
                low = middle + 1
            else:
                high = middle
        block = low - 1
        if block < 0:
            return None
        for offset, candidate in enumerate(self._block_keys(block)):
            if candidate == target:
                return self._decoded_value(block * self.block_size + offset)
            if candidate > target:
                return None
        return None
