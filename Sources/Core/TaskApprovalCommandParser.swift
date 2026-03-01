import Foundation

enum TaskApprovalReference: Equatable {
    case index(Int)
    case taskID(String)
}

enum TaskApprovalCommandParser {
    static func parse(_ content: String) -> TaskApprovalReference? {
        let pattern = #"^\s*(pick\s*up|pickup|возьми|запусти)\s+#([A-Za-z0-9._-]+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        guard let match = regex.firstMatch(in: content, options: [], range: fullRange),
              match.numberOfRanges > 2
        else {
            return nil
        }

        let tokenRange = match.range(at: 2)
        guard tokenRange.location != NSNotFound else {
            return nil
        }

        let token = nsContent.substring(with: tokenRange).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return nil
        }

        if let index = Int(token), index > 0 {
            return .index(index)
        }

        return .taskID(token)
    }
}
