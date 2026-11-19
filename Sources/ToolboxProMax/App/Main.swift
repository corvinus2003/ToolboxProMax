import Foundation

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let i = args.firstIndex(of: "--selftest") {
            let rest = Array(args[(i + 1)...])
            let done = DispatchSemaphore(value: 0)
            var code: Int32 = 1
            Task.detached {
                code = await SelfTest.run(rest)
                done.signal()
            }
            done.wait()
            exit(code)
        }
        if let i = args.firstIndex(of: "--merge"), args.count >= i + 4 {
            // diagnostic: join a picture file and a sound file the way the Download node does
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do { try await VideoOps.merge(video: URL(fileURLWithPath: args[i + 1]), audio: URL(fileURLWithPath: args[i + 2]),
                                              to: URL(fileURLWithPath: args[i + 3])) } catch { print("merge failed:", error) }
                done.signal()
            }
            done.wait()
            exit(0)
        }
        ToolboxProMaxApp.main()
    }
}
