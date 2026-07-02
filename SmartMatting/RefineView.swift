import SwiftUI
import CoreImage

/// 手动精修视图：在抠图结果上涂抹修改遮罩
struct RefineView: View {
    let originalImage: UIImage
    let mattedImage: UIImage
    let maskImage: UIImage
    let onSave: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var brushMode: BrushMode = .erase  // 默认擦除
    @State private var brushSize: CGFloat = 25
    @State private var strokes: [Stroke] = []
    @State private var currentStroke: Stroke?
    @State private var previewImage: UIImage?
    @State private var displayRect: CGRect = .zero
    @State private var magnifierCenter: CGPoint?
    @State private var magnifierScale: CGFloat = 2.5

    // 缓存的遮罩像素（避免每次重新渲染）
    @State private var cachedMaskPixels: [UInt8]?
    @State private var cachedMaskSize: CGSize = .zero

    enum BrushMode: String, CaseIterable {
        case erase = "擦除"
        case keep = "保留"

        var color: Color {
            switch self {
            case .keep: .green
            case .erase: .red
            }
        }

        var icon: String {
            switch self {
            case .keep: "plus.circle.fill"
            case .erase: "minus.circle.fill"
            }
        }
    }

    struct Stroke: Identifiable {
        let id = UUID()
        var points: [CGPoint]
        let mode: BrushMode
        let size: CGFloat
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let imageSize = previewImage?.size ?? mattedImage.size
                    let fitScale = min(geo.size.width / imageSize.width, geo.size.height / imageSize.height)
                    let renderedW = imageSize.width * fitScale
                    let renderedH = imageSize.height * fitScale
                    let offsetX = (geo.size.width - renderedW) / 2
                    let offsetY = (geo.size.height - renderedH) / 2

                    ZStack {
                        // 棋盘格背景
                        Image(uiImage: checkerboardImage(size: imageSize))
                            .resizable()
                            .frame(width: renderedW, height: renderedH)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)

                        // 抠图结果
                        Image(uiImage: previewImage ?? mattedImage)
                            .resizable()
                            .frame(width: renderedW, height: renderedH)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)

                        // 画笔预览层
                        Canvas { context, size in
                            for stroke in strokes {
                                drawStrokeOverlay(stroke, in: &context, fitScale: fitScale, offsetX: offsetX, offsetY: offsetY)
                            }
                            if let stroke = currentStroke {
                                drawStrokeOverlay(stroke, in: &context, fitScale: fitScale, offsetX: offsetX, offsetY: offsetY)
                            }
                        }
                        .allowsHitTesting(false)

                        // 放大镜
                        if let center = magnifierCenter {
                            magnifierView(at: center, fitScale: fitScale, offsetX: offsetX, offsetY: offsetY, size: geo.size)
                        }
                    }
                    .onAppear {
                        displayRect = CGRect(x: offsetX, y: offsetY, width: renderedW, height: renderedH)
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                magnifierCenter = value.location
                                let point = value.location
                                if currentStroke == nil {
                                    currentStroke = Stroke(points: [point], mode: brushMode, size: brushSize)
                                } else {
                                    currentStroke?.points.append(point)
                                }
                            }
                            .onEnded { _ in
                                magnifierCenter = nil
                                if let stroke = currentStroke {
                                    strokes.append(stroke)
                                    currentStroke = nil
                                    applyStrokesFast()
                                }
                            }
                    )
                }

                // 底部工具栏
                HStack(spacing: 12) {
                    Picker("模式", selection: $brushMode) {
                        ForEach(BrushMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)

                    HStack(spacing: 4) {
                        Image(systemName: "circle.lefthalf.filled").font(.caption)
                        Slider(value: $brushSize, in: 5...60, step: 5).frame(width: 80)
                        Text("\(Int(brushSize))").font(.caption).frame(width: 24)
                    }

                    Spacer()

                    Button {
                        if !strokes.isEmpty {
                            strokes.removeLast()
                            applyStrokesFast()
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(strokes.isEmpty)

                    Button("重置") {
                        strokes.removeAll()
                        previewImage = nil
                        cachedMaskPixels = nil
                    }
                    .buttonStyle(.bordered)
                    .disabled(strokes.isEmpty)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("精修 · 涂抹边缘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSave(previewImage ?? mattedImage)
                    }
                }
            }
        }
    }

    // MARK: - 放大镜

    private func magnifierView(at point: CGPoint, fitScale: CGFloat, offsetX: CGFloat, offsetY: CGFloat, size: CGSize) -> some View {
        let magnifierSize: CGFloat = 120
        let imgPt = imagePoint(from: point, imageSize: mattedImage.size, displaySize: size)

        // 放大镜内容：裁剪原图 + 遮罩叠加
        return ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: magnifierSize, height: magnifierSize)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.6), lineWidth: 2)
                )
                .shadow(radius: 8)

            // 放大区域
            GeometryReader { _ in
                let cropW = magnifierSize / magnifierScale
                let cropH = magnifierSize / magnifierScale
                let cropRect = CGRect(
                    x: imgPt.x - cropW / 2,
                    y: imgPt.y - cropH / 2,
                    width: cropW,
                    height: cropH
                )

                if let cg = (previewImage ?? mattedImage).cgImage,
                   let cropped = cg.cropping(to: cropRect.intersection(CGRect(origin: .zero, size: mattedImage.size))) {
                    Image(uiImage: UIImage(cgImage: cropped))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: magnifierSize - 8, height: magnifierSize - 8)
                        .clipShape(Circle())
                }
            }
            .frame(width: magnifierSize - 8, height: magnifierSize - 8)
            .clipShape(Circle())

            // 十字准星
            Circle()
                .stroke(Color.white, lineWidth: 1)
                .frame(width: magnifierSize, height: magnifierSize)
            Path { path in
                let cx = magnifierSize / 2
                path.move(to: CGPoint(x: cx, y: cx - 8))
                path.addLine(to: CGPoint(x: cx, y: cx + 8))
                path.move(to: CGPoint(x: cx - 8, y: cx))
                path.addLine(to: CGPoint(x: cx + 8, y: cx))
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 1)
        }
        .frame(width: magnifierSize, height: magnifierSize)
        .position(x: min(max(point.x, magnifierSize / 2 + 10), size.width - magnifierSize / 2 - 10),
                  y: max(point.y - magnifierSize - 20, magnifierSize / 2 + 10))
    }

    // MARK: - 画笔叠加层

    private func drawStrokeOverlay(_ stroke: Stroke, in context: inout GraphicsContext, fitScale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        guard stroke.points.count >= 2 else { return }
        let color = stroke.mode == .keep
            ? Color.green.opacity(0.35)
            : Color.red.opacity(0.35)
        context.stroke(
            Path { path in
                path.move(to: stroke.points[0])
                for point in stroke.points.dropFirst() {
                    path.addLine(to: point)
                }
            },
            with: .color(color),
            style: StrokeStyle(lineWidth: stroke.size, lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - 坐标映射

    private func imagePoint(from screenPoint: CGPoint, imageSize: CGSize, displaySize: CGSize) -> CGPoint {
        let scale = min(displaySize.width / imageSize.width, displaySize.height / imageSize.height)
        let renderedW = imageSize.width * scale
        let renderedH = imageSize.height * scale
        let ox = (displaySize.width - renderedW) / 2
        let oy = (displaySize.height - renderedH) / 2
        let x = (screenPoint.x - ox) / scale
        let y = (screenPoint.y - oy) / scale
        return CGPoint(x: max(0, min(imageSize.width, x)),
                        y: max(0, min(imageSize.height, y)))
    }

    // MARK: - 快速应用画笔（CPU 逐像素）

    private func applyStrokesFast() {
        guard !strokes.isEmpty else {
            previewImage = nil
            cachedMaskPixels = nil
            return
        }

        let imageSize = mattedImage.size
        let w = Int(imageSize.width)
        let h = Int(imageSize.height)
        let total = w * h

        let displayW = displayRect.width > 0 ? displayRect.width : imageSize.width
        let displayH = displayRect.height > 0 ? displayRect.height : imageSize.height
        let displaySize = CGSize(width: displayW, height: displayH)

        // 懒加载遮罩像素缓存
        if cachedMaskPixels == nil || cachedMaskSize != imageSize {
            cachedMaskPixels = extractMaskPixels(from: maskImage, width: w, height: h)
            cachedMaskSize = imageSize
        }
        guard var maskPixels = cachedMaskPixels else { return }

        // 在遮罩上应用所有笔画
        for stroke in strokes {
            guard stroke.points.count >= 2 else { continue }
            let brushPixelSize = stroke.size / displaySize.width * imageSize.width
            let brushRadius = Int(brushPixelSize / 2)
            let targetValue: UInt8 = stroke.mode == .keep ? 255 : 0

            // 将屏幕坐标转为像素坐标
            var pixelPoints: [(Int, Int)] = []
            for pt in stroke.points {
                let mapped = imagePoint(from: pt, imageSize: imageSize, displaySize: displaySize)
                pixelPoints.append((Int(mapped.x), Int(mapped.y)))
            }

            // 沿路径绘制圆点
            for (px, py) in pixelPoints {
                for dy in -brushRadius...brushRadius {
                    for dx in -brushRadius...brushRadius {
                        if dx * dx + dy * dy <= brushRadius * brushRadius {
                            let nx = px + dx
                            let ny = py + dy
                            guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                            maskPixels[ny * w + nx] = targetValue
                        }
                    }
                }
            }
        }

        // 轻微羽化遮罩
        let featheredMask = featherMaskPixels(&maskPixels, width: w, height: h, radius: 1)

        // CPU 合成
        guard let resultCG = blendWithMask(originalImage, maskPixels: featheredMask, width: w, height: h) else { return }

        previewImage = UIImage(cgImage: resultCG, scale: mattedImage.scale, orientation: .up)
    }

    /// 从遮罩图片提取灰度像素
    private func extractMaskPixels(from image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        let ctx = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx?.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: width * height)
        return Array(UnsafeBufferPointer(start: ptr, count: width * height))
    }

    /// 羽化遮罩像素（简单盒模糊）
    private func featherMaskPixels(_ pixels: inout [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        guard radius > 0 else { return pixels }
        var result = pixels
        let total = width * height
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                if pixels[idx] > 0 && pixels[idx] < 255 { continue }  // 保留已有的过渡像素
                var sum: Int = 0
                var count: Int = 0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        sum += Int(pixels[ny * width + nx])
                        count += 1
                    }
                }
                result[idx] = UInt8(sum / count)
            }
        }
        return result
    }

    /// CPU 逐像素合成：遮罩值 → alpha 通道
    private func blendWithMask(_ image: UIImage, maskPixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let cg = image.cgImage else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { return nil }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return nil }
        let rgb = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        for i in 0..<(width * height) {
            rgb[i * 4 + 3] = maskPixels[i]
        }

        return ctx.makeImage()
    }

    // MARK: - 棋盘格

    private func checkerboardImage(size: CGSize) -> UIImage {
        let tile: CGFloat = 12
        let f = UIGraphicsImageRendererFormat(); f.scale = UIScreen.main.scale
        let isDark = UITraitCollection.current.userInterfaceStyle == .dark
        let lightColor: UIColor = isDark
            ? UIColor(white: 0.25, alpha: 1)
            : UIColor(white: 0.85, alpha: 1)
        let darkColor: UIColor = isDark
            ? UIColor(white: 0.20, alpha: 1)
            : UIColor(white: 0.75, alpha: 1)
        return UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            let cols = Int(size.width / tile) + 1
            let rows = Int(size.height / tile) + 1
            for row in 0..<rows {
                for col in 0..<cols {
                    let color: UIColor = (row + col).isMultiple(of: 2) ? lightColor : darkColor
                    color.setFill()
                    ctx.fill(CGRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile, width: tile, height: tile))
                }
            }
        }
    }
}
