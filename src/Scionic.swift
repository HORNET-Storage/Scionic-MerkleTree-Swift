/// The library's version, and the numbers the format fixes.
///
/// `spec/FORMAT.md` in this repository says exactly what each hash covers.
public enum Scionic {
    /// The version of this library, the same in the Rust and Go libraries.
    public static let version = "2.5.6"

    /// The most bytes a chunk may hold: 8 MiB.
    public static let maxChunkBytes = FastCDC.maxSize
    /// How many bytes one item of a file's list takes: a hash and a length.
    public static let listItemBytes = 36
    /// The most bytes a name may hold.
    public static let maxNameBytes = 255
    /// The most values a set of extra data may hold.
    public static let maxExtraValues = 32
    /// The most bytes the name of an extra value may hold.
    public static let maxExtraNameBytes = 64
    /// The most bytes an extra value may hold.
    public static let maxExtraValueBytes = 1024
    /// The most folders that may sit inside one another, the top one counted.
    public static let maxFolderDepth = 128
    /// The most nodes a branch may carry: 40 on each side of what it shows.
    public static let maxCarriedNodes = 80
    /// The most items a list may hold. It bounds how deep any walk goes.
    public static let maxListItems: UInt64 = 1 << 40
    /// The most bytes a set of extra data may take: how many values it has,
    /// and 32 values that are as long as they can be.
    public static let maxExtraBytes = 2 + maxExtraValues * (4 + maxExtraNameBytes + maxExtraValueBytes)
    /// The most bytes a record may take: its fixed part, and extra data that
    /// is as full as it can be.
    public static let maxRecordBytes = 66 + maxExtraBytes
    /// The most bytes a folder's entry may take: its fixed part, the longest
    /// name, and extra data that is as full as it can be.
    public static let maxEntryBytes = 43 + maxNameBytes + maxExtraBytes
    /// The extra value of a record that says how the tree's files were chunked.
    public static let chunkingKey = "chunking"
    /// The extra value of a record that says when the tree was built.
    public static let timestampKey = "timestamp"
    /// How a tree says that its files were chunked by content.
    public static let chunkingFastCDCv1 = "fastcdc-v1"
}
