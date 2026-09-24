import Darwin
import Foundation

enum GramStoreError: Error, Equatable {
    case resourceNotFound(String)
    case openFailed(String)
    case invalidFormat(String)
}

/// Read-only view of an FZGram file (see Tools/DictionaryCompiler/octagram.py).
///
/// The file is memory-mapped, so its pages are clean and file-backed: the
/// system can evict them under memory pressure instead of charging them to the
/// keyboard extension.
final class MappedGramStore: @unchecked Sendable {
    struct LookupResult: Equatable {
        /// Octagram-scaled value (`ln(x) * 10000`) when the key exists.
        let value: Int?
        /// Whether some longer key starts with the looked-up key.
        let hasExtensions: Bool
    }

    static let magic: [UInt8] = Array("FZGRAM".utf8) + [0, 0]
    static let formatVersion: UInt32 = 1
    static let headerSize = 64

    let keyCount: Int
    let compilerVersion: Int

    private let mapping: UnsafeMutableRawPointer
    private let mappingSize: Int
    private let valueBase: Int
    private let valueShift: Int
    private let blockSize: Int
    private let blockCount: Int
    private let blockOffsets: UnsafePointer<UInt32>
    private let blocks: UnsafePointer<UInt8>
    private let blocksSize: Int
    private let values: UnsafePointer<UInt16>
    /// First 8 bytes of each block's first key as big-endian integers, so the
    /// binary search stays in one small array instead of faulting in pages
    /// all over the block area.
    private let blockPrefixes: UnsafePointer<UInt64>

    convenience init(
        bundle: Bundle,
        resourceName: String = "flickzhuyin",
        resourceExtension: String = "gram"
    ) throws {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw GramStoreError.resourceNotFound("\(resourceName).\(resourceExtension)")
        }
        try self.init(url: url)
    }

    init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw GramStoreError.openFailed("\(url.lastPathComponent): errno \(errno)")
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw GramStoreError.openFailed("\(url.lastPathComponent): fstat errno \(errno)")
        }
        let size = Int(status.st_size)
        guard size >= Self.headerSize else {
            throw GramStoreError.invalidFormat("file is smaller than the header")
        }
        guard let pointer = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0),
              pointer != MAP_FAILED
        else {
            throw GramStoreError.openFailed("\(url.lastPathComponent): mmap errno \(errno)")
        }
        mapping = pointer
        mappingSize = size
        // Lookups hit pages all over the file, so a cold store would fault
        // them in one at a time; ask for asynchronous sequential readahead
        // instead. The pages stay clean and evictable.
        _ = madvise(pointer, size, MADV_WILLNEED)

        do {
            let base = UnsafeRawPointer(pointer)
            func u32(_ offset: Int) -> Int {
                Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            guard Array(UnsafeRawBufferPointer(start: base, count: 8)) == Self.magic else {
                throw GramStoreError.invalidFormat("bad magic")
            }
            guard u32(8) == Int(Self.formatVersion) else {
                throw GramStoreError.invalidFormat("unsupported format version \(u32(8))")
            }
            compilerVersion = u32(12)
            keyCount = u32(16)
            valueBase = u32(20)
            valueShift = u32(24)
            blockSize = u32(28)
            blockCount = u32(32)
            let blockOffsetsOffset = u32(36)
            let blocksOffset = u32(40)
            blocksSize = u32(44)
            let valuesOffset = u32(48)
            let blockPrefixesOffset = u32(52)

            guard keyCount > 0, blockSize > 0, valueShift < 16,
                  blockCount == (keyCount + blockSize - 1) / blockSize
            else {
                throw GramStoreError.invalidFormat("inconsistent key or block counts")
            }
            func fits(_ offset: Int, _ length: Int, alignment: Int) -> Bool {
                offset >= Self.headerSize && offset % alignment == 0
                    && length >= 0 && offset <= size && length <= size - offset
            }
            guard fits(blockOffsetsOffset, (blockCount + 1) * 4, alignment: 4),
                  fits(blocksOffset, blocksSize, alignment: 1),
                  fits(valuesOffset, keyCount * 2, alignment: 2),
                  fits(blockPrefixesOffset, blockCount * 8, alignment: 8)
            else {
                throw GramStoreError.invalidFormat("section out of bounds")
            }
            blockOffsets = base.advanced(by: blockOffsetsOffset).assumingMemoryBound(to: UInt32.self)
            blocks = base.advanced(by: blocksOffset).assumingMemoryBound(to: UInt8.self)
            values = base.advanced(by: valuesOffset).assumingMemoryBound(to: UInt16.self)
            blockPrefixes = base.advanced(by: blockPrefixesOffset).assumingMemoryBound(to: UInt64.self)

            var previous = 0
            for index in 0...blockCount {
                let offset = Int(UInt32(littleEndian: blockOffsets[index]))
                guard offset >= previous, offset <= blocksSize, index > 0 || offset == 0 else {
                    throw GramStoreError.invalidFormat("block offsets are not monotonic")
                }
                previous = offset
            }
            guard previous == blocksSize else {
                throw GramStoreError.invalidFormat("block offsets do not cover the blocks")
            }
        } catch {
            munmap(pointer, size)
            throw error
        }
    }

    deinit {
        munmap(mapping, mappingSize)
    }

    func value(forKey key: String) -> Int? {
        lookup(Array(key.utf8)).value
    }

    /// Looks up `key` (UTF-8) and reports whether any longer key extends it.
    func lookup(_ key: [UInt8]) -> LookupResult {
        guard !key.isEmpty else { return LookupResult(value: nil, hasExtensions: true) }
        return key.withUnsafeBufferPointer { target in
            let targetPrefix = Self.prefix(of: target)
            // Last block whose first key is <= target.
            var low = 0
            var high = blockCount
            while low < high {
                let middle = (low + high) / 2
                let blockPrefix = UInt64(littleEndian: blockPrefixes[middle])
                let isAtOrBefore = blockPrefix != targetPrefix
                    ? blockPrefix < targetPrefix
                    : compare(firstKeyOf: middle, target) <= 0
                if isAtOrBefore {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            let block = low - 1
            guard block >= 0 else {
                // Target sorts before every key; the first key may still extend it.
                return LookupResult(value: nil, hasExtensions: firstKey(of: 0, hasPrefix: target))
            }
            return scan(block: block, for: target)
        }
    }

    // MARK: - Block decoding

    private func blockRange(_ block: Int) -> (start: Int, end: Int) {
        (
            Int(UInt32(littleEndian: blockOffsets[block])),
            Int(UInt32(littleEndian: blockOffsets[block + 1]))
        )
    }

    private func compare(firstKeyOf block: Int, _ target: UnsafeBufferPointer<UInt8>) -> Int {
        let (start, end) = blockRange(block)
        guard start < end else { return 1 }
        let length = min(Int(blocks[start]), end - start - 1)
        let key = UnsafeBufferPointer(start: blocks + start + 1, count: length)
        return Self.compare(key, target)
    }

    private func firstKey(of block: Int, hasPrefix target: UnsafeBufferPointer<UInt8>) -> Bool {
        guard block < blockCount else { return false }
        let (start, end) = blockRange(block)
        guard start < end else { return false }
        let length = min(Int(blocks[start]), end - start - 1)
        guard length > target.count else { return false }
        return memcmp(blocks + start + 1, target.baseAddress!, target.count) == 0
    }

    private func scan(block: Int, for target: UnsafeBufferPointer<UInt8>) -> LookupResult {
        var (position, end) = blockRange(block)
        var key = [UInt8]()
        key.reserveCapacity(64)
        var index = 0
        var found: Int?
        while position < end {
            if index == 0 {
                let length = Int(blocks[position])
                guard position + 1 + length <= end else { break }
                key.append(contentsOf: UnsafeBufferPointer(start: blocks + position + 1, count: length))
                position += 1 + length
            } else {
                guard position + 2 <= end else { break }
                let shared = Int(blocks[position])
                let suffix = Int(blocks[position + 1])
                guard shared <= key.count, position + 2 + suffix <= end else { break }
                key.removeSubrange(shared...)
                key.append(contentsOf: UnsafeBufferPointer(start: blocks + position + 2, count: suffix))
                position += 2 + suffix
            }
            let order = key.withUnsafeBufferPointer { Self.compare($0, target) }
            if order == 0 {
                found = decodedValue(at: block * blockSize + index)
            } else if order > 0 {
                return LookupResult(value: found, hasExtensions: Self.hasPrefix(key, target))
            }
            index += 1
        }
        // Every key in this block sorts at or before the target; the next
        // block's first key is the only other key that can extend it.
        return LookupResult(value: found, hasExtensions: firstKey(of: block + 1, hasPrefix: target))
    }

    private func decodedValue(at index: Int) -> Int? {
        guard index < keyCount else { return nil }
        return valueBase + (Int(UInt16(littleEndian: values[index])) << valueShift)
    }

    private static func compare(_ lhs: UnsafeBufferPointer<UInt8>, _ rhs: UnsafeBufferPointer<UInt8>) -> Int {
        let shared = min(lhs.count, rhs.count)
        if shared > 0 {
            let order = memcmp(lhs.baseAddress!, rhs.baseAddress!, shared)
            if order != 0 { return Int(order) }
        }
        return lhs.count - rhs.count
    }

    /// The first 8 bytes of `key`, zero-padded, as a big-endian integer.
    private static func prefix(of key: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(index < key.count ? key[index] : 0)
        }
        return value
    }

    private static func hasPrefix(_ key: [UInt8], _ prefix: UnsafeBufferPointer<UInt8>) -> Bool {
        guard key.count > prefix.count else { return false }
        for index in 0..<prefix.count where key[index] != prefix[index] {
            return false
        }
        return true
    }
}
