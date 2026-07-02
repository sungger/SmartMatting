# SmartMatting 抠图 Bug 修复经验

> 2026-07-02，花了将近一整个晚上修了三个深坑。记录下来，以后遇到类似问题能少走弯路。

---

## 背景

SmartMatting 的人像抠图功能，目标是：**抠出人物 → 去掉帽子 → 保存透明 PNG**。

测试图片：800×800 的 AI 少女，浅米色宽檐帽，深绿虚化背景。

抠图管线：Vision 前景分割 → U2Net → DeepLabV3（只保留 class 15 人）→ RMBG1.4 回退。

---

## Bug 1：保存的透明 PNG 是原图（alpha 全 255）

### 现象

抠图后在 App 里显示正常（背景透明），但点"保存"后得到的 PNG 文件和原图一模一样——所有像素 alpha=255。

### 排查过程

这是最耗时的一个 bug，排查了至少 10 轮：

1. **怀疑 `UIImage.pngData()` 有问题** → 换 `CGImageDestination` 直接写 PNG → 没用
2. **怀疑 SwiftUI 渲染时修改了 UIImage** → 在 `segmentPerson` 返回前做 `lockPNG`（PNG data 来回转换）→ 没用
3. **怀疑 `fixOrientation` 创建的 `UIImage(cgImage:)` 丢失 alpha** → 把 `lockPNG` 放在 `fixOrientation` 之后 → 没用
4. **怀疑 `synthesizeResult` 返回的 UIImage 有问题** → 在返回前再做 `lockPNG` → 没用
5. **在 `blend` 方法内部保存 `blend_debug.png`** → 发现它是正确的（64.1% 前景）！说明 `blend` 内部的 `resultCG` 是对的
6. **但同一个 `resultCG` 通过 `UIImage(cgImage:)` 返回后，`.pngData()` 就返回原图** → 怀疑 `UIImage` 的 `pngData()` 在某些情况下会出问题
7. **把 `resultCG` 存到 `lastResultCGImage`，用 `CGImageDestination` 直接写** → 还是原图！

### 根因

**`premultipliedLast` context 初始 alpha=0。**

`blend` 方法创建了 `premultipliedLast` 格式的 CGContext，然后 `ctx.draw(imageCG)` 把原图画上去。

Premultiplied（预乘 alpha）的意思是：RGB 值 = 实际 RGB × alpha。由于 context 初始 alpha=0，所以 `draw` 时 RGB 被乘以 0 → **全部变成 0（黑色）**。

然后代码遍历像素，把遮罩的灰度值写入 alpha 通道。对于前景像素，alpha 被设为 255，但 RGB 已经是 0 了——所以前景像素变成了 `RGB(0,0,0,255)` 即纯黑色。

`blend_debug.png` 之所以正确，是因为它是在 `blend` 方法**内部**用 `UIImage(cgImage:).pngData()` 保存的——可能 iOS 在生成 PNG 时有某种回退逻辑。但返回后的 UIImage 就不行了。

### 修复

```swift
// 先填充白色不透明背景（否则 premultiplied 会导致 RGB 被清零）
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

// 然后再画原图
ctx.draw(imageCG, in: CGRect(x: 0, y: 0, width: w, height: h))
```

### 教训

- **Premultiplied alpha 是坑。** 在 premultiplied context 上操作时，永远记住 RGB 已经被 alpha 预乘了
- **初始 alpha=0 时 draw 会把 RGB 清零。** 需要先填充不透明背景
- **`UIImage.pngData()` 不可靠。** 对于 premultiplied 格式的 CGImage，它可能返回错误数据。直接用 `CGImageDestination` 更可靠
- **调试时在源头保存中间文件。** 如果不在 `blend` 内部保存 `blend_debug.png`，可能永远找不到根因

---

## Bug 2：DeepLabV3 遮罩缩放后变成全白

### 现象

DeepLabV3 输出的 513×513 灰度遮罩缩放为 800×800 后，前景占比从 67% 变成了 100%（全白）。

### 排查

在 `deeplabSegment` 的每一步保存中间文件：

- `deeplabOutputToMask` 输出 513×513 灰度图 → 67% 前景 ✅
- `resizeCGImage` 缩放后 800×800 → 67% 前景 ✅
- `binarizeMask` 之后 → 67% 前景 ✅
- `featherMask` 之后 → **100% 前景** ❌

### 根因

**`fillInteriorHoles` 太激进。**

这个方法用 BFS 距离变换，把距离边缘 > `minDist` 的背景像素填为前景。`minDist = 1` 意味着：只要不是紧挨着前景边缘的背景像素，全被填为前景。

DeepLabV3 的遮罩里，帽子区域是背景（0），人物是前景（255）。帽子在人物上方，帽子像素距离最近的人物像素通常 > 1px，所以帽子区域全被填成了前景。

### 修复

跳过 `fillInteriorHoles`。对于 DeepLabV3 这种语义分割模型，输出遮罩已经比较干净了，不需要激进的填孔。

```swift
// 之前：二值化 + 距离变换填孔 + 移除小区域 + 羽化
// 修复：二值化 + 移除小区域 + 羽化（跳过 fillInteriorHoles）
if let binarized = binarizeMask(maskCI) { maskCI = binarized }
if let cleaned = removeSmallForegroundRegions(maskCI) { maskCI = cleaned }
if let b = featherMask(maskCI, radius: 0.5 * rScale) { maskCI = b }
```

### 教训

- **后处理参数要保守。** `minDist=1` 对某些遮罩来说太激进
- **语义分割的输出通常不需要填孔。** 填孔更适合传统图像处理生成的带噪点的遮罩
- **分步保存中间结果。** 在每一步后保存文件，能快速定位是哪一步出了问题

---

## Bug 3：`resizeCGImage` 把灰度图转成了 RGBA

### 现象

`resizeCGImage` 缩放灰度遮罩后，输出变成了 RGBA 四通道图像（804×804×4 而非 800×800×1）。

### 根因

`resizeCGImage` 硬编码了 RGBA premultipliedLast 格式：

```swift
// 之前的代码
let ctx = CGContext(data: nil, width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
```

灰度 CGImage（8bpp，无 alpha）画到 RGBA context 时，灰度值被写入 R 通道，G、B 被设为 0，A 被设为 255。

虽然 `binarizeMask` 只取 R 通道（通过 `CIColorMatrix`），所以功能上没坏，但尺寸从 800×800 变成了 804×804（`CIImage.extent` 浮点精度问题），导致后续操作尺寸不匹配。

### 修复

保持原始 CGImage 的色彩空间和 alpha 格式：

```swift
let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
let alphaInfo = cgImage.alphaInfo
let bpp = cgImage.bitsPerPixel
let bpr = (bpp / 8) * width
let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue)
let ctx = CGContext(data: nil, width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: bpr,
    space: colorSpace, bitmapInfo: bitmapInfo.rawValue)
```

### 教训

- **缩放时保持原始格式。** 不要硬编码色彩空间和像素格式
- **灰度图用灰度 context。** 否则会被转成 RGB，浪费内存且可能导致后续处理出错
- **`CIImage.extent` 有浮点精度问题。** 用 `CIImage.transformed(by: CGAffineTransform(scaleX:y:))` 缩放时，extent 可能不是精确的整数尺寸

---

## 总结

| Bug | 根因 | 修复 | 耗时 |
|-----|------|------|------|
| 保存 PNG 是原图 | premultipliedLast context 初始 alpha=0，draw 时 RGB 被清零 | 先 fill 白色背景再 draw | ~2h |
| 遮罩全白 | fillInteriorHoles minDist=1 太激进 | 跳过 fillInteriorHoles | ~30min |
| 灰度图变 RGBA | resizeCGImage 硬编码 RGBA 格式 | 保持原始色彩空间 | ~15min |

**核心教训：**

1. **Premultiplied alpha 是 iOS 图形编程的常见坑。** 操作 premultiplied context 前一定要确认初始 alpha 状态
2. **分步保存中间文件是最有效的调试手段。** 如果不在 `blend` 内部保存 `blend_debug.png`，Bug 1 可能永远找不到
3. **后处理参数要保守，尤其是涉及全局操作的（如填孔、膨胀）。** 宁可少做，不要多做
4. **CGImage 缩放时保持原始格式。** 硬编码 RGB/RGBA 会导致灰度图被错误转换

---

*记录于 2026-07-02 深夜，SmartMatting 项目*
