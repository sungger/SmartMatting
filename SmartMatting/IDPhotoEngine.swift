import UIKit
import CoreImage

/// 证件照引擎
final class IDPhotoEngine {

    enum PhotoSize: String, CaseIterable, Identifiable {
        case small1 = "小一寸"
        case inch1 = "一寸"
        case inch2 = "二寸"

        var id: String { rawValue }

        var sizeMM: CGSize {
            switch self {
            case .small1: CGSize(width: 22, height: 32)
            case .inch1:  CGSize(width: 25, height: 35)
            case .inch2:  CGSize(width: 35, height: 49)
            }
        }

        var pixelSize: CGSize {
            let dpi: CGFloat = 300
            let mmPerInch: CGFloat = 25.4
            return CGSize(
                width: sizeMM.width / mmPerInch * dpi,
                height: sizeMM.height / mmPerInch * dpi
            )
        }
    }

    enum BackgroundColor: String, CaseIterable, Identifiable {
        case red = "红色"
        case blue = "蓝色"
        case white = "白色"

        var id: String { rawValue }

        var uiColor: UIColor {
            switch self {
            case .red:  UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1)
            case .blue: UIColor(red: 0.20, green: 0.45, blue: 0.85, alpha: 1)
            case .white: .white
            }
        }
    }

    static func generate(
        foreground: UIImage,
        size: PhotoSize,
        bgColor: BackgroundColor,
        originalImage: UIImage
    ) -> UIImage {
        let canvas = size.pixelSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        // 裁剪透明区域，获取人物实际包围盒
        let personRect = trimTransparent(foreground)
        
        guard personRect.width > 0, personRect.height > 0 else {
            // Fallback: 直接画整个前景
            return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
                bgColor.uiColor.setFill()
                ctx.fill(CGRect(origin: .zero, size: canvas))
                let fgSize = foreground.size
                let scale = min(canvas.width * 0.82 / fgSize.width, canvas.height * 0.62 / fgSize.height)
                let dw = fgSize.width * scale
                let dh = fgSize.height * scale
                foreground.draw(in: CGRect(x: (canvas.width - dw) / 2, y: canvas.height * 0.17, width: dw, height: dh))
            }
        }

        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            bgColor.uiColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))

            guard let cgImage = foreground.cgImage else { return }

            // 证件照只需要上半身，裁剪到人物高度的 55%（头+肩+胸）
            let cropHeight = personRect.height * 0.55
            let cropY = personRect.origin.y
            let cropRect = CGRect(x: personRect.origin.x, y: cropY, width: personRect.width, height: cropHeight)

            let maxPersonHeight = canvas.height * 0.65
            let maxPersonWidth = canvas.width * 0.85

            let scale = min(maxPersonWidth / cropRect.width, maxPersonHeight / cropRect.height)
            let drawWidth = cropRect.width * scale
            let drawHeight = cropRect.height * scale
            let drawX = (canvas.width - drawWidth) / 2
            let drawY = canvas.height * 0.15

            if let cropped = cgImage.cropping(to: cropRect) {
                UIImage(cgImage: cropped).draw(in: CGRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight))
            }
        }
    }

    /// 裁剪透明区域，返回非透明像素的包围盒（归一化坐标 0~1）
    private static func trimTransparent(_ image: UIImage) -> CGRect {
        guard let cgImage = image.cgImage else { return .zero }
        let width = cgImage.width
        let height = cgImage.height

        guard let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return .zero }

        let bpp = cgImage.bitsPerPixel / 8
        let bpr = cgImage.bytesPerRow

        var minX = width, minY = height, maxX = 0, maxY = 0

        let step = max(1, min(width, height) / 300)

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let alpha = bytes[y * bpr + x * bpp + (bpp - 1)]
                if alpha > 10 {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard maxX > minX, maxY > minY else { return .zero }

        let padPx: CGFloat = CGFloat(max(width, height)) * 0.02
        let nx = max(0, CGFloat(minX) - padPx)
        let ny = max(0, CGFloat(minY) - padPx)
        let nw = min(CGFloat(width) - nx, CGFloat(maxX - minX) + padPx * 2)
        let nh = min(CGFloat(height) - ny, CGFloat(maxY - minY) + padPx * 2)

        // 返回像素坐标
        return CGRect(x: nx, y: ny, width: nw, height: nh)
    }
}
