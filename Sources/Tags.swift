import Foundation
import SwiftUI

/// The four rating levels. Each one is stored on the file as a Finder tag.
enum Rating: Int, CaseIterable, Identifiable {
    case delete = 1, heavyEdit, lightEdit, great

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .delete: return "Delete"
        case .heavyEdit: return "Heavy edit"
        case .lightEdit: return "Light edit"
        case .great: return "Great"
        }
    }

    /// The Finder tag name, e.g. "3 Light edit".
    var tagName: String { "\(rawValue) \(label)" }

    /// Finder's colour index: 2 green, 5 yellow, 6 red, 7 orange.
    var finderColor: Int {
        switch self {
        case .delete: return 6
        case .heavyEdit: return 7
        case .lightEdit: return 5
        case .great: return 2
        }
    }

    var color: Color {
        switch self {
        case .delete: return .red
        case .heavyEdit: return .orange
        case .lightEdit: return .yellow
        case .great: return .green
        }
    }
}

/// Reads and writes Finder tags directly, so each tag gets a colour and any
/// other tags already on the file are left alone.
enum FinderTags {
    private static let key = "com.apple.metadata:_kMDItemUserTags"
    private static let ratingNames = Set(Rating.allCases.map(\.tagName))

    private static func name(of raw: String) -> String {
        raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
    }

    static func rawTags(_ url: URL) -> [String] {
        let path = url.path
        let size = getxattr(path, key, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, key, $0.baseAddress, size, 0, 0) }
        guard read > 0,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return list
    }

    static func rating(of url: URL) -> Rating? {
        for raw in rawTags(url) {
            let n = name(of: raw)
            if let r = Rating.allCases.first(where: { $0.tagName == n }) { return r }
        }
        return nil
    }

    static func setRating(_ rating: Rating?, on url: URL) throws {
        let path = url.path
        var tags = rawTags(url).filter { !ratingNames.contains(name(of: $0)) }
        if let rating { tags.append("\(rating.tagName)\n\(rating.finderColor)") }
        if tags.isEmpty {
            if removexattr(path, key, 0) != 0 && errno != ENOATTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
        let rc = data.withUnsafeBytes { setxattr(path, key, $0.baseAddress, data.count, 0, 0) }
        if rc != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
