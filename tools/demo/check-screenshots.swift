// Reads every PNG in a folder (OCR) and fails if anything personal shows up: the user name, the
// full name, the home folder, or any extra words given in MACMONEY_PRIVATE_WORDS (comma-separated,
// for example your real bank or employer names).
//
//   swift tools/demo/check-screenshots.swift <folder>

import Foundation
import Vision
import AppKit

guard CommandLine.arguments.count > 1 else { print("usage: check-screenshots.swift <folder>"); exit(2) }
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

var words = [NSUserName(), NSHomeDirectory(), "/Users/"]
words += NSFullUserName().split(separator: " ").map(String.init).filter { $0.count > 2 }
words += (ProcessInfo.processInfo.environment["MACMONEY_PRIVATE_WORDS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
let needles = Set(words.filter { !$0.isEmpty }.map { $0.lowercased() })

let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.path < $1.path }
var problems = 0
for file in files {
    guard let image = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("✗ \(file.lastPathComponent): could not be read")
        problems += 1
        continue
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: image).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    // Compare without spaces too, so a path broken across words is still caught.
    let text = lines.joined(separator: "\n").lowercased()
    let squeezed = text.filter { !$0.isWhitespace }
    let found = needles.filter { text.contains($0) || squeezed.contains($0.filter { !$0.isWhitespace }) }
    if lines.isEmpty {
        print("✗ \(file.lastPathComponent): no text recognized, so it can't be checked")
        problems += 1
    } else if found.isEmpty {
        print("✓ \(file.lastPathComponent)")
    } else {
        print("✗ \(file.lastPathComponent): shows \(found.sorted().joined(separator: ", "))")
        problems += 1
    }
}
if files.isEmpty { print("No screenshots found in \(folder.path)"); exit(1) }
if problems > 0 { print("\(problems) picture(s) need attention. Nothing was copied."); exit(1) }
print("All \(files.count) pictures are clean.")
