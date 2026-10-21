import Foundation

let args = CommandLine.arguments
guard args.count == 4, args[1].range(of: "^[A-Fa-f0-9]{40}$", options: .regularExpression) != nil else { exit(2) }
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
process.arguments = ["--force", "--sign", args[1], "--timestamp=none", args[2]]
do {
    try process.run(); process.waitUntilExit()
    try Data(String(process.terminationStatus).utf8).write(to: URL(fileURLWithPath: args[3]), options: [.atomic])
    exit(process.terminationStatus)
} catch {
    try? Data("1".utf8).write(to: URL(fileURLWithPath: args[3]), options: [.atomic])
    exit(1)
}
