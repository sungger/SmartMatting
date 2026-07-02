import Vision
import CoreImage
import UIKit
import Accelerate
import CoreML

/// 智能抠图引擎
final class MattingEngine: @unchecked Sendable {

    /// 处理大图时的最大边长(超过此值自动缩放处理)
    static let maxProcessingSize: CGFloat = 2048

    /// 复用的 CIContext(避免重复创建)
    private static let sharedContext: CIContext = {
        let ctx = CIContext(options: [
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .highQualityDownsample: false,
            .outputPremultiplied: true
        ])
        return ctx
    }()

    /// 最近一次生成的遮罩(供精修使用)
    static var lastMaskImage: UIImage?

    /// DeepLabV3 模型(懒加载)
    private static let deeplabModel: DeepLab = {
        let config = MLModelConfiguration()
        config.computeUnits = .all  // 优先 GPU
        return try! DeepLab(configuration: config)
    }()

    // MARK: - DeepLabV3 语义分割抠图

    /// 使用 VNGenerateForegroundInstanceMaskRequest 进行前景分割(iOS 26+)
    /// Apple 专门的前景/背景分离模型,支持人像和通用物体
    static func foregroundSegment(_ cgImage: CGImage, feather: Double = 1.5) throws -> UIImage {
        let w = cgImage.width, h = cgImage.height
        guard let safeCG = ensureReadableCGImage(cgImage) else {
            throw MattingError.processingFailed
        }

        // 使用 iOS 26 的前景实例分割
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: safeCG)
        try handler.perform([request])

        guard let result = request.results?.first else {
            throw MattingError.processingFailed
        }

        // 获取遮罩 pixel buffer
        let maskPB = try result.generateMask(forInstances: result.allInstances)
        guard let maskCG = pixelBufferToCGImage(maskPB) else {
            throw MattingError.processingFailed
        }

        var maskCI = CIImage(cgImage: maskCG)
        let rScale = max(1, CGFloat(max(w, h)) / 1024)

        // 二值化 + 距离变换填孔 + 移除小区域 + 羽化
        if let binarized = binarizeMask(maskCI) { maskCI = binarized }
        if let filled = fillInteriorHoles(maskCI) { maskCI = filled }
        if let cleaned = removeSmallForegroundRegions(maskCI) { maskCI = cleaned }
        if let b = featherMask(maskCI, radius: 0.5 * rScale) { maskCI = b }

        if let maskCG = sharedContext.createCGImage(maskCI, from: maskCI.extent) {
            lastMaskImage = UIImage(cgImage: maskCG)
        }

        let ciImage = CIImage(cgImage: safeCG)
        return try blend(ciImage, mask: maskCI, featherRadius: feather)
    }

    /// CVPixelBuffer → CGImage
    private static func pixelBufferToCGImage(_ pb: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let data = CVPixelBufferGetBaseAddress(pb)!
        let bpr = CVPixelBufferGetBytesPerRow(pb)

        guard let ctx = CGContext(data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }

        // 复制像素(PixelBuffer 可能是 float 格式)
        guard let dst = ctx.data else { return nil }
        let src = data.bindMemory(to: Float.self, capacity: h * bpr / 4)
        let dstPixels = dst.bindMemory(to: UInt8.self, capacity: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let val = src[y * (bpr / 4) + x]
                dstPixels[y * w + x] = UInt8(min(max(val * 255, 0), 255))
            }
        }
        return ctx.makeImage()
    }

    /// DeepLabV3 语义分割(回退方案)
    static func deeplabSegment(_ cgImage: CGImage, feather: Double = 1.5) throws -> UIImage {
        let w = cgImage.width, h = cgImage.height
        guard let safeCG = ensureReadableCGImage(cgImage) else {
            throw MattingError.processingFailed
        }

        // 1. 缩放到 513x513(DeepLabV3 输入尺寸)
        let targetSize = 513
        let scale = CGFloat(targetSize) / CGFloat(max(w, h))
        let scaledW = Int(CGFloat(w) * scale)
        let scaledH = Int(CGFloat(h) * scale)

        guard let resizedCG = resizeCGImage(safeCG, width: scaledW, height: scaledH) else {
            throw MattingError.processingFailed
        }

        // 2. 转成 CVPixelBuffer
        guard let pixelBuffer = cgImageToPixelBuffer(resizedCG, width: scaledW, height: scaledH) else {
            throw MattingError.processingFailed
        }

        // 3. 运行 DeepLabV3
        guard let output = try? deeplabModel.prediction(image: pixelBuffer) else {
            throw MattingError.processingFailed
        }

        // 4. 从输出中提取遮罩(semanticPredictions 是 513x513 的类别图)
        let maskML = output.semanticPredictions
        guard let maskCG = deeplabOutputToMask(maskML, width: scaledW, height: scaledH) else {
            throw MattingError.processingFailed
        }

        // 5. 缩回原图尺寸
        var maskCI = CIImage(cgImage: maskCG)
        let rScale = max(1, CGFloat(max(w, h)) / 1024)

        // 6. 二值化 + 距离变换填孔 + 移除小区域 + 羽化
        if let binarized = binarizeMask(maskCI) { maskCI = binarized }
        if let filled = fillInteriorHoles(maskCI) { maskCI = filled }
        if let cleaned = removeSmallForegroundRegions(maskCI) { maskCI = cleaned }
        if let b = featherMask(maskCI, radius: 0.5 * rScale) { maskCI = b }

        if let maskCG = sharedContext.createCGImage(maskCI, from: maskCI.extent) {
            lastMaskImage = UIImage(cgImage: maskCG)
        }

        let ciImage = CIImage(cgImage: safeCG)
        return try blend(ciImage, mask: maskCI, featherRadius: feather)
    }

    /// CGImage → CVPixelBuffer
    private static func cgImageToPixelBuffer(_ cgImage: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// 缩放 CGImage
    private static func resizeCGImage(_ cgImage: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// DeepLabV3 输出 → 二值遮罩 CGImage
    private static func deeplabOutputToMask(_ mlMultiArray: MLMultiArray, width: Int, height: Int) -> CGImage? {
        let ptr = mlMultiArray.dataPointer.bindMemory(to: Int32.self, capacity: width * height)
        guard let ctx = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)

        // DeepLabV3 类别: 15=人(person), 0=背景
        // 只保留"人"类别作为前景
        for i in 0..<(width * height) {
            pixels[i] = ptr[i] == 15 ? 255 : 0
        }
        return ctx.makeImage()
    }

    static func segmentPerson(in image: UIImage, feather: Double = 1.5) async throws -> UIImage {
        let cgImage = try prepareCGImage(from: image)

        // 优先 Apple Vision 前景分割(iOS 17+) → DeepLabV3 → RMBG1.4 回退
        if let fg = try? foregroundSegment(cgImage, feather: feather) {
            return fixOrientation(fg, to: image.imageOrientation)
        }
        if let fg = try? deeplabSegment(cgImage, feather: feather) {
            return fixOrientation(fg, to: image.imageOrientation)
        }

        let originalSize = CGSize(width: cgImage.width, height: cgImage.height)

        // 计算 letterbox 参数(和 rmbgMask 一致)
        let inputSize: CGFloat = 1024
        let scale = min(inputSize / originalSize.width, inputSize / originalSize.height)
        let scaledW = originalSize.width * scale
        let scaledH = originalSize.height * scale
        let offsetX = (inputSize - scaledW) / 2.0
        let offsetY = (inputSize - scaledH) / 2.0

        // 用 letterbox 图片推理,得到 1024×1024 遮罩
        let mask1024 = try rmbgMask(for: image)
        lastMaskImage = mask1024

        // 从 1024×1024 遮罩中裁剪出有效区域(去掉黑边)
        guard let maskCG = mask1024.cgImage,
              let croppedMask = maskCG.cropping(to: CGRect(x: offsetX, y: offsetY, width: scaledW, height: scaledH)) else {
            throw MattingError.processingFailed
        }

        // 缩放回原图尺寸
        var maskCI = CIImage(cgImage: croppedMask)
        maskCI = maskCI.transformed(by: CGAffineTransform(scaleX: originalSize.width / scaledW,
                                                           y: originalSize.height / scaledH))

        // 二值化 + 只保留最大连通域 + 羽化
        let rScale = max(1, CGFloat(max(originalSize.width, originalSize.height)) / 1024)
        if let binarized = binarizeMask(maskCI) { maskCI = binarized }
        if let cleaned = removeSmallForegroundRegions(maskCI, minArea: 500) { maskCI = cleaned }
        if let b = featherMask(maskCI, radius: 0.5 * rScale) { maskCI = b }

        guard let finalMaskCG = sharedContext.createCGImage(maskCI, from: CGRect(origin: .zero, size: originalSize)) else {
            throw MattingError.processingFailed
        }

        print("[RMBG] originalSize=\(originalSize), letterbox: offset=(\(offsetX),\(offsetY)), scaled=(\(scaledW),\(scaledH))")
        print("[RMBG] finalMaskCG size=\(finalMaskCG.width)x\(finalMaskCG.height)")

        let result = try blend(CIImage(cgImage: cgImage), mask: CIImage(cgImage: finalMaskCG), featherRadius: feather)
        print("[RMBG] result size=\(result.size), cgImage=\(result.cgImage != nil)")

        // DEBUG: 保存 segmentPerson 最终输出
        if let data = result.pngData() {
            let path = NSTemporaryDirectory() + "segment_final.png"
            try? data.write(to: URL(fileURLWithPath: path))
            print("[RMBG] Saved segment_final to \(path)")
        }

        return fixOrientation(result, to: image.imageOrientation)
    }

    /// 使用 RMBG1.4 模型生成遮罩(1024×1024,专为背景移除优化)
    private static func rmbgMask(for image: UIImage) throws -> UIImage {
        guard let url = Bundle.main.url(forResource: "RMBG_1_4", withExtension: "mlmodelc"),
              let mlModel = try? MLModel(contentsOf: url, configuration: {
                  let config = MLModelConfiguration()
                  config.computeUnits = .cpuAndNeuralEngine  // 避免模拟器 MPSGraph 不兼容
                  return config
              }()) else {
            print("[RMBG] Failed to load model")
            throw MattingError.processingFailed
        }

        // 使用 letterbox 缩放:保持宽高比,填充到 1024×1024
        let inputSize = CGSize(width: 1024, height: 1024)
        let originalSize = image.size
        let scale = min(inputSize.width / originalSize.width, inputSize.height / originalSize.height)
        let scaledW = originalSize.width * scale
        let scaledH = originalSize.height * scale
        let offsetX = (inputSize.width - scaledW) / 2.0
        let offsetY = (inputSize.height - scaledH) / 2.0

        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        guard let resizedCG = UIGraphicsImageRenderer(size: inputSize, format: fmt).image(actions: { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: inputSize))
            image.draw(in: CGRect(x: offsetX, y: offsetY, width: scaledW, height: scaledH))
        }).cgImage else {
            print("[RMBG] Failed to resize image")
            throw MattingError.processingFailed
        }

        // 先获取原始像素 [0,255]
        guard let dataProvider = resizedCG.dataProvider,
              let pixelData = CFDataGetBytePtr(dataProvider.data) else {
            print("[RMBG] Failed to get pixel data")
            throw MattingError.processingFailed
        }
        let width = resizedCG.width
        let height = resizedCG.height
        let bytesPerRow = resizedCG.bytesPerRow
        let bytesPerPixel = resizedCG.bitsPerPixel / 8

        // 创建 Float32 CVPixelBuffer(归一化到 [0,1])
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, 1024, 1024,
                                  kCVPixelFormatType_32ARGB, attrs, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else {
            print("[RMBG] Failed to create float pixel buffer")
            throw MattingError.processingFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let base = CVPixelBufferGetBaseAddress(buffer)!.bindMemory(to: Float32.self, capacity: 1024 * 1024 * 4)
        let bufBytesPerRow = CVPixelBufferGetBytesPerRow(buffer) / 4  // in float32 units

        for y in 0..<height {
            for x in 0..<width {
                let srcOff = y * bytesPerRow + x * bytesPerPixel
                let dstOff = y * bufBytesPerRow + x * 4
                // ARGB format, normalized to [0,1]
                base[dstOff + 1] = Float32(pixelData[srcOff]) / 255.0     // R at offset 1
                base[dstOff + 2] = Float32(pixelData[srcOff + 1]) / 255.0 // G at offset 2
                base[dstOff + 3] = Float32(pixelData[srcOff + 2]) / 255.0 // B at offset 3
                base[dstOff + 0] = 1.0                                     // A at offset 0
            }
        }

        // 推理
        let featureValue = MLFeatureValue(pixelBuffer: buffer)
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": featureValue])
        let prediction = try mlModel.prediction(from: input)
        guard let alphaMask = prediction.featureValue(for: "var_2534")?.multiArrayValue else {
            print("[RMBG] No var_2534 in prediction")
            throw MattingError.processingFailed
        }

        // 从 MLMultiArray (Float16, [1,1,1024,1024]) 创建灰度 CGImage
        let grayCount = 1024 * 1024
        var grayPixels = [UInt8](repeating: 0, count: grayCount)
        let ptr = alphaMask.dataPointer.bindMemory(to: Float16.self, capacity: grayCount)

        var minVal: Float = 1.0, maxVal: Float = 0.0
        var whiteCount = 0, blackCount = 0
        for i in 0..<grayCount {
            let val = Float(ptr[i])
            if val < minVal { minVal = val }
            if val > maxVal { maxVal = val }
            grayPixels[i] = UInt8(min(max(val * 255.0, 0), 255))
            if val > 0.5 { whiteCount += 1 }
            else { blackCount += 1 }
        }
        print("[RMBG] Mask value range: \(minVal) ~ \(maxVal), white=\(whiteCount) black=\(blackCount)")

        // DEBUG: 采样遮罩中心和顶部区域
        let cx = 512, cy = 512
        var centerVals: [Float] = []
        for dy in -5...5 {
            for dx in -5...5 {
                let idx = (cy + dy) * 1024 + (cx + dx)
                centerVals.append(Float(ptr[idx]))
            }
        }
        print("[RMBG] Center 11x11 mask mean: \(centerVals.reduce(0,+) / Float(centerVals.count))")

        // 采样顶部区域(帽子)
        var topVals: [Float] = []
        for y in 0..<50 {
            for x in 300..<700 {
                topVals.append(Float(ptr[y * 1024 + x]))
            }
        }
        print("[RMBG] Top region mask mean: \(topVals.reduce(0,+) / Float(topVals.count))")

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: NSData(bytes: &grayPixels, length: grayCount)),
              let mask1024 = CGImage(
                width: 1024, height: 1024,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1024,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent
              ) else {
            print("[RMBG] Failed to create CGImage from mask")
            throw MattingError.processingFailed
        }

        return UIImage(cgImage: mask1024)
    }

    static func segmentPerson(in image: UIImage, background: BackgroundStyle) async throws -> UIImage {
        var fg = try await segmentPerson(in: image)
        if fg.cgImage == nil {
            let f = UIGraphicsImageRendererFormat(); f.scale = fg.scale
            fg = UIGraphicsImageRenderer(size: fg.size, format: f).image { _ in fg.draw(at: .zero) }
        }
        guard fg.cgImage != nil else { throw MattingError.invalidImage }
        let size = image.size; let fmt = UIGraphicsImageRendererFormat(); fmt.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            switch background {
            case .transparent: break
            case .color(let c): c.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            case .blur(let r):
                if let b = blur(image, radius: r) { b.draw(in: CGRect(origin: .zero, size: size)) }
            case .image(let bg): bg.draw(in: CGRect(origin: .zero, size: size))
            }
            fg.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - 通用物体抠图

    static func segmentObject(in image: UIImage, feather: Double = 1.5) async throws -> UIImage {
        let cgImage = try prepareCGImage(from: image)
        let (workImage, workScale) = downsampleIfNeeded(cgImage)
        let result: UIImage
        // 优先 iOS 26 前景分割 → DeepLabV3 → 色差法
        if let fg = try? foregroundSegment(workImage, feather: feather) {
            result = fg
        } else if let deeplab = try? deeplabSegment(workImage, feather: feather) {
            result = deeplab
        } else {
            result = try colorBasedSegment(workImage, feather: feather)
        }
        let finalResult = workScale < 1 ? upscaleResult(result, to: cgImage, workScale: workScale) : result
        return fixOrientation(finalResult, to: image.imageOrientation)
    }

    /// 确保 CGImage 像素数据可读(通过 RGBA8 重绘)
    private static func ensureReadableCGImage(_ cgImage: CGImage) -> CGImage? {
        let w = cgImage.width, h = cgImage.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - 大图缩放处理

    private static func downsampleIfNeeded(_ cgImage: CGImage) -> (CGImage, CGFloat) {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let maxDim = max(w, h)
        guard maxDim > maxProcessingSize else { return (cgImage, 1) }

        let scale = maxProcessingSize / maxDim
        let newW = Int(w * scale), newH = Int(h * scale)
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: newW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (cgImage, 1) }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let scaled = ctx.makeImage() else { return (cgImage, 1) }
        return (scaled, scale)
    }

    private static func upscaleResult(_ result: UIImage, to originalCG: CGImage, workScale: CGFloat) -> UIImage {
        let origW = CGFloat(originalCG.width), origH = CGFloat(originalCG.height)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: origW, height: origH), format: fmt).image { ctx in
            result.draw(in: CGRect(x: 0, y: 0, width: origW, height: origH))
        }
    }

    // MARK: - 遮罩生成

    private static func generateMask(for cgImage: CGImage) throws -> CGImage {
        if let m = try? visionMask(cgImage) { return m }
        return try faceMask(cgImage)
    }

    private static func visionMask(_ cgImage: CGImage) throws -> CGImage {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])
        guard let buf = req.results?.first?.pixelBuffer else { throw MattingError.segmentationFailed }
        let ci = CIImage(cvPixelBuffer: buf)
        guard let cg = sharedContext.createCGImage(ci, from: ci.extent) else { throw MattingError.processingFailed }
        return cg
    }

    private static func faceMask(_ cgImage: CGImage) throws -> CGImage {
        let ci = CIImage(cgImage: cgImage)
        let faces = try detectFaces(in: cgImage)
        guard !faces.isEmpty else { throw MattingError.segmentationFailed }
        guard let maskCI = bodyContourMask(faces: faces, imageSize: ci.extent.size) else {
            throw MattingError.processingFailed
        }
        guard let cg = sharedContext.createCGImage(maskCI, from: maskCI.extent) else {
            throw MattingError.processingFailed
        }
        return cg
    }

    private static func detectFaces(in cgImage: CGImage) throws -> [CGRect] {
        guard let detector = CIDetector(ofType: CIDetectorTypeFace, context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyLow]) else {
            throw MattingError.segmentationFailed
        }
        return detector.features(in: CIImage(cgImage: cgImage)).map { $0.bounds }
    }

    private static func bodyContourMask(faces: [CGRect], imageSize: CGSize) -> CIImage? {
        let paths = faces.map { face -> UIBezierPath in
            let cx = face.midX, hw = face.width, ht = face.minY, hb = face.maxY
            let nw = hw * 0.4, sw = hw * 1.8
            let ny = hb + hw * 0.15, sy = ny + hw * 0.1
            let bb = min(imageSize.height, sy + hw * 2.5)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: cx - hw * 0.35, y: ht + hw * 0.15))
            p.addCurve(to: CGPoint(x: cx + hw * 0.35, y: ht + hw * 0.15),
                       controlPoint1: CGPoint(x: cx - hw * 0.5, y: ht - hw * 0.15),
                       controlPoint2: CGPoint(x: cx + hw * 0.5, y: ht - hw * 0.15))
            p.addLine(to: CGPoint(x: cx + hw * 0.4, y: hb))
            p.addLine(to: CGPoint(x: cx + nw * 0.5, y: ny))
            p.addLine(to: CGPoint(x: cx + sw * 0.5, y: sy))
            p.addCurve(to: CGPoint(x: cx + sw * 0.42, y: bb),
                       controlPoint1: CGPoint(x: cx + sw * 0.55, y: sy + (bb - sy) * 0.3),
                       controlPoint2: CGPoint(x: cx + sw * 0.48, y: sy + (bb - sy) * 0.5))
            p.addCurve(to: CGPoint(x: cx - sw * 0.42, y: bb),
                       controlPoint1: CGPoint(x: cx + sw * 0.2, y: bb + hw * 0.1),
                       controlPoint2: CGPoint(x: cx - sw * 0.2, y: bb + hw * 0.1))
            p.addCurve(to: CGPoint(x: cx - sw * 0.5, y: sy),
                       controlPoint1: CGPoint(x: cx - sw * 0.48, y: sy + (bb - sy) * 0.5),
                       controlPoint2: CGPoint(x: cx - sw * 0.55, y: sy + (bb - sy) * 0.3))
            p.addLine(to: CGPoint(x: cx - nw * 0.5, y: ny))
            p.addLine(to: CGPoint(x: cx - hw * 0.4, y: hb))
            p.close(); return p
        }
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        let img = UIGraphicsImageRenderer(size: imageSize, format: f).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: imageSize))
            UIColor.white.setFill(); paths.forEach { $0.fill() }
        }
        guard let cg = img.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    // MARK: - 色彩聚类通用抠图

    private static func colorBasedSegment(_ cgImage: CGImage, feather: Double = 1.5) throws -> UIImage {
        let w = cgImage.width, h = cgImage.height

        guard let safeCG = ensureReadableCGImage(cgImage) else {
            throw MattingError.processingFailed
        }

        let ciImage = CIImage(cgImage: safeCG)
        let rScale = max(1, CGFloat(max(w, h)) / 1024)

        // 采样边缘颜色(背景色)和中心颜色(前景色)
        let bgColor = sampleEdgeColorFast(from: safeCG)
        let fgColor = sampleRegionColor(from: safeCG,
            xRange: w/4..<(3*w/4), yRange: h/4..<(3*h/4))

        // 计算背景色和前景色之间的欧氏距离
        let colorDiff = sqrt(
            pow(bgColor.x - fgColor.x, 2) +
            pow(bgColor.y - fgColor.y, 2) +
            pow(bgColor.z - fgColor.z, 2)
        )

        // 自适应阈值
        let threshold: Float = {
            if colorDiff < 0.10 { return 0.15 }
            if colorDiff < 0.20 { return 0.10 }
            if colorDiff < 0.35 { return 0.07 }
            return 0.05
        }()

        // 生成遮罩
        guard let maskCG = pixelMaskFast(from: safeCG, bgR: bgColor.x, bgG: bgColor.y, bgB: bgColor.z, t: threshold) else {
            throw MattingError.processingFailed
        }

        var maskCI = CIImage(cgImage: maskCG)

        // 闭运算填孔 + 开运算去噪
        if let d = morph(maskCI, r: 5 * rScale, dilate: true) { maskCI = d }
        if let e = morph(maskCI, r: 4 * rScale, dilate: false) { maskCI = e }
        if let e = morph(maskCI, r: 2 * rScale, dilate: false) { maskCI = e }
        if let d = morph(maskCI, r: 1.5 * rScale, dilate: true) { maskCI = d }

        // 二值化
        if let binarized = binarizeMask(maskCI) { maskCI = binarized }

        // Flood Fill 填内部穿孔
        if let filled = fillInteriorHoles(maskCI) { maskCI = filled }

        // 移除前景中的孤立小区域
        if let cleaned = removeSmallForegroundRegions(maskCI) { maskCI = cleaned }

        // 轻微羽化 0.5px 柔化边界
        if let b = featherMask(maskCI, radius: 0.5 * rScale) { maskCI = b }

        if let maskCG = sharedContext.createCGImage(maskCI, from: maskCI.extent) {
            lastMaskImage = UIImage(cgImage: maskCG)
        }

        return try blend(ciImage, mask: maskCI, featherRadius: feather)
    }

    /// 二值化遮罩:>threshold → 255(纯白), ≤threshold → 0(纯黑),消除灰色过渡
    private static func binarizeMask(_ mask: CIImage, threshold: UInt8 = 128) -> CIImage? {
        guard let cgMask = sharedContext.createCGImage(mask, from: mask.extent) else { return nil }
        let w = cgMask.width, h = cgMask.height
        let total = w * h

        guard let ctx = CGContext(data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cgMask, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: total)

        var changed = 0
        for i in 0..<total {
            let newVal: UInt8 = pixels[i] >= threshold ? 255 : 0
            if pixels[i] != newVal { changed += 1 }
            pixels[i] = newVal
        }

        guard changed > 0, let result = ctx.makeImage() else { return mask }
        print("[Binarize] threshold=\(threshold), changed=\(changed)/\(total)")
        return CIImage(cgImage: result)
    }

    /// 填充内部穿孔:用距离变换,远离边缘的背景像素 → 填为前景
    private static func fillInteriorHoles(_ mask: CIImage) -> CIImage? {
        guard let cgMask = sharedContext.createCGImage(mask, from: mask.extent) else { return nil }
        let w = cgMask.width, h = cgMask.height
        let totalPixels = w * h

        guard let ctx = CGContext(data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cgMask, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: totalPixels)

        // 距离变换:计算每个背景像素到最近前景像素的距离
        // 用 BFS 从所有前景像素出发
        var dist = [Int](repeating: Int.max, count: totalPixels)
        var queue: [(Int, Int)] = []

        // 所有前景像素(255)距离=0
        for i in 0..<totalPixels {
            if pixels[i] >= 128 {
                dist[i] = 0
                queue.append((i % w, i / w))
            }
        }

        guard !queue.isEmpty else { return mask }

        let dirs = [(0,1),(0,-1),(1,0),(-1,0)]
        var head = 0
        while head < queue.count {
            let (cx, cy) = queue[head]; head += 1
            let cd = dist[cy * w + cx]
            for (dx, dy) in dirs {
                let nx = cx + dx, ny = cy + dy
                guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                let nidx = ny * w + nx
                if dist[nidx] > cd + 1 {
                    dist[nidx] = cd + 1
                    queue.append((nx, ny))
                }
            }
        }

        // 距离 > 阈值 的背景像素填为前景(内部穿孔)
        let minDist = 1  // 距边缘超过 1px 的背景填为前景
        var filled = 0
        for i in 0..<totalPixels {
            if pixels[i] < 128, dist[i] > minDist {
                pixels[i] = 255
                filled += 1
            }
        }

        guard filled > 0, let result = ctx.makeImage() else { return mask }
        return CIImage(cgImage: result)
    }

    /// 移除前景中的孤立小区域（连通域分析）
    /// 检测二值遮罩中的前景连通域，面积 < minArea 的移除
    private static func removeSmallForegroundRegions(_ mask: CIImage, minArea: Int = 200) -> CIImage? {
        guard let cgMask = sharedContext.createCGImage(mask, from: mask.extent) else { return nil }
        let w = cgMask.width, h = cgMask.height
        let totalPixels = w * h

        guard let ctx = CGContext(data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cgMask, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: totalPixels)

        // BFS 连通域标记
        var visited = [Bool](repeating: false, count: totalPixels)
        var regions: [[Int]] = []  // 每个连通域的像素索引列表

        let dirs4 = [(0,1),(0,-1),(1,0),(-1,0)]
        for y in 0..<h {
            for x in 0..<w {
                let idx = y * w + x
                if visited[idx] || pixels[idx] < 128 { continue }

                // BFS 找连通域
                var region: [Int] = []
                var queue = [(x, y)]
                visited[idx] = true
                var head = 0
                while head < queue.count {
                    let (cx, cy) = queue[head]; head += 1
                    region.append(cy * w + cx)
                    for (dx, dy) in dirs4 {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        let nidx = ny * w + nx
                        if !visited[nidx], pixels[nidx] >= 128 {
                            visited[nidx] = true
                            queue.append((nx, ny))
                        }
                    }
                }
                regions.append(region)
            }
        }

        guard !regions.isEmpty else { return mask }

        // 找到最大的连通域（主体）
        guard let maxRegion = regions.max(by: { $0.count < $1.count }) else { return mask }
        let maxArea = maxRegion.count

        // 移除面积 < minArea 且不是最大连通域的小区域
        var removed = 0
        for region in regions {
            if region.count < minArea && region.count < maxArea {
                for idx in region {
                    pixels[idx] = 0
                    removed += 1
                }
            }
        }

        guard removed > 0, let result = ctx.makeImage() else { return mask }
        print("[CleanUp] Removed \(removed) pixels from \(regions.count) regions (maxArea=\(maxArea))")
        return CIImage(cgImage: result)
    }

    /// 自动清理遮罩边缘的灰色不确定区域
    /// 检测遮罩中 0.1~0.9 的灰色像素，如果靠近背景（< 0.5），自动擦除
    private static func autoCleanEdge(_ mask: CIImage) -> CIImage? {
        guard let cgMask = sharedContext.createCGImage(mask, from: mask.extent) else { return nil }
        let w = cgMask.width, h = cgMask.height
        let totalPixels = w * h

        guard let ctx = CGContext(data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cgMask, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: totalPixels)

        // 找边缘灰色像素：值在 20~235 之间的不确定区域
        // 对这些像素做局部判断：如果周围背景像素多于前景像素，就擦除
        var cleaned = 0
        var temp = [UInt8](repeating: 0, count: totalPixels)
        for i in 0..<totalPixels {
            let v = pixels[i]
            if v >= 20 && v <= 235 {
                // 灰色不确定区域
                let x = i % w, y = i / w
                var bgCount = 0, fgCount = 0
                let radius = 3
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        let nv = pixels[ny * w + nx]
                        if nv < 64 { bgCount += 1 }
                        else if nv > 192 { fgCount += 1 }
                    }
                }
                // 周围背景像素 > 前景像素 → 擦除
                temp[i] = bgCount > fgCount ? 0 : 255
                if temp[i] != v { cleaned += 1 }
            } else {
                temp[i] = v
            }
        }

        guard cleaned > 0 else { return mask }

        // 写回
        for i in 0..<totalPixels { pixels[i] = temp[i] }
        guard let result = ctx.makeImage() else { return mask }
        print("[AutoClean] Cleaned \(cleaned) gray edge pixels")
        return CIImage(cgImage: result)
    }

    /// 采样指定区域的平均颜色
    private static func sampleRegionColor(from cgImage: CGImage, xRange: Range<Int>, yRange: Range<Int>) -> SIMD4<Float> {
        guard let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return SIMD4<Float>(0.5, 0.5, 0.5, 1)
        }
        let bpp = cgImage.bitsPerPixel / 8, bpr = cgImage.bytesPerRow
        let step = 4
        var rs: Float = 0, gs: Float = 0, bs: Float = 0, cnt: Float = 0

        let xr = xRange.clamped(to: 0..<cgImage.width)
        let yr = yRange.clamped(to: 0..<cgImage.height)
        for y in stride(from: yr.lowerBound, to: yr.upperBound, by: step) {
            for x in stride(from: xr.lowerBound, to: xr.upperBound, by: step) {
                let off = y * bpr + x * bpp
                rs += Float(bytes[off]) / 255; gs += Float(bytes[off+1]) / 255; bs += Float(bytes[off+2]) / 255; cnt += 1
            }
        }
        guard cnt > 0 else { return SIMD4<Float>(0.5, 0.5, 0.5, 1) }
        return SIMD4<Float>(rs / cnt, gs / cnt, bs / cnt, 1)
    }

    // MARK: - vDSP 加速方法

    /// 跳步采样边缘+四角颜色(重点采四角,因为主体通常在中心)
    private static func sampleEdgeColorFast(from cgImage: CGImage) -> SIMD4<Float> {
        guard let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return SIMD4<Float>(0.5, 0.5, 0.5, 1)
        }
        let w = cgImage.width, h = cgImage.height, bpp = cgImage.bitsPerPixel / 8, bpr = cgImage.bytesPerRow
        let cw = w / 8, ch = h / 8  // 四角区域大小
        let step = 4
        var rs: Float = 0, gs: Float = 0, bs: Float = 0, cnt: Float = 0

        // 采样四角(权重更高:每个角采样 2 次)
        let corners: [(Range<Int>, Range<Int>)] = [
            (0..<cw, 0..<ch),                     // 左上
            ((w-cw)..<w, 0..<ch),                  // 右上
            (0..<cw, (h-ch)..<h),                  // 左下
            ((w-cw)..<w, (h-ch)..<h)               // 右下
        ]
        for (xr, yr) in corners {
            for _ in 0..<2 {  // 每个角采两次,增加权重
                for x in stride(from: xr.lowerBound, to: xr.upperBound, by: step) {
                    for y in stride(from: yr.lowerBound, to: yr.upperBound, by: step) {
                        let off = y * bpr + x * bpp
                        rs += Float(bytes[off]) / 255; gs += Float(bytes[off+1]) / 255; bs += Float(bytes[off+2]) / 255; cnt += 1
                    }
                }
            }
        }

        // 四边采样(补充)
        let ew = max(1, w / 20), eh = max(1, h / 20)
        for x in stride(from: cw, to: w-cw, by: step) {
            for y in stride(from: 0, to: eh, by: step) {
                let off = y * bpr + x * bpp
                rs += Float(bytes[off]) / 255; gs += Float(bytes[off+1]) / 255; bs += Float(bytes[off+2]) / 255; cnt += 1
            }
            for y in stride(from: h-eh, to: h, by: step) {
                let off = y * bpr + x * bpp
                rs += Float(bytes[off]) / 255; gs += Float(bytes[off+1]) / 255; bs += Float(bytes[off+2]) / 255; cnt += 1
            }
        }
        for y in stride(from: ch, to: h-ch, by: step) {
            for x in stride(from: 0, to: ew, by: step) {
                let off = y * bpr + x * bpp
                rs += Float(bytes[off]) / 255; gs += Float(bytes[off+1]) / 255; bs += Float(bytes[off+2]) / 255; cnt += 1
            }
            for x in stride(from: w-ew, to: w, by: step) {
                let off = y * bpr + x * bpp
                rs += Float(bytes[off]) / 255; gs += Float(bytes[off+1]) / 255; bs += Float(bytes[off+2]) / 255; cnt += 1
            }
        }
        guard cnt > 0 else { return SIMD4<Float>(0.5, 0.5, 0.5, 1) }
        return SIMD4<Float>(rs / cnt, gs / cnt, bs / cnt, 1)
    }

    /// vDSP 向量化像素距离计算
    /// invert=false: 远离目标色=前景(255);invert=true: 接近目标色=前景(255)
    private static func pixelMaskFast(from cgImage: CGImage, bgR: Float, bgG: Float, bgB: Float, t: Float, invert: Bool = false) -> CGImage? {
        let w = cgImage.width, h = cgImage.height
        let pixelCount = w * h

        guard let src = cgImage.dataProvider?.data, let sb = CFDataGetBytePtr(src) else { return nil }
        let bpp = cgImage.bitsPerPixel / 8, bpr = cgImage.bytesPerRow

        // 分配浮点数组用于 vDSP 计算
        let rPtr = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let gPtr = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let bPtr = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let distPtr = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        defer { rPtr.deallocate(); gPtr.deallocate(); bPtr.deallocate(); distPtr.deallocate() }

        // 提取 RGB 通道到独立数组
        var idx = 0
        for y in 0..<h {
            let rowBase = y * bpr
            for x in 0..<w {
                let off = rowBase + x * bpp
                rPtr[idx] = Float(sb[off]) / 255
                gPtr[idx] = Float(sb[off+1]) / 255
                bPtr[idx] = Float(sb[off+2]) / 255
                idx += 1
            }
        }

        // vDSP 向量减法:(R - bgR), (G - bgG), (B - bgB)
        var negBgR = -bgR, negBgG = -bgG, negBgB = -bgB
        vDSP_vsadd(rPtr, 1, &negBgR, rPtr, 1, vDSP_Length(pixelCount))
        vDSP_vsadd(gPtr, 1, &negBgG, gPtr, 1, vDSP_Length(pixelCount))
        vDSP_vsadd(bPtr, 1, &negBgB, bPtr, 1, vDSP_Length(pixelCount))

        // 平方
        vDSP_vsq(rPtr, 1, rPtr, 1, vDSP_Length(pixelCount))
        vDSP_vsq(gPtr, 1, gPtr, 1, vDSP_Length(pixelCount))
        vDSP_vsq(bPtr, 1, bPtr, 1, vDSP_Length(pixelCount))

        // 相加:dist = r2 + g2 + b2
        vDSP_vadd(rPtr, 1, gPtr, 1, distPtr, 1, vDSP_Length(pixelCount))
        vDSP_vadd(distPtr, 1, bPtr, 1, distPtr, 1, vDSP_Length(pixelCount))

        // 开方
        var count = Int32(pixelCount)
        vvsqrtf(distPtr, distPtr, &count)

        // 阈值比较 → 生成遮罩
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
            let dst = ctx.data else { return nil }
        let db = dst.bindMemory(to: UInt8.self, capacity: pixelCount)

        let tSq = t
        if invert {
            // 接近目标色 → 前景(255)
            for i in 0..<pixelCount {
                db[i] = distPtr[i] < tSq ? 255 : 0
            }
        } else {
            // 远离目标色 → 前景(255)
            for i in 0..<pixelCount {
                db[i] = distPtr[i] > tSq ? 255 : 0
            }
        }

        return ctx.makeImage()
    }

    // MARK: - 背景样式

    enum BackgroundStyle {
        case transparent
        case color(UIColor)
        case blur(radius: CGFloat)
        case image(UIImage)
    }

    // MARK: - 工具方法

    static func blend(_ image: CIImage, mask: CIImage, featherRadius: Double = 1.5) throws -> UIImage {
        // 手动逐像素合成:把遮罩灰度值写入 alpha 通道
        let softMask: CIImage
        if featherRadius > 0, let blurred = featherMask(mask, radius: CGFloat(featherRadius)) {
            softMask = blurred
        } else {
            softMask = mask
        }

        let imageExtent = image.extent
        let w = Int(imageExtent.width)
        let h = Int(imageExtent.height)

        // 渲染 image 和 mask 为 CGImage
        guard let imageCG = sharedContext.createCGImage(image, from: imageExtent),
              let maskCG = sharedContext.createCGImage(softMask, from: imageExtent) else {
            throw MattingError.processingFailed
        }

        // 创建 RGBA 画布
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
            throw MattingError.processingFailed
        }

        // 绘制原图
        ctx.draw(imageCG, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rgbData = ctx.data else { throw MattingError.processingFailed }
        let rgbBytes = rgbData.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // 读取遮罩灰度值
        guard let maskProvider = maskCG.dataProvider,
              let maskData = CFDataGetBytePtr(maskProvider.data) else {
            throw MattingError.processingFailed
        }
        let maskBPR = maskCG.bytesPerRow

        // 把遮罩写入 alpha 通道,阈值二值化消除半透明
        for y in 0..<h {
            for x in 0..<w {
                let off = y * w * 4 + x * 4
                let maskOff = y * maskBPR + x
                let rawAlpha = maskData[maskOff]
                rgbBytes[off + 3] = rawAlpha >= 128 ? 255 : 0
            }
        }

        guard let resultCG = ctx.makeImage() else { throw MattingError.processingFailed }

        // DEBUG
        if let data = UIImage(cgImage: resultCG).pngData() {
            let path = NSTemporaryDirectory() + "blend_debug.png"
            try? data.write(to: URL(fileURLWithPath: path))
            print("[BLEND] Saved debug to \(path)")
        }

        return UIImage(cgImage: resultCG, scale: 1, orientation: .up)
    }

    static func morph(_ image: CIImage, r: CGFloat, dilate: Bool) -> CIImage? {
        let name = dilate ? "CIMorphologyMaximum" : "CIMorphologyMinimum"
        return CIFilter(name: name, parameters: [kCIInputImageKey: image, kCIInputRadiusKey: r])?.outputImage
    }

    static func featherMask(_ mask: CIImage, radius: CGFloat = 2) -> CIImage? {
        return CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: mask,
            kCIInputRadiusKey: radius
        ])?.outputImage
    }

    static func feather(_ image: UIImage, radius: CGFloat = 2) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let f = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: CIImage(cgImage: cg), kCIInputRadiusKey: radius])
        guard let out = f?.outputImage else { return nil }
        return UIImage(ciImage: out)
    }

    static func exportAsPNG(_ image: UIImage) -> Data? { image.pngData() }

    /// 把结果图的方向修正为和原图一致
    private static func fixOrientation(_ image: UIImage, to orientation: UIImage.Orientation) -> UIImage {
        guard orientation != .up, let cg = image.cgImage else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: orientation)
    }

    // MARK: - Private Helpers

    private static func prepareCGImage(from image: UIImage) throws -> CGImage {
        if let cg = image.cgImage { return cg }
        if let ci = image.ciImage, let cg = sharedContext.createCGImage(ci, from: ci.extent) { return cg }
        let f = UIGraphicsImageRendererFormat(); f.scale = image.scale
        let r = UIGraphicsImageRenderer(size: image.size, format: f).image { _ in image.draw(at: .zero) }
        guard let cg = r.cgImage else { throw MattingError.invalidImage }
        return cg
    }

    static func blur(_ image: UIImage, radius: CGFloat) -> UIImage? {
        guard let ci = CIImage(image: image) else { return nil }
        let f = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: ci, kCIInputRadiusKey: radius])
        guard let out = f?.outputImage, let cg = sharedContext.createCGImage(out, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

enum MattingError: LocalizedError {
    case invalidImage, segmentationFailed, processingFailed
    var errorDescription: String? {
        switch self {
        case .invalidImage: "无法读取图片"
        case .segmentationFailed: "未检测到主体"
        case .processingFailed: "图片处理失败"
        }
    }
}
