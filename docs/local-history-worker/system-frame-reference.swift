import Foundation
import AppKit
import SwiftUI
import Darwin
import MachO
_ = NSColor.red
_ = Color.red
let detectors = dlopen("/System/Library/PrivateFrameworks/DataDetectorsCore.framework/DataDetectorsCore", RTLD_LAZY)
let events = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
var images: [String: (UnsafeRawPointer, String)] = [:]
for i in 0..<_dyld_image_count() {
    guard let header = _dyld_get_image_header(i), let name = _dyld_get_image_name(i) else { continue }
    let raw = UnsafeRawPointer(header)
    guard header.pointee.magic == MH_MAGIC_64 else { continue }
    var command = raw.advanced(by: MemoryLayout<mach_header_64>.size)
    for _ in 0..<header.pointee.ncmds {
        let load = command.load(as: load_command.self)
        if load.cmd == LC_UUID {
            var uuid = command.load(as: uuid_command.self).uuid
            let key = withUnsafeBytes(of: &uuid) { bytes in
                bytes.enumerated().map { i, b in ([4,6,8,10].contains(i) ? "-" : "") + String(format: "%02X", b) }.joined()
            }
            let path = String(cString: name)
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/") { images[key] = (raw, path) }
        }
        command = command.advanced(by: Int(load.cmdsize))
    }
}
var output: [[String: Any]] = []
for event in events {
    let frames = (event["backtrace"] as? [String: Any])?["frames"] as? [[String: Any]] ?? []
    var mapped: [[String: Any]] = []
    for f in frames {
        guard let uuid = f["imageUUID"] as? String, let offset = f["imageOffset"] as? Int else { continue }
        var row = f
        if let (base, path) = images[uuid] {
            let address = base.advanced(by: offset)
            var info = Dl_info()
            row["image"] = path
            if dladdr(address, &info) != 0, let name = info.dli_sname {
                row["symbol"] = String(cString: name)
                if let symbolBase = info.dli_saddr { row["symbolOffset"] = Int(bitPattern: address) - Int(bitPattern: symbolBase) }
            }
        }
        mapped.append(row)
    }
    output.append(["timestamp":event["timestamp"] ?? "", "processID":event["processID"] ?? 0, "frames":mapped, "matchedSystemFrames":mapped.filter{$0["image"] != nil}.count])
}
let data = try JSONSerialization.data(withJSONObject: ["method":"Read own loaded Mach-O UUID/base and dladdr; UUID-matched historical system-image offsets only. No historical app frames relocated.","events":output], options: [.prettyPrinted,.sortedKeys])
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("System images \(images.count); events \(output.count); mapped \(output.map{$0["matchedSystemFrames"]!})")
if let detectors { dlclose(detectors) }
