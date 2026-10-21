import Foundation

/// Device metadata sent to Samsung. Each client identifies its own platform;
/// the accepted registration profile itself is shared (see Authentication.swift).
enum ClientPlatform {
    #if os(macOS)
    static let model = "Mac"
    static let userAgent = "SamsungCloudNotes-macOS/" + appVersion
    #else
    static let model: String = {
        // hw.machine is e.g. "iPad14,1"; simulators report the host architecture.
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? String(cString: machine)
        return identifier.hasPrefix("iPad") ? "iPad" : "iPhone"
    }()
    static let userAgent = "SamsungCloudNotes-iOS/" + appVersion
    #endif
    static let deviceName = "Samsung Cloud Notes for " + model
}
