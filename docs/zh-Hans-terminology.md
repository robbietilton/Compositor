# 简体中文术语与维护规则

界面优先使用 Photoshop 简体中文的常见称呼，并按实际功能翻译。系统文件对话框遵循 macOS 的本地化。

| 英文 | 简体中文 | 使用场景 |
| --- | --- | --- |
| Type / Type tool | 文字／文字工具 | 文字编辑，不译为“类型” |
| Healing Type | 类型 | 污点修复的算法选项，与文字工具区分 |
| Layer / Folder | 图层／图层组 | 图层面板中的分组；磁盘目录仍称文件夹 |
| Layer Mask / Clipping Mask | 图层蒙版／剪贴蒙版 | 区分两类蒙版 |
| Color Picker / Eyedropper | 拾色器／吸管 | 色彩对话框与取样工具 |
| Levels / Curves | 色阶／曲线 | 色调调整 |
| Set Black / Gray / White Point | 设置黑场／灰场／白场 | 色阶吸管；普通颜色仍为黑色、灰色、白色 |
| Point Sample / Average | 点取样／平均 | 魔棒取样范围 |
| Multiply / Screen / Overlay | 正片叠底／滤色／叠加 | 混合模式 |
| Drop Shadow / Stroke | 投影／描边 | 图层效果 |
| Size | 大小 | 投影、内阴影的模糊范围沿用 Photoshop 图层样式标签 |
| Light / Lighting | 亮色／光线 | 仿色中的亮色与 Camera Raw 光线分区分别处理 |
| Smudge / Hand | 涂抹／抓手 | 工具与状态提示保持一致 |
| Dither / Halftone | 仿色／半调 | 仿色滤镜 |
| Content-Aware Fill | 内容识别填充 | 选区填充 |
| View / Fit Canvas / Fit | 视图／按屏幕大小缩放／适合屏幕 | 菜单与工具栏分别采用 Photoshop 对应称呼 |
| Save / Save As / Export | 存储／存储为／导出 | 命令与文件对话框按钮保持一致 |
| Handle | 控制点 | 变换框与文字框的调整点 |
| Rasterize | 栅格化 | 把可编辑对象转换为像素 |
| Guide / Tracking / Leading | 参考线／字距／行距 | 布局与文字排版 |

术语参考：[Adobe 文字工具](https://helpx.adobe.com/cn/photoshop/using/creating-type.html)、[色阶与曲线的黑场、灰场和白场](https://helpx.adobe.com/cn/photoshop/using/adjust-color-tone-levels-curves.html)、[混合模式](https://helpx.adobe.com/cn/photoshop/desktop/repair-retouch/adjust-light-tone/blending-mode-descriptions.html)、[颜色模式中的仿色](https://helpx.adobe.com/cn/photoshop/using/color-modes.html)。

视图术语参考：[Adobe 查看图像](https://helpx.adobe.com/cn/photoshop/using/viewing-images.html)。图层样式参考：[Adobe 图层样式效果和选项](https://helpx.adobe.com/cn/photoshop/desktop/create-manage-layers/apply-layer-effects/layer-style-effects-and-options-overview.html)。

## 新功能的本地化

1. SwiftUI 字面量使用原生本地化 API；动态 `String` 与 AppKit 文本使用 `localized(...)` 或 `String(localized:)`。
2. 新增文字写入 `Compositor/Localizable.xcstrings`。运行时拼接的完整键、枚举选项、提示和撤销名称都需要覆盖。格式参数的数量、位置与类型保持一致。
3. 不把译文用作功能标识。菜单用 action/identifier，枚举的 `rawValue`、快捷键 ID、PSD 键及项目格式继续使用既有值。
4. 只翻译默认生成的名称及界面说明，不翻译用户内容、文件名、字体家族或技术格式名。
   快捷键中的字母 W、H 等按键字符保留；尺寸标签中的 W、H 译为宽、高。搜索需同时匹配显示的中文标题与原始英文标题。
5. 构建后执行资源检查；英文与简体中文分别跑完整回归。`LocalizationTests` 检查真实构建产物，资源检查脚本同时检查 Xcode 提取结果和运行时 helper。

代码扫描与自动测试不能代替逐项视觉检查。验收前还需检查菜单、工具、对话框和长提示的显示，特别注意中文截断、滑块标签宽度、文件转换提示和快捷键操作。
