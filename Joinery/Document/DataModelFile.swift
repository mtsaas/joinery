import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let joineryDataModel = UTType(exportedAs: "com.clarkmccauley.joinery.schema")
}

extension DataModel {
    /// Reads a `.joinery` file, dropping anything it refers to that isn't there.
    init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(DataModel.self, from: Data(contentsOf: url))
        repair()
    }

    /// Writes it as a `.joinery` file: readable JSON, keys sorted so changes diff cleanly. Written whole to a new file
    /// that then replaces the old, so it's never half written; the library's own marks on the old one (favorite, last
    /// opened) are carried over, as the new file wouldn't have them.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let marks = url.extendedAttributeNames.filter { $0.hasPrefix(URL.attributePrefix) }
            .compactMap { name in url.extendedAttribute(name).map { (name, $0) } }
        try encoder.encode(self).write(to: url, options: .atomic)
        for (name, value) in marks { url.setExtendedAttribute(name, to: value) }
    }
}

extension URL {
    /// Extended attributes the app keeps on files start with this.
    static let attributePrefix = "com.clarkmccauley.joinery."

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
