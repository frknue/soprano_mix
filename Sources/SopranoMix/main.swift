import AppKit

// Sub-commands run before the app launches and exit with their status: the snapshot
// harness, `scan`, `selftest` and the CLI (`list`, `devices`, `set`, `mute`, `unmute`,
// `output`, `show`, `hide`, `help`). Each gets the arguments without the executable,
// starting with the command itself. Anything else starts the menu-bar app.
let launchArguments = Array(CommandLine.arguments.dropFirst())
if let command = launchArguments.first {
    switch command {
    case "snapshot":
        exit(SnapshotCommand.run(arguments: launchArguments))
    case "scan":
        exit(ScanCommand.run(arguments: launchArguments))
    case "selftest":
        exit(SelfTestCommand.run(arguments: launchArguments))
    case _ where CLIClient.commands.contains(command):
        exit(CLIClient.run(arguments: launchArguments))
    default:
        break
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
