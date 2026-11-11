import Foundation
import VMCore

// Writes the exact production launch plan with a headless display into a JSON file.
// The Python smoke harness launches it and verifies QMP, TPM, HVF and framebuffer.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
var configuration = VMConfiguration()
configuration.memoryGiB = 4
configuration.forwardHostPort = 28080
let firmware = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
let plan = try LaunchPlan(configuration: configuration, directory: directory, firmware: firmware)
let args = plan.arguments.map { $0.hasPrefix("cocoa") ? "none" : $0 }
let data = try JSONEncoder().encode(args)
FileHandle.standardOutput.write(data)
