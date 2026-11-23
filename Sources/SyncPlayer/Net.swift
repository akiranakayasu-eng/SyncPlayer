import Foundation
import Darwin

/// Small UDP socket on top of BSD sockets, read with a DispatchSource.
final class UDPSocket {
    let fd: Int32
    private var source: DispatchSourceRead?
    var onReceive: ((Data, sockaddr_in) -> Void)?

    /// port 0 = any free port. reusePort lets several processes on one Mac share the beacon port.
    init(port: UInt16, reusePort: Bool = false, broadcast: Bool = false) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw NSError(domain: "udp", code: Int(errno)) }
        var one: Int32 = 1
        if reusePort {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        if broadcast {
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else { close(fd); throw NSError(domain: "udp.bind", code: Int(errno)) }
    }

    func start(queue: DispatchQueue) {
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 2048)
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(self.fd, &buf, buf.count, 0, $0, &len)
                }
            }
            if n > 0 { self.onReceive?(Data(buf[0..<n]), from) }
        }
        s.resume()
        source = s
    }

    func send(_ data: Data, to addr: sockaddr_in) {
        var a = addr
        _ = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    static func address(_ host: String, _ port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &a.sin_addr)
        return a
    }

    static func withPort(_ addr: sockaddr_in, _ port: UInt16) -> sockaddr_in {
        var a = addr
        a.sin_port = port.bigEndian
        return a
    }

    static func hostString(_ addr: sockaddr_in) -> String {
        var a = addr.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}
