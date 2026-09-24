import Foundation
// Frozen algorithm comparison on recorded native AX trees. No phone input or
// model calls. Run with: swift tests/jev_title_benchmark.swift audit-*.json
// The live --profile decoder measurements validate the production path;
// these copied old/new algorithms isolate the repeated traversal itself.
final class Counter { var value = 0 }
func old(_ node: [String: Any], calls: Counter) -> String? {
    calls.value += 1
    let p = "XC_kAXXCAttribute"
    if node[p + "ElementType"] as? String == "WebAccessibilityObjectWrapper",
       let label = node[p + "Label"] as? String, !label.isEmpty { return label }
    return (node[p + "Children"] as? [[String: Any]] ?? []).lazy.compactMap { old($0, calls: calls) }.first
}
func new(_ node: [String: Any], calls: Counter) -> String? {
    calls.value += 1
    let p = "XC_kAXXCAttribute"
    if node[p + "ElementType"] as? String == "WebAccessibilityObjectWrapper",
       let label = node[p + "Label"] as? String, !label.isEmpty { return label }
    for child in node[p + "Children"] as? [[String: Any]] ?? [] {
        if let title = new(child, calls: calls) { return title }
    }
    return nil
}
var rows: [[String: Any]] = []
for path in CommandLine.arguments.dropFirst() {
    let tree = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:path))) as! [String: Any]
    let oldCalls = Counter(), newCalls = Counter()
    var start = ProcessInfo.processInfo.systemUptime
    let before = old(tree, calls: oldCalls)
    let oldSeconds = ProcessInfo.processInfo.systemUptime - start
    start = ProcessInfo.processInfo.systemUptime
    let after = new(tree, calls: newCalls)
    let newSeconds = ProcessInfo.processInfo.systemUptime - start
    rows.append(["path":path,"sameTitle":before == after,"title":after ?? "", "oldCalls":oldCalls.value,"newCalls":newCalls.value,"oldSeconds":oldSeconds,"newSeconds":newSeconds])
}
print(String(data:try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
