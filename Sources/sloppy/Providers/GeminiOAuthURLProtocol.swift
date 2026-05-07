import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class GeminiOAuthURLProtocol: URLProtocol {
    private var activeTask: URLSessionDataTask?
    private var activeSession: URLSession?
    private var activeDelegate: GeminiOAuthURLProtocolSessionDelegate?

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return false
        }
        guard let key = request.value(forHTTPHeaderField: "x-goog-api-key"),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let modified = Self.modifiedRequest(from: request)
        let configuration = URLSessionConfiguration.ephemeral
        let delegate = GeminiOAuthURLProtocolSessionDelegate(owner: self)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: modified)
        activeDelegate = delegate
        activeSession = session
        activeTask = task
        task.resume()
    }

    override func stopLoading() {
        activeTask?.cancel()
        activeSession?.invalidateAndCancel()
        activeDelegate = nil
        activeSession = nil
        activeTask = nil
    }

    fileprivate func didReceive(response: URLResponse) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    fileprivate func didReceive(data: Data) {
        client?.urlProtocol(self, didLoad: data)
    }

    fileprivate func didComplete(with error: Error?) {
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
        activeDelegate = nil
        activeSession = nil
        activeTask = nil
    }

    static func modifiedRequest(from request: URLRequest) -> URLRequest {
        var mutable = request
        let token = request.value(forHTTPHeaderField: "x-goog-api-key")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        mutable.setValue(nil, forHTTPHeaderField: "x-goog-api-key")
        mutable.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let userProject = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT_ID"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        if let userProject, !userProject.isEmpty {
            mutable.setValue(userProject, forHTTPHeaderField: "x-goog-user-project")
        }
        return mutable
    }
}

private final class GeminiOAuthURLProtocolSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private weak var owner: GeminiOAuthURLProtocol?

    init(owner: GeminiOAuthURLProtocol) {
        self.owner = owner
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        owner?.didReceive(response: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner?.didReceive(data: data)
    }

    #if canImport(Security)
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if SloppyExtraCertificateAuthority.handle(challenge: challenge, completionHandler: completionHandler) {
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
    #endif

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner?.didComplete(with: error)
        session.finishTasksAndInvalidate()
    }
}
