import Darwin
import Foundation

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    var authorizationBearerToken: String? {
        guard let value = headers["authorization"] else { return nil }
        let prefix = "Bearer "
        guard value.hasPrefix(prefix) else { return nil }
        return String(value.dropFirst(prefix.count))
    }
}

struct HTTPResponse {
    var status: String
    var contentType: String
    var body: Data

    static func text(status: String = "200 OK", contentType: String = "text/plain; charset=utf-8", _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: contentType, body: Data(body.utf8))
    }

    static func json<T: Encodable>(status: String = "200 OK", _ payload: T) -> HTTPResponse {
        let data = (try? JSONEncoder.guardian.encode(payload)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }
}

extension JSONEncoder {
    static let guardian: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

final class LightweightHTTPServer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let host: String
    private let port: UInt16
    private let logger: FileLogger
    private let handler: (HTTPRequest) -> HTTPResponse

    private var listenSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(host: String, port: UInt16, queueLabel: String, logger: FileLogger, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.host = host
        self.port = port
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
        self.logger = logger
        self.handler = handler
    }

    func start() throws {
        stop()

        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
        }

        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian

        let bindAddress = host == "0.0.0.0" ? "0.0.0.0" : host
        let conversion = bindAddress.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard conversion == 1 else {
            close(socketFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: [NSLocalizedDescriptionKey: "Invalid bind host: \(host)"])
        }

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(socketFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Bind failed on \(host):\(port)"])
        }

        guard listen(socketFD, SOMAXCONN) == 0 else {
            let code = errno
            close(socketFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Listen failed"])
        }

        let currentFlags = fcntl(socketFD, F_GETFL, 0)
        guard currentFlags >= 0, fcntl(socketFD, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            let code = errno
            close(socketFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Failed to configure non-blocking listener"])
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.setCancelHandler {
            close(socketFD)
        }
        source.resume()

        listenSocket = socketFD
        acceptSource = source
        logger.write("HTTP server started host=\(host) port=\(port)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenSocket >= 0 {
            close(listenSocket)
            listenSocket = -1
        }
    }

    private func acceptConnections() {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenSocket, $0, &length)
                }
            }

            if client < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { break }
                break
            }

            queue.async { [weak self] in
                self?.handleClient(client)
            }
        }
    }

    private func handleClient(_ client: Int32) {
        defer { close(client) }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        let bytesRead = recv(client, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return }

        let data = Data(buffer.prefix(bytesRead))
        guard let requestString = String(data: data, encoding: .utf8),
              let request = Self.parse(requestString: requestString, rawData: data) else {
            return
        }

        let response = handler(request)
        let payload = serialized(response: response)
        payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = send(client, base, rawBuffer.count, 0)
        }
    }

    private func serialized(response: HTTPResponse) -> Data {
        var text = "HTTP/1.1 \(response.status)\r\n"
        text += "Content-Type: \(response.contentType)\r\n"
        text += "Content-Length: \(response.body.count)\r\n"
        text += "Connection: close\r\n\r\n"
        var data = Data(text.utf8)
        data.append(response.body)
        return data
    }

    static func parse(requestString: String, rawData: Data) -> HTTPRequest? {
        let parts = requestString.components(separatedBy: "\r\n\r\n")
        guard let headerText = parts.first else { return nil }
        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return nil }
        let segments = requestLine.split(separator: " ")
        guard segments.count >= 2 else { return nil }

        let method = String(segments[0])
        let rawTarget = String(segments[1])
        let components = rawTarget.split(separator: "?", maxSplits: 1).map(String.init)
        let path = components[0]
        var query: [String: String] = [:]
        if let queryString = components[safe: 1] {
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if let key = kv.first {
                    query[key.removingPercentEncoding ?? key] = kv[safe: 1]?.removingPercentEncoding ?? ""
                }
            }
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let body = parts.count > 1 ? Data(parts[1].utf8) : Data()
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }
}
