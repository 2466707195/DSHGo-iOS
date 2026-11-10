import Foundation

/// 本机 Wi-Fi 接口的 IPv4（诊断用）。
///
/// `en0` 在 iOS 上通常就是 Wi-Fi；蜂窝（pdp_ip*）与回环（lo0）跳过。
enum WiFiInfo {

    static func currentIPv4() -> (interface: String, address: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        var fallback: (String, String)?

        while let current = pointer {
            let interface = current.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("pdp_ip") || name == "lo0" {
                    pointer = interface.ifa_next
                    continue
                }
                var address = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    interface.ifa_addr,
                    socklen_t(interface.ifa_addr.pointee.sa_len),
                    &address,
                    socklen_t(address.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    let ip = String(cString: address)
                    if name == "en0" {
                        return (name, ip)
                    }
                    if fallback == nil {
                        fallback = (name, ip)
                    }
                }
            }
            pointer = interface.ifa_next
        }
        return fallback
    }
}
