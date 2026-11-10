import Foundation

/// 连接清单的持久化：地址簿 + 每台的在线探测结果缓存。
///
/// 多台电脑各存一条；**多地址自动选路**：家里局域网、出门 Tailscale 都记着，
/// 当前地址能用就不动，连不上才切。
final class ComputerStore: ObservableObject {

    @Published var computers: [DSHComputer] = []

    private static let key = "dshgo.computers.v1"

    var active: DSHComputer? {
        computers.first { $0.isActive }
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let list = try? JSONDecoder().decode([DSHComputer].self, from: data) else {
            return
        }
        computers = list
    }

    func save() {
        guard let data = try? JSONEncoder().encode(computers) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    // MARK: - 增删

    /// 从 `http://192.168.1.100:3081` 这样的地址创建一条连接。
    @discardableResult
    func add(name: String?, host: String, port: Int, tailscaleHost: String? = nil, tailscalePort: Int? = nil) -> DSHComputer {
        let computer = DSHComputer(
            id: "\(host)-\(port)-\(UUID().uuidString.prefix(6))",
            name: name ?? "\(host):\(port)",
            host: host,
            port: port,
            tailscaleHost: tailscaleHost,
            tailscalePort: tailscalePort,
            lastSeen: Date(),
            pluginVersion: nil,
            isOnline: false,
            needsPassword: false,
            latencyMs: nil,
            hasStoredPassword: false
        )
        computers.append(computer)
        save()
        return computer
    }

    func update(_ computer: DSHComputer) {
        guard let idx = computers.firstIndex(where: { $0.id == computer.id }) else { return }
        computers[idx] = computer
        save()
    }

    func remove(_ computer: DSHComputer) {
        computers.removeAll { $0.id == computer.id }
        save()
    }

    func setActive(_ id: String) {
        for i in computers.indices {
            computers[i].isActive = computers[i].id == id
        }
        save()
    }

    // MARK: - 多地址自动选路

    /// 当前地址连不上时切到备用地址（局域网 ↔ Tailscale）。
    ///
    /// 做法是**互换**：把现在用的地址存进 tailscale 字段，再换成备用地址。
    /// 这样来回切多少次都不会丢，且「当前地址能用就不动」——
    /// 只有探测失败时才会被调用。
    @discardableResult
    func switchAddress(for id: String) -> Bool {
        guard let idx = computers.firstIndex(where: { $0.id == id }),
              let alternateHost = computers[idx].tailscaleHost else {
            return false
        }
        var c = computers[idx]
        let currentHost = c.host
        let currentPort = c.port
        c.host = alternateHost
        c.port = c.tailscalePort ?? currentPort
        c.tailscaleHost = currentHost
        c.tailscalePort = currentPort
        c.isOnline = false
        computers[idx] = c
        save()
        return true
    }

    /// 从 `http://host:port` 地址串反查连接。
    func find(host: String, port: Int) -> DSHComputer? {
        computers.first { $0.host == host && $0.port == port }
    }
}
