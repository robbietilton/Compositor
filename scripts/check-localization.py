#!/usr/bin/env python3
"""检查简体中文资源和格式参数；可结合 Xcode 提取结果检查 SwiftUI 界面覆盖。"""
import argparse
import collections
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
# 数字、符号、单位不翻译。算法名称保留原名，但必须存在资源条目。
NONLINGUISTIC = {"", "#", "%", "%lld", "100%", "px", "°", "X", "Y", "·"}
LITERAL = r'"((?:[^"\\]|\\.)*)"'
FORMAT = re.compile(r'%(?:(\d+)\$)?(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|ll|[hljztL])?([@diuoxXfFeEgGaAcCsSp])')


def parameters(value):
    result = collections.Counter()
    # %% 是字面百分号，不是参数。
    for index, match in enumerate(FORMAT.finditer(value.replace("%%", "")), 1):
        result[(int(match[1] or index), (match[2] or "") + match[3])] += 1
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, help="已 build-for-testing 的 DerivedData 目录")
    parser.add_argument("--compiled-strings", type=Path, help="swiftc 实际编译提取的 stringsdata 目录")
    args = parser.parse_args()
    strings = json.loads((ROOT / "Compositor/Localizable.xcstrings").read_text())["strings"]
    errors = []
    required = set()
    for key, entry in strings.items():
        unit = entry.get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {})
        value = unit.get("value", "")
        if not value or unit.get("state") != "translated":
            errors.append(f"未完成译文：{key}")
        if parameters(key) != parameters(value):
            errors.append(f"格式参数不一致：{key} → {value}")
    for path in (ROOT / "Compositor").rglob("*.swift"):
        source = path.read_text()
        # 运行时 helper 的字面量不被 Xcode 提取。
        patterns = [r'localized\(' + LITERAL,
                    r'\b(?:control|slider|sharpenSlider|geometrySlider|calibrationSlider|wheel|field|colorSwatch)\(' + LITERAL,
                    r'\bhelp:\s*' + LITERAL, r'\bbeginEdit\(' + LITERAL,
                    r'\bTransformValueField\(label:\s*' + LITERAL]
        for pattern in patterns:
            for match in re.finditer(pattern, source):
                key = match[1]
                if "\\(" not in key:
                    required.add(json.loads('"' + key + '"'))
    extracted = 0
    if args.compiled_strings:
        files = list(args.compiled_strings.glob("*.stringsdata"))
        if not files:
            errors.append("没有找到 swiftc 编译提取结果")
        for path in files:
            for entry in json.loads(path.read_text()).get("tables", {}).get("Localizable", []):
                required.add(entry["key"])
                extracted += 1
    if args.derived_data:
        folder = args.derived_data / "Build/Intermediates.noindex/Compositor.build"
        files = list(folder.glob("*/Compositor.build/Objects-normal/*/*.stringsdata"))
        if not files:
            errors.append("没有找到 Compositor 的编译提取结果，请先构建该目录")
        for path in files:
            for entry in json.loads(path.read_text()).get("tables", {}).get("Localizable", []):
                required.add(entry["key"])
                extracted += 1
    for key in sorted(required - NONLINGUISTIC - strings.keys()):
        errors.append(f"缺少简体中文资源：{key}")
    for error in errors:
        print(error, file=sys.stderr)
    print(f"检查 {len(strings)} 条译文、{len(required - NONLINGUISTIC)} 个界面键；编译提取 {extracted} 处；问题 {len(errors)} 个")
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())
