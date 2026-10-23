import Foundation
import ImageIO

// One request per process. CommandRunner owns cancellation, so cancelling a
// reader page terminates precisely that page's helper without stale IPC work.
@main
struct VisionHelperMain {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let hints: [[String: Any]]
            if arguments == ["--prepare"] {
                VisionRecognition.prepare()
                hints = []
            } else if arguments.count == 2, arguments[0] == "--image" {
                let url = URL(fileURLWithPath: arguments[1])
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw NSError(domain: "ShioriVision", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "无法读取识字图片。"])
                }
                hints = VisionRecognition.textHints(in: image)
            } else {
                throw NSError(domain: "ShioriVision", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Usage: ShioriVision --prepare | --image PATH"])
            }
            let data = try JSONSerialization.data(withJSONObject: hints, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
