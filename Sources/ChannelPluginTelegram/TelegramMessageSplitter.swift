import Foundation

enum TelegramMessageSplitter {
    static let maxCharacters = 4096

    static func split(_ text: String, maxCharacters: Int = Self.maxCharacters) -> [String] {
        guard maxCharacters > 0 else { return [text] }
        guard text.count > maxCharacters else { return [text] }

        var chunks: [String] = []
        var remaining = text[...]

        while remaining.count > maxCharacters {
            let limitIndex = remaining.index(remaining.startIndex, offsetBy: maxCharacters)
            let splitIndex = preferredSplitIndex(in: remaining, before: limitIndex)
            let chunk = String(remaining[..<splitIndex])
            chunks.append(chunk)

            remaining = remaining[splitIndex...]
        }

        if !remaining.isEmpty {
            chunks.append(String(remaining))
        }

        return chunks
    }

    private static func preferredSplitIndex(in text: Substring, before limitIndex: String.Index) -> String.Index {
        let minimumUsefulSplit = text.index(
            text.startIndex,
            offsetBy: max(1, text.distance(from: text.startIndex, to: limitIndex) / 2)
        )

        let searchRange = text.startIndex..<limitIndex
        for separator in ["\n\n", "\n", " "] {
            if let range = text.range(of: separator, options: .backwards, range: searchRange),
               range.upperBound > minimumUsefulSplit {
                return range.upperBound
            }
        }

        return limitIndex
    }
}
