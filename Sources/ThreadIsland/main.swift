import AppKit
import ThreadIslandCore

if CommandLine.arguments.dropFirst().first == "--avatar" {
    do {
        try AvatarAgent.run(Array(CommandLine.arguments.dropFirst(2)))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--diagnose") {
    let arguments = CommandLine.arguments
    let needle = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
    let instances = Discovery.instances()
    print("instances=\(instances.count)")
    var failed = false
    for instance in instances {
        do {
            let page = try Catalog.sessions(in: instance, limit: 40)
            let hit = try needle.flatMap { try Catalog.session(id: $0, in: instance) }
            let readable = hit.map { ((try? Transcript.read($0).messages.count) ?? 0) > 0 } ?? false
            let desktop = (try? DesktopRouter.destination(for: instance)) != nil
            print("agent=\(instance.agent.rawValue) origin=\(instance.origin.rawValue) profile=\(instance.root.lastPathComponent) visible=\(page.count) lookup=\(hit != nil) preview=\(readable) desktop=\(desktop)")
        } catch {
            failed = true
            print("agent=\(instance.agent.rawValue) origin=\(instance.origin.rawValue) profile=\(instance.root.lastPathComponent) error=\(error.localizedDescription)")
        }
    }
    exit(failed || instances.isEmpty ? 1 : 0)
}

let application = NSApplication.shared
let controller = IslandController()
application.setActivationPolicy(.accessory)
application.delegate = controller
application.run()
