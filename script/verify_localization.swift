import Foundation

let app = URL(fileURLWithPath: CommandLine.arguments[1])
let root = URL(fileURLWithPath: CommandLine.arguments[2])
let catalogData = try Data(contentsOf: root.appendingPathComponent("Compositor/Localizable.xcstrings"))
let catalog = try JSONSerialization.jsonObject(with: catalogData) as! [String: Any]
let strings = catalog["strings"] as! [String: [String: Any]]
let bundle = Bundle(path: app.appendingPathComponent("Contents/Resources/zh-Hans.lproj").path)!
var checked = 0
for (key, entry) in strings {
    let locales = entry["localizations"] as! [String: [String: Any]]
    let unit = locales["zh-Hans"]!["stringUnit"] as! [String: String]
    let actual = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    precondition(actual == unit["value"], "资源未生效：\(key)")
    checked += 1
}
let terms = [("Multiply", "正片叠底"), ("Screen", "滤色"), ("Layer Mask", "图层蒙版"),
                         ("Create Clipping Mask", "创建剪贴蒙版"), ("Levels", "色阶"), ("Curves", "曲线"),
                         ("Type", "文字"), ("Color Range", "色彩范围"), ("Fuzziness", "颜色容差"),
                         ("View", "视图"), ("Fit", "适合屏幕"), ("Fit Canvas", "按屏幕大小缩放"),
                         ("Save", "存储"), ("Save Project", "存储文档"), ("Save Project As", "存储为"),
                         ("Don’t Save", "不存储"), ("Export", "导出")]
for (key, expected) in terms {
    precondition(bundle.localizedString(forKey: key, value: nil, table: "Localizable") == expected, "术语不一致：\(key)")
}
let name = String(localized: "Layer \(3)", bundle: bundle)
precondition(name == "图层 3", "动态名称未汉化：\(name)")
let tabs = String(localized: "\(4) more tabs", bundle: bundle)
precondition(tabs == "另有 4 个文档", "动态文档数量未汉化：\(tabs)")
print("macOS 资源查找通过：\(checked) 条译文、\(terms.count) 项 Photoshop 术语、2 项插值")
