import Foundation

nonisolated struct TranslationHTTPPayload: Sendable {
    let status: Int
    let data: Data
}

/// Single-attempt JSON transport for dedicated translation APIs. Error bodies
/// are bounded separately and only inspected by fixed-code error mappers.
nonisolated enum BoundedTranslationHTTPTransport {
    static let maximumResponseBytes = 4_194_304
    static let maximumErrorBytes = 65_536

    static func send(
        _ request: URLRequest,
        session injectedSession: URLSession? = nil,
        maximumResponseBytes responseLimit: Int = maximumResponseBytes
    ) async throws -> TranslationHTTPPayload {
        try Task.checkCancellation()
        guard responseLimit > 0, responseLimit <= maximumResponseBytes else { throw RemoteTranslationError.responseTooLarge }
        let session = injectedSession ?? URLSession(configuration: TranslationHTTPPolicy.sessionConfiguration())
        defer { if injectedSession == nil { session.invalidateAndCancel() } }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: TranslationRedirectGuard())
            let task = bytes.task
            defer { task.cancel() }
            return try await withTaskCancellationHandler {
                guard let http = response as? HTTPURLResponse else { throw RemoteTranslationError.invalidResponse }
                guard http.url == request.url, !(300...399).contains(http.statusCode) else {
                    throw RemoteTranslationError.redirected
                }
                let succeeded = (200...299).contains(http.statusCode)
                if succeeded && http.mimeType?.lowercased() != "application/json" {
                    throw RemoteTranslationError.invalidResponse
                }
                let limit = succeeded ? responseLimit : maximumErrorBytes
                if succeeded && http.expectedContentLength > Int64(limit) { throw RemoteTranslationError.responseTooLarge }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    if data.count == limit {
                        if succeeded { throw RemoteTranslationError.responseTooLarge }
                        break
                    }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return TranslationHTTPPayload(status: http.statusCode, data: data)
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RemoteTranslationError {
            throw error
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            switch error.code {
            case .timedOut: throw RemoteTranslationError.timedOut
            case .notConnectedToInternet: throw RemoteTranslationError.offline
            default: throw RemoteTranslationError.connectionFailed
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw RemoteTranslationError.connectionFailed
        }
    }
}
