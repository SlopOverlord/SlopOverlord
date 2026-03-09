import Foundation

public struct OpenAPISpec: Encodable {
    public let openapi: String = "3.0.0"
    public let info: OpenAPIInfo
    public let paths: [String: OpenAPIPathItem]
}

public struct OpenAPIInfo: Encodable {
    public let title: String
    public let version: String
}

public struct OpenAPIPathItem: Encodable {
    public var get: OpenAPIOperation?
    public var post: OpenAPIOperation?
    public var put: OpenAPIOperation?
    public var patch: OpenAPIOperation?
    public var delete: OpenAPIOperation?

    public mutating func setOperation(_ operation: OpenAPIOperation, for method: HTTPRouteMethod) {
        switch method {
        case .get: get = operation
        case .post: post = operation
        case .put: put = operation
        case .patch: patch = operation
        case .delete: delete = operation
        }
    }
}

public struct OpenAPIOperation: Encodable {
    public let summary: String?
    public let description: String?
    public let tags: [String]?
    public let responses: [String: OpenAPIResponse]
}

public struct OpenAPIResponse: Encodable {
    public let description: String
}

public struct OpenAPIGenerator {
    public static func generate(routes: [RouteDefinition]) -> OpenAPISpec {
        var paths: [String: OpenAPIPathItem] = [:]

        for route in routes {
            let path = normalizePath(route.path)
            var pathItem = paths[path] ?? OpenAPIPathItem()

            let operation = OpenAPIOperation(
                summary: route.metadata?.summary,
                description: route.metadata?.description,
                tags: route.metadata?.tags,
                responses: ["200": OpenAPIResponse(description: "Successful response")]
            )

            pathItem.setOperation(operation, for: route.method)
            paths[path] = pathItem
        }

        return OpenAPISpec(
            info: OpenAPIInfo(title: "Sloppy API", version: "1.0.0"),
            paths: paths
        )
    }

    private static func normalizePath(_ path: String) -> String {
        // Convert :param to {param}
        let segments = path.split(separator: "/").map { segment -> String in
            if segment.hasPrefix(":") {
                let param = segment.dropFirst()
                // Strip query if present (though routes usually don't have it)
                if let queryIndex = param.firstIndex(of: "?") {
                    return "{\(param[..<queryIndex])}"
                }
                return "{\(param)}"
            }
            return String(segment)
        }
        return "/" + segments.joined(separator: "/")
    }
}
