import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let joineryDataModel = UTType(exportedAs: "com.mtsaas.joinery.schema")
}

/// A `.joinery` data model is a package, a folder Finder shows as one file: the model, as `model.json`, and its earlier
/// versions (see `History`), so wherever the file goes, its history goes too. Before there were versions, it was the
/// model alone, as a file; those still open, and become packages when next written.
extension DataModel {
    /// Reads a `.joinery` package, or file from before packages, dropping anything it refers to that isn't there.
    init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(DataModel.self, from: Data(contentsOf: url.isPackage ? url.appending(path: Self.packagedName) : url))
        repair()
    }

    /// The model's file in a package.
    static let packagedName = "model.json"

    /// Writes it into a `.joinery` package as readable JSON, keys sorted so changes diff cleanly. Written whole to a new
    /// file that then replaces the old, so it's never half written. Only the model is replaced, so the package keeps its
    /// versions and the library's marks on it (favorite, last opened). A file from before packages becomes one, its
    /// marks carried over.
    func write(to url: URL) throws {
        let files = FileManager.default
        if url.isPackage {
            try fileData.write(to: url.appending(path: Self.packagedName), options: .atomic)
        } else {
            // Made beside it, hidden, then swapped in, so the model is on disk throughout.
            let marks = url.extendedAttributeNames.filter { $0.hasPrefix(URL.attributePrefix) }
                .compactMap { name in url.extendedAttribute(name).map { (name, $0) } }
            let package = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).joinery", directoryHint: .isDirectory)
            try files.createDirectory(at: package, withIntermediateDirectories: false)
            try fileData.write(to: package.appending(path: Self.packagedName), options: .atomic)
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
            try files.moveItem(at: package, to: url)
            for (name, value) in marks { url.setExtendedAttribute(name, to: value) }
        }
    }

    /// What a `.joinery` file of it holds.
    var fileData: Data {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }
    }
}

extension URL {
    /// Extended attributes the app keeps on files start with this.
    static let attributePrefix = "com.mtsaas.joinery."

    /// Whether it's a folder, as a `.joinery` package is (as it is now, on disk, not as the URL was spelled).
    var isPackage: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var extendedAttributeNames: [String] {
        withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let size = listxattr(path, nil, 0, 0)
            guard size > 0 else { return [] }
            var names = [CChar](repeating: 0, count: size)
            guard listxattr(path, &names, size, 0) == size else { return [] }
            // One after another, each ending in a zero.
            return names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        }
    }

    func extendedAttribute(_ name: String) -> Data? {
        withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size >= 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            return read >= 0 ? data : nil
        }
    }

    /// Sets it, or removes it for nil.
    func setExtendedAttribute(_ name: String, to data: Data?) {
        withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            if let data {
                _ = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
            } else {
                removexattr(path, name, 0)
            }
        }
    }
}
