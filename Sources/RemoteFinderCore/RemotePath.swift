import Foundation

struct RemotePathComponent: Equatable {
    let name: String
    let path: String

    static func components(of path: String) -> [RemotePathComponent] {
        guard path.hasPrefix("/") else { return [] }
        var result = [RemotePathComponent(name: "/", path: "/")]
        var prefix = ""
        for name in path.split(separator: "/") {
            prefix += "/" + name
            result.append(RemotePathComponent(name: String(name), path: prefix))
        }
        return result
    }
}

// -1 represents the menu containing omitted ancestors; keep root and current directory visible.
func compactPathIndices(widths: [CGFloat], available: CGFloat) -> [Int] {
    guard widths.count > 2 else { return Array(widths.indices) }
    if widths.reduce(0, +) <= available { return Array(widths.indices) }
    var firstVisible = widths.count - 1
    var used = widths[0] + 38 + widths[firstVisible]
    while firstVisible > 2 && used + widths[firstVisible - 1] <= available {
        firstVisible -= 1; used += widths[firstVisible]
    }
    return [0, -1] + Array(firstVisible..<widths.count)
}
