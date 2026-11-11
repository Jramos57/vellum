import Foundation

/// Resource limits applied while reading ZIP-based publications (EPUB, Vellum archives).
///
/// A ZIP central directory can declare arbitrary 32-bit uncompressed sizes, so a tiny
/// hostile archive can advertise a multi-gigabyte entry. These limits let the reader
/// reject those declarations up front and bound the decompressor's runtime output,
/// instead of trusting the declared size when reserving memory. The limits are also
/// enforced on a per-archive aggregate so many individually valid entries cannot sum
/// to an unbounded allocation.
struct ZIPResourceLimits {
    /// Maximum uncompressed size, in bytes, allowed for a single ZIP entry.
    var maxEntryByteCount: Int
    /// Maximum sum of declared uncompressed sizes, in bytes, across all entries.
    var maxTotalByteCount: Int

    init(maxEntryByteCount: Int, maxTotalByteCount: Int) {
        self.maxEntryByteCount = maxEntryByteCount
        self.maxTotalByteCount = maxTotalByteCount
    }

    /// Defaults chosen for a personal-library reader that must still open media-heavy
    /// EPUB 3 books (narration tracks, video): 512 MiB for any single entry and 2 GiB
    /// for the sum of all declared uncompressed entries in one archive. The inflater
    /// reserves at most 1 MiB up front and grows only with real output, so a hostile
    /// size declaration alone cannot claim this much memory.
    /// On 32-bit watchOS (`arm64_32`), where `Int` can't hold 2 GiB, the
    /// aggregate is clamped to `Int.max`, just under it.
    static let `default` = ZIPResourceLimits(
        maxEntryByteCount: 512 * 1024 * 1024,
        maxTotalByteCount: Int(clamping: Int64(2) * 1024 * 1024 * 1024)
    )
}
