import Foundation
import NTFSMountCore

enum HelperClient {
    static func call(_ arguments: [String], timeout: TimeInterval = 60) -> HelperResponse? {
        let result = Shell.run(
            "/usr/bin/sudo",
            ["-n", Paths.helper] + arguments,
            timeout: timeout
        )
        guard let line = result.stdout
            .split(separator: "\n")
            .last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }) else {
            return nil
        }
        guard let data = String(line).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HelperResponse.self, from: data)
    }
}
