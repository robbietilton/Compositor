# 简体中文术语约定

以 Photoshop 桌面版简体中文的常用术语为参考，同时保留 Compositor 实际功能含义。不同 Adobe 版本的译法可能不同；不要仅凭英文单词全局替换。

| 英文 / 上下文 | 中文 | 约定 |
| --- | --- | --- |
| Copy / Copy Merged | 拷贝 / 合并拷贝 | 剪贴板操作 |
| Duplicate Layer / Copy Layer Mask | 复制图层 / 复制图层蒙版 | 创建副本；后者是 Option 拖动蒙版，与剪贴板拷贝区分 |
| Inverse（选区） | 反向 | 与颜色的 Invert「反相」区分 |
| Master（色相/饱和度） | 全图 | 调整全部颜色范围 |
| Exposure / Offset / Gamma | 曝光度 / 位移 / 灰度系数 | 使用桌面版曝光度对话框术语 |
| Black / Gray / White（色阶吸管） | 黑场 / 灰场 / 白场 | 独立上下文键 levels.sample.* |
| Black / Gray / White（颜色） | 黑色 / 灰色 / 白色 | 不受色阶术语影响 |
| Sampling（缩放插值） | 插值方法 | 与吸管、仿制图章的「取样」区分 |
| Show Controls（变换） | 显示变换控件 | 明确控件用途 |
| Spot Healing | 污点修复画笔 | 使用工具名称 |
| Polygonal（套索） | 多边形套索 | 使用工具名称 |
| Folder（图层容器） | 图层组 | 不称文件夹 |
| Lightness / Luminosity | 明度 | 不与 Brightness「亮度」混用 |
| Save / Save As | 保存 / 另存为 | 采用新版官方指南用词 |

## 保留功能差异

- 不把「平滑」「高质量」插值选项改称「两次线性」「两次立方」；当前实现不能证明与 Photoshop 的对应算法完全一致。
- Compositor 特有的实时蒙版、固化等行为按实际功能描述，不套用含义不同的 Photoshop 命令。
- 显示文案可以翻译，持久化的枚举值、快捷键和自动化标识保持不变。
- 英文资源仍保留原有 Black / Gray / White 吸管标题；只有中文按上下文区分。

## 官方参考

- [曝光度、位移、灰度系数与色阶吸管](https://helpx.adobe.com/cn/photoshop/using/adjusting-hdr-exposure-toning.html)
- [选择 > 反向](https://helpx.adobe.com/cn/photoshop/desktop/make-selections/refine-modify-selections/inverse-selection.html)
- [色阶调整](https://helpx.adobe.com/cn/photoshop/using/levels-adjustment.html)
- [创建图层和组、拷贝与复制](https://helpx.adobe.com/cn/photoshop/using/create-layers-groups.html)
- [Photoshop 官方中文参考手册：色相/饱和度的全图范围](https://helpx.adobe.com/archive/cn/photoshop/cc/2015/photoshop_reference.pdf)
- [新版保存工作指南](https://helpx.adobe.com/cn/photoshop/desktop/save-and-export/save-files/save-your-work.html)

核对日期：2026-09-19。
