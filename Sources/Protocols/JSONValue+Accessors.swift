import Foundation

public extension JSONValue {
    var asString: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    var asBool: Bool? {
        guard case .bool(let value) = self else {
            return nil
        }
        return value
    }

    var asNumber: Double? {
        guard case .number(let value) = self else {
            return nil
        }
        return value
    }

    var asInt: Int? {
        guard case .number(let value) = self else {
            return nil
        }
        return Int(value)
    }

    var asObject: [String: JSONValue]? {
        guard case .object(let value) = self else {
            return nil
        }
        return value
    }

    var asArray: [JSONValue]? {
        guard case .array(let value) = self else {
            return nil
        }
        return value
    }
}
