import SwiftUI
import PhotosUI
import Photos

struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var originalImage: UIImage?
    @State private var resultImage: UIImage?
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var selectedBackground: BackgroundOption = .transparent
    @State private var showingShareSheet = false
    @State private var mattingMode: MattingMode = .person

    // 批量抠图
    @State private var batchImages: [UIImage] = []
    @State private var batchResults: [UIImage] = []
    @State private var batchIndex: Int = 0
    @State private var batchTotal: Int = 0
    @State private var isBatchMode = false
    @State private var showSaveAlert = false
    @State private var saveMessage = ""

    // 缩略图缓存（小图，减少内存）
    @State private var batchThumbnails: [UIImage] = []

    // 抠出的前景图（人像/通用模式共用）
    @State private var foregroundImage: UIImage?

    // 证件照参数
    @State private var idPhotoSize: IDPhotoEngine.PhotoSize = .inch1
    @State private var idPhotoColor: IDPhotoEngine.BackgroundColor = .red

    // 边缘羽化强度（0 = 硬边，5 = 柔和）
    @State private var featherStrength: Double = 1.5

    // 滤镜
    @State private var selectedFilter: FilterOption = .none
    @State private var filteredImage: UIImage?

    // 重试计数
    @State private var retryCount = 0

    // 轮廓线显示
    @State private var showContour = true
    @State private var contourImage: UIImage?

    /// 处理进度提示文字
    var processingMessage: String {
        if mattingMode == .person {
            return "正在人像抠图中…"
        } else {
            return "正在通用抠图中…"
        }
    }

    enum MattingMode: String, CaseIterable {
        case person = "人像"
        case object = "通用"
    }

    enum BackgroundOption: String, CaseIterable, Identifiable {
        case transparent = "透明"
        case white = "白色"
        case blue = "蓝色"
        case red = "红色"
        case blur = "模糊"
        case idPhoto = "证件照"

        var id: String { rawValue }

        var color: UIColor {
            switch self {
            case .white: .white
            case .blue: .systemBlue
            case .red: .systemRed
            default: .clear
            }
        }

        /// 当前模式是否可用
        func available(in mode: MattingMode) -> Bool {
            if self == .idPhoto { return mode == .person }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // 渐变背景
                LinearGradient(
                    colors: [Color(.systemGray6), Color(.systemBackground)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    if isBatchMode && !batchImages.isEmpty {
                        batchModeContent
                    } else {
                        normalModeContent
                    }
                }
            }
            .navigationTitle("智能抠图")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if resultImage != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            reset()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("返回")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") { saveToAlbum() }
                            .accessibilityLabel("保存到相册")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: { showingShareSheet = true }) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("分享")
                    }
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let image = resultImage {
                ShareSheet(items: [image])
            }
        }
        .alert("保存成功", isPresented: $showSaveAlert) {
            Button("好的") { }
        } message: {
            Text(saveMessage)
        }
    }

    // MARK: - 批量模式内容

    var batchModeContent: some View {
        VStack(spacing: 12) {
            imagePreviewArea
                .frame(maxWidth: .infinity)
                .frame(minHeight: 200)

            Divider()

            Text("已选 \(batchImages.count) 张图片")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .accessibilityLabel("已选\(batchImages.count)张图片")

            if isProcessing {
                VStack(spacing: 8) {
                    ProgressView(value: Double(batchIndex), total: Double(batchTotal))
                        .padding(.horizontal, 32)
                        .accessibilityLabel("批量处理进度")
                        .accessibilityValue("\(batchIndex) / \(batchTotal)")
                    Text("正在处理 \(batchIndex)/\(batchTotal)…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(batchThumbnails.enumerated()), id: \.offset) { idx, img in
                        VStack(spacing: 4) {
                            ZStack {
                                if idx < batchResults.count {
                                    Image(uiImage: batchResults[idx])
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .opacity(0.5)
                                }
                                if isProcessing && idx == batchIndex - 1 {
                                    ProgressView()
                                }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        originalImage == img ? Color.accentColor :
                                        (idx < batchResults.count ? Color.green : Color.clear),
                                        lineWidth: originalImage == img ? 3 : 2
                                    )
                            )
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("第\(idx + 1)张")
                            .accessibilityValue(idx < batchResults.count ? "已完成" : "等待处理")
                            .accessibilityAddTraits(originalImage == img ? .isSelected : [])
                            if idx < batchResults.count {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if idx < batchResults.count {
                                resultImage = batchResults[idx]
                                foregroundImage = batchResults[idx]
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }

            if !isProcessing {
                if !batchResults.isEmpty {
                    HStack(spacing: 12) {
                        Button {
                            saveAllBatchResults()
                        } label: {
                            Label("全部保存", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("全部保存")
                        .accessibilityHint("将所有抠图结果保存到相册")

                        Button {
                            showingShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("分享当前结果")

                        Button {
                            isBatchMode = false
                            batchImages = []
                            batchThumbnails = []
                            batchResults = []
                            selectedItems = []
                        } label: {
                            Text("完成")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("完成批量抠图")
                    }
                } else {
                    Button {
                        startBatchProcessing()
                    } label: {
                        Label("开始批量抠图", systemImage: "play.rectangle")
                            .font(.headline)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("开始批量抠图")
                    .accessibilityHint("对\(batchImages.count)张图片依次抠图")
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - 正常模式内容

    var normalModeContent: some View {
        Group {
            Spacer()

            imagePreviewArea
                .frame(maxWidth: .infinity)

            Spacer()

            if originalImage == nil {
                VStack(spacing: 12) {
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Label("选择图片", systemImage: "photo.badge.plus")
                            .font(.headline)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .onChange(of: selectedItem) { _, newItem in
                        loadImage(from: newItem)
                    }
                    .accessibilityLabel("选择图片")
                    .accessibilityHint("从相册中选择一张照片开始抠图")

                    PhotosPicker(selection: $selectedItems, maxSelectionCount: 10, matching: .images) {
                        Label("批量抠图", systemImage: "square.stack.3d.up")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .onChange(of: selectedItems) { _, items in
                        if !items.isEmpty { loadBatchImages(items) }
                    }
                    .accessibilityLabel("批量抠图")
                    .accessibilityHint("一次选择最多10张照片进行批量抠图")
                }
            }

            if resultImage != nil {
                backgroundPicker
                    .padding(.top, 8)
            }

            if selectedBackground == .idPhoto && resultImage != nil {
                idPhotoOptions
                    .padding(.top, 4)
            }

            if originalImage != nil {
                VStack(spacing: 8) {
                    Picker("模式", selection: $mattingMode) {
                        ForEach(MattingMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .onChange(of: mattingMode) { _, _ in
                        resultImage = nil
                        foregroundImage = nil
                        selectedBackground = .transparent
                    }
                    .accessibilityLabel("抠图模式")
                    .accessibilityHint("切换人像抠图或通用物体抠图")

                    HStack(spacing: 12) {
                        PhotosPicker(selection: $selectedItem, matching: .images) {
                            Label("选图", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .onChange(of: selectedItem) { _, newItem in
                            loadImage(from: newItem)
                        }
                        .accessibilityLabel("重新选图")

                        Button {
                            reset()
                        } label: {
                            Label("重置", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isProcessing)
                        .accessibilityLabel("重置")
                        .accessibilityHint("清除当前图片和抠图结果")
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - 图片预览

    @ViewBuilder
    var imagePreviewArea: some View {
        Group {
            if isProcessing {
                VStack(spacing: 20) {
                    // 旋转圆环动画
                    ZStack {
                        Circle()
                            .stroke(Color(.systemGray5), lineWidth: 4)
                            .frame(width: 60, height: 60)
                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(
                                LinearGradient(
                                    colors: [.blue, .purple, .pink],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round)
                            )
                            .frame(width: 60, height: 60)
                            .rotationEffect(.degrees(isProcessing ? 360 : 0))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isProcessing)
                    }
                    Text(processingMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(40)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(processingMessage)
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                        .accessibilityHidden(true)
                    Text(error)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button {
                        retrySegmentation()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("重试抠图")
                    .accessibilityHint("重新尝试对当前照片进行抠图")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("错误：\(error)")
            } else if let result = resultImage {
                ZStack {
                    Image(uiImage: checkerboardImage(size: result.size))
                        .resizable()
                        .scaledToFit()
                        .accessibilityHidden(true)
                    Image(uiImage: result)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("抠图结果")
                    // 轮廓线叠加
                    if showContour, let contour = contourImage {
                        Image(uiImage: contour)
                            .resizable()
                            .scaledToFit()
                            .accessibilityHidden(true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.horizontal, 20)
                // 轮廓线开关
                .overlay(alignment: .topTrailing) {
                    Button {
                        showContour.toggle()
                    } label: {
                        Image(systemName: showContour ? "eye" : "eye.slash")
                            .font(.caption)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .padding(8)
                    .accessibilityLabel(showContour ? "隐藏轮廓线" : "显示轮廓线")
                }
            } else if let original = originalImage {
                Image(uiImage: original)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    .padding(.horizontal, 20)
                    .accessibilityLabel("已选择的原始图片")
            } else {
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [.blue.opacity(0.1), .purple.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 100, height: 100)
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 44))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    Text("选择一张照片开始抠图")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("空状态：选择一张照片开始抠图")
            }
        }
    }

    // MARK: - 背景选择

    var backgroundPicker: some View {
        VStack(spacing: 6) {
            Text("背景")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(BackgroundOption.allCases) { option in
                        if option.available(in: mattingMode) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedBackground = option
                                }
                                applyBackground(option)
                            } label: {
                                VStack(spacing: 6) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(selectedBackground == option ? Color.accentColor.opacity(0.15) : Color(.systemGray5))
                                            .frame(width: 52, height: 52)
                                        if option == .idPhoto {
                                            Image(systemName: "person.crop.rectangle")
                                                .font(.system(size: 20))
                                                .foregroundColor(selectedBackground == option ? .accentColor : .secondary)
                                        } else if option == .transparent {
                                            Image(systemName: "checkerboard.rectangle")
                                                .font(.system(size: 20))
                                                .foregroundColor(selectedBackground == option ? .accentColor : .secondary)
                                        } else if option == .blur {
                                            Image(systemName: "circle.dotted")
                                                .font(.system(size: 20))
                                                .foregroundColor(selectedBackground == option ? .accentColor : .secondary)
                                        } else {
                                            Circle()
                                                .fill(bgColor(option))
                                                .frame(width: 24, height: 24)
                                                .overlay(
                                                    Circle()
                                                        .stroke(Color(.systemGray4), lineWidth: 1)
                                                )
                                        }
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(selectedBackground == option ? Color.accentColor : Color.clear, lineWidth: 2)
                                    )
                                    Text(option.rawValue)
                                        .font(.caption2)
                                        .foregroundColor(selectedBackground == option ? .accentColor : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(option.rawValue)背景")
                            .accessibilityAddTraits(selectedBackground == option ? .isSelected : [])
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
            .accessibilityLabel("背景选择")

            // 边缘羽化
            if resultImage != nil {
                VStack(spacing: 4) {
                    HStack {
                        Text("边缘羽化")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.1f px", featherStrength))
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                    Slider(value: $featherStrength, in: 0...5, step: 0.5)
                        .onChange(of: featherStrength) { _, _ in reapplyFeather() }
                        .accessibilityLabel("边缘羽化强度")
                        .accessibilityValue(String(format: "%.1f像素", featherStrength))
                        .accessibilityHint("调整抠图边缘的柔和程度")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            // 滤镜
            if resultImage != nil {
                VStack(spacing: 4) {
                    HStack {
                        Text("滤镜")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(FilterOption.allCases) { filter in
                                VStack(spacing: 2) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color(.systemGray5))
                                            .frame(width: 48, height: 48)
                                        if let thumb = filter == .none ? resultImage : filter.apply(to: resultImage!) {
                                            Image(uiImage: thumb)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 44, height: 44)
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                        }
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(selectedFilter == filter ? Color.accentColor : Color.clear, lineWidth: 2)
                                    )
                                    Text(filter.rawValue)
                                        .font(.caption2)
                                        .foregroundColor(selectedFilter == filter ? .accentColor : .secondary)
                                }
                                .onTapGesture {
                                    selectedFilter = filter
                                    applyFilter()
                                }
                                .accessibilityLabel("\(filter.rawValue)滤镜")
                                .accessibilityHint("应用\(filter.rawValue)滤镜效果")
                                .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - 证件照选项

    var idPhotoOptions: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Text("尺寸")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("尺寸", selection: $idPhotoSize) {
                    ForEach(IDPhotoEngine.PhotoSize.allCases) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: idPhotoSize) { _, _ in regenerateIDPhoto() }
                .accessibilityLabel("证件照尺寸")
                .accessibilityHint("选择一寸、二寸或小一寸")
            }

            HStack(spacing: 8) {
                Text("底色")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(IDPhotoEngine.BackgroundColor.allCases) { color in
                    Button {
                        idPhotoColor = color
                        regenerateIDPhoto()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(uiColor: color.uiColor))
                                .frame(width: 28, height: 28)
                            if idPhotoColor == color {
                                Circle()
                                    .stroke(Color.accentColor, lineWidth: 2.5)
                                    .frame(width: 32, height: 32)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(color.rawValue)底色")
                    .accessibilityHint("切换为\(color.rawValue)底色")
                    .accessibilityAddTraits(idPhotoColor == color ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    func bgColor(_ option: BackgroundOption) -> Color {
        switch option {
        case .transparent: Color(.systemGray5)
        case .white: Color(.systemBackground)
        case .blue: .blue
        case .red: .red
        case .blur: Color(.systemGray3)
        case .idPhoto: .clear
        }
    }

    func checkerboardImage(size: CGSize) -> UIImage {
        let tile: CGFloat = 12
        let f = UIGraphicsImageRendererFormat(); f.scale = UIScreen.main.scale
        // 暗黑模式适配：棋盘格使用动态颜色
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

    // MARK: - Actions (单张)

    func loadImage(from item: PhotosPickerItem?) {
        guard let item else { return }
        isProcessing = true
        errorMessage = nil
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                await MainActor.run {
                    originalImage = image
                    resultImage = nil
                    errorMessage = nil
                    foregroundImage = nil
                    selectedBackground = .transparent
                    isBatchMode = false
                    // 保持 isProcessing = true，继续抠图
                }
                // 一键去背景：选图后自动抠图
                await runSegmentation(on: image)
            } else {
                await MainActor.run {
                    errorMessage = "无法加载图片，请重试"
                    isProcessing = false
                }
            }
        }
    }

    // MARK: - 批量抠图方法

    func loadBatchImages(_ items: [PhotosPickerItem]) {
        isProcessing = true
        errorMessage = nil
        Task {
            var images: [UIImage] = []
            var thumbs: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    images.append(image)
                    let maxDim: CGFloat = 200
                    let scale = min(maxDim / image.size.width, maxDim / image.size.height, 1)
                    let thumbSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    let fmt = UIGraphicsImageRendererFormat()
                    fmt.scale = 1
                    let thumb = UIGraphicsImageRenderer(size: thumbSize, format: fmt).image { _ in
                        image.draw(in: CGRect(origin: .zero, size: thumbSize))
                    }
                    thumbs.append(thumb)
                }
            }
            await MainActor.run {
                if images.isEmpty {
                    errorMessage = "无法加载所选图片"
                    isProcessing = false
                    return
                }
                batchImages = images
                batchThumbnails = thumbs
                batchResults = []
                batchIndex = 0
                batchTotal = images.count
                isBatchMode = true
                originalImage = nil
                resultImage = nil
                errorMessage = nil
                isProcessing = false
            }
        }
    }

    func startBatchProcessing() {
        guard !batchImages.isEmpty, !isProcessing else { return }
        isProcessing = true
        batchResults = []
        batchIndex = 0
        batchTotal = batchImages.count
        errorMessage = nil
        Task { @MainActor in
            processNextBatch()
        }
    }

    func processNextBatch() {
        guard batchIndex < batchTotal else {
            Task { @MainActor in
                isProcessing = false
                if batchResults.isEmpty {
                    errorMessage = "所有图片处理失败，请重试"
                } else if let first = batchResults.first {
                    resultImage = first
                    foregroundImage = first
                }
            }
            return
        }

        let image = batchImages[batchIndex]
        batchIndex += 1

        Task {
            do {
                let fg: UIImage
                if mattingMode == .person {
                    fg = try await MattingEngine.segmentPerson(in: image, feather: featherStrength)
                } else {
                    fg = try await MattingEngine.segmentObject(in: image, feather: featherStrength)
                }
                var safe = fg
                if safe.cgImage == nil {
                    let fmt = UIGraphicsImageRendererFormat()
                    fmt.scale = safe.scale
                    safe = UIGraphicsImageRenderer(size: safe.size, format: fmt).image { _ in
                        safe.draw(at: .zero)
                    }
                }
                await MainActor.run {
                    batchResults.append(safe)
                    processNextBatch()
                }
            } catch {
                await MainActor.run {
                    // 失败时保留原图作为占位，继续处理下一张
                    batchResults.append(image)
                    processNextBatch()
                }
            }
        }
    }

    func saveAllBatchResults() {
        for result in batchResults {
            UIImageWriteToSavedPhotosAlbum(result, nil, nil, nil)
        }
        saveMessage = "已保存 \(batchResults.count) 张图片到相册"
        showSaveAlert = true
    }

    func performSegmentation() {
        guard let image = originalImage else { return }
        isProcessing = true
        errorMessage = nil
        retryCount = 0

        Task {
            await runSegmentation(on: image)
        }
    }

    private func runSegmentation(on image: UIImage) async {
        do {
            let fg: UIImage
            if mattingMode == .person {
                fg = try await MattingEngine.segmentPerson(in: image)
            } else {
                fg = try await MattingEngine.segmentObject(in: image)
            }

            // 自动精修（默认轻度）
            let refined = MattingEngine.autoRefine(fg, original: image, feather: 1.0) ?? fg

            await MainActor.run {
                foregroundImage = refined
                resultImage = synthesizeResult(foreground: refined, background: selectedBackground)
                if let ri = resultImage, let data = ri.pngData(), let locked = UIImage(data: data) {
                    resultImage = locked
                }
                contourImage = generateContour(from: refined)
                isProcessing = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "抠图失败: \(error.localizedDescription)"
                isProcessing = false
            }
        }
    }

    /// 错误状态下重试
    func retrySegmentation() {
        guard let image = originalImage else { return }
        isProcessing = true
        errorMessage = nil
        retryCount += 1

        Task {
            await runSegmentation(on: image)
        }
    }

    func applyBackground(_ option: BackgroundOption) {
        guard let fg = foregroundImage else {
            // 没有前景图，需要先抠
            isProcessing = true
            errorMessage = nil
            Task {
                do {
                    let newFg: UIImage
                    if mattingMode == .person {
                        newFg = try await MattingEngine.segmentPerson(in: originalImage!)
                    } else {
                        newFg = try await MattingEngine.segmentObject(in: originalImage!)
                    }
                    await MainActor.run {
                        foregroundImage = newFg
                        isProcessing = false
                        resultImage = synthesizeResult(foreground: newFg, background: option)
                        contourImage = generateContour(from: newFg)
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = "抠图失败: \(error.localizedDescription)"
                        isProcessing = false
                    }
                }
            }
            return
        }

        resultImage = synthesizeResult(foreground: fg, background: option)
    }

    /// 用前景图 + 背景选项合成最终结果
    func synthesizeResult(foreground fg: UIImage, background option: BackgroundOption) -> UIImage? {
        guard let original = originalImage else { return nil }

        switch option {
        case .idPhoto:
            return IDPhotoEngine.generate(
                foreground: fg,
                size: idPhotoSize,
                bgColor: idPhotoColor,
                originalImage: original
            )
        default:
            // 透明背景：直接返回前景图（已带透明通道）
            if option == .transparent {
                // PNG 锁定，确保 alpha 不丢失
                if let data = fg.pngData(), let locked = UIImage(data: data) {
                    return locked
                }
                return fg
            }

            let bg: MattingEngine.BackgroundStyle = switch option {
            case .blur: .blur(radius: 10)
            default: .color(option.color)
            }
            // 以前景图尺寸为画布
            let size = fg.size
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = fg.scale
            fmt.opaque = false  // 保留透明通道
            let rendered = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
                switch bg {
                case .transparent: break
                case .color(let c): c.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                case .blur(let r):
                    if let blurred = MattingEngine.blur(original, radius: r) {
                        blurred.draw(in: CGRect(origin: .zero, size: size))
                    }
                case .image(let bgImg): bgImg.draw(in: CGRect(origin: .zero, size: size))
                }
                fg.draw(in: CGRect(origin: .zero, size: size))
            }
            // 保留原图方向
            if let cg = rendered.cgImage {
                return UIImage(cgImage: cg, scale: rendered.scale, orientation: original.imageOrientation)
            }
            return rendered
        }
    }

    func regenerateIDPhoto() {
        guard let fg = foregroundImage, let original = originalImage else { return }
        resultImage = IDPhotoEngine.generate(
            foreground: fg,
            size: idPhotoSize,
            bgColor: idPhotoColor,
            originalImage: original
        )
    }

    /// 羽化滑块变化时重新抠图（用新羽化强度）
    func reapplyFeather() {
        guard let image = originalImage else { return }
        isProcessing = true
        errorMessage = nil
        Task {
            do {
                let fg: UIImage
                if mattingMode == .person {
                    fg = try await MattingEngine.segmentPerson(in: image, feather: featherStrength)
                } else {
                    fg = try await MattingEngine.segmentObject(in: image, feather: featherStrength)
                }
                await MainActor.run {
                    foregroundImage = fg
                    resultImage = synthesizeResult(foreground: fg, background: selectedBackground)
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "抠图失败: \(error.localizedDescription)"
                    isProcessing = false
                }
            }
        }
    }

    func saveToAlbum() {
        guard let fg = foregroundImage else {
            saveMessage = "没有可保存的图片"
            showSaveAlert = true
            return
        }

        // 1. 裁剪人物到边界
        let trimmed = trimToContent(fg) ?? fg

        // 2. 如果人物太小，放大到合适尺寸（最短边至少 800px）
        let minTarget: CGFloat = 800
        let fgW = trimmed.size.width
        let fgH = trimmed.size.height
        let minDim = min(fgW, fgH)
        let scale = minDim < minTarget ? minTarget / minDim : 1.0
        let scaledW = fgW * scale
        let scaledH = fgH * scale

        // 3. 合成：透明背景 + 阴影 + 人物 + 轮廓线
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        let finalImage = UIGraphicsImageRenderer(size: CGSize(width: scaledW, height: scaledH), format: fmt).image { ctx in
            let cgCtx = ctx.cgContext
            let drawRect = CGRect(x: 0, y: 0, width: scaledW, height: scaledH)

            // 人物阴影
            cgCtx.saveGState()
            cgCtx.setShadow(offset: CGSize(width: 3, height: 5), blur: 12, color: UIColor.black.withAlphaComponent(0.3).cgColor)
            trimmed.draw(in: drawRect)
            cgCtx.restoreGState()

            // 人物本体
            trimmed.draw(in: drawRect)

            // 绿色轮廓线
            if showContour, let contour = contourImage {
                contour.draw(in: drawRect)
            }
        }

        guard let pngData = finalImage.pngData() else {
            saveMessage = "保存失败"
            showSaveAlert = true
            return
        }

        // 保存到相册
        UIImageWriteToSavedPhotosAlbum(finalImage, nil, nil, nil)

        // 同时保存到桌面
        let timestamp = Int(Date().timeIntervalSince1970)
        let desktopPath = "/Users/jiangbo/Desktop/SmartMatting_\(timestamp).png"
        try? pngData.write(to: URL(fileURLWithPath: desktopPath))

        saveMessage = "已保存到相册和桌面"
        showSaveAlert = true
    }

    /// 给人物加外发光 + 轮廓线，增强立体感
    func mergeContour(base: UIImage, contour: UIImage) -> UIImage? {
        let size = base.size
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = base.scale
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let cgCtx = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)

            // 1. 外发光层（白色，大模糊）——让人物边缘发光
            cgCtx.saveGState()
            cgCtx.setShadow(offset: .zero, blur: 20, color: UIColor.white.withAlphaComponent(0.6).cgColor)
            base.draw(in: rect)
            cgCtx.restoreGState()

            // 2. 投影（右下偏移）——增加深度
            cgCtx.saveGState()
            cgCtx.setShadow(offset: CGSize(width: 3, height: 5), blur: 10, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            base.draw(in: rect)
            cgCtx.restoreGState()

            // 3. 人物本体
            base.draw(in: rect)

            // 4. 绿色轮廓线
            contour.draw(in: rect)
        }
    }

    /// 裁剪图片到非透明区域的边界
    func trimToContent(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height

        // 读取 alpha 通道找边界
        guard let ctx = CGContext(data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h)

        var minX = w, maxX = 0, minY = h, maxY = 0
        for y in 0..<h {
            for x in 0..<w {
                if pixels[y * w + x] > 10 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard minX <= maxX, minY <= maxY else { return image }

        // 留一点边距（8px）
        let pad: CGFloat = 8
        let cropRect = CGRect(
            x: max(0, CGFloat(minX) - pad),
            y: max(0, CGFloat(minY) - pad),
            width: min(CGFloat(w) - CGFloat(minX) + pad, CGFloat(maxX - minX) + pad * 2),
            height: min(CGFloat(h) - CGFloat(minY) + pad, CGFloat(maxY - minY) + pad * 2)
        )

        guard let cropped = cg.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    func applyFilter() {
        guard let base = foregroundImage else { return }
        if selectedFilter == .none {
            resultImage = synthesizeResult(foreground: base, background: selectedBackground)
            filteredImage = nil
        } else if let filtered = selectedFilter.apply(to: base) {
            filteredImage = filtered
            resultImage = synthesizeResult(foreground: filtered, background: selectedBackground)
        }
    }

    func reset() {
        originalImage = nil
        resultImage = nil
        errorMessage = nil
        selectedItem = nil
        selectedBackground = .transparent
        foregroundImage = nil
        contourImage = nil
        MattingEngine.lastMaskImage = nil
        isProcessing = false
        retryCount = 0
    }

// MARK: - UIKit 分享桥接

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 滤镜

enum FilterOption: String, CaseIterable, Identifiable {
    case none = "原图"
    case mono = "黑白"
    case noir = " noir"
    case chrome = "铬黄"
    case fade = "褪色"
    case instant = "拍立得"
    case process = "冲印"
    case tonal = "色调"
    case transfer = "转印"
    case sepia = "复古"
    case vignette = "暗角"

    var id: String { rawValue }

    func apply(to image: UIImage) -> UIImage? {
        guard self != .none, let ciImage = CIImage(image: image) else { return nil }
        let name: String
        switch self {
        case .mono: name = "CIPhotoEffectMono"
        case .noir: name = "CIPhotoEffectNoir"
        case .chrome: name = "CIPhotoEffectChrome"
        case .fade: name = "CIPhotoEffectFade"
        case .instant: name = "CIPhotoEffectInstant"
        case .process: name = "CIPhotoEffectProcess"
        case .tonal: name = "CIPhotoEffectTonal"
        case .transfer: name = "CIPhotoEffectTransfer"
        case .sepia: name = "CISepiaTone"
        case .vignette:
            guard let f = CIFilter(name: "CIVignette", parameters: [
                kCIInputImageKey: ciImage,
                kCIInputIntensityKey: 0.8,
                kCIInputRadiusKey: ciImage.extent.width * 0.7
            ]), let out = f.outputImage else { return nil }
            return renderFilterOutput(out)
        default: return nil
        }
        guard let f = CIFilter(name: name, parameters: [kCIInputImageKey: ciImage]),
              let out = f.outputImage else { return nil }
        return renderFilterOutput(out)
    }

    private func renderFilterOutput(_ ci: CIImage) -> UIImage? {
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

    // MARK: - 轮廓线生成

    /// 从前景图（带 alpha）提取轮廓线
    func generateContour(from foreground: UIImage) -> UIImage? {
        guard let cg = foreground.cgImage else { return nil }
        let w = cg.width, h = cg.height

        // 1. 提取 alpha 通道
        guard let maskCtx = CGContext(data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        maskCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let maskCG = maskCtx.makeImage() else { return nil }

        // 2. 用 CIImage 做大半径形态学处理，把内部空洞全部填平
        var maskCI = CIImage(cgImage: maskCG)
        if let binarized = MattingEngine.binarizeMask(maskCI) { maskCI = binarized }
        // 大幅膨胀把内部全填实
        if let d1 = MattingEngine.morph(maskCI, r: 15.0, dilate: true) { maskCI = d1 }
        // 再腐蚀回来
        if let e1 = MattingEngine.morph(maskCI, r: 15.0, dilate: false) { maskCI = e1 }
        if let binarized = MattingEngine.binarizeMask(maskCI) { maskCI = binarized }

        // 渲染处理后的遮罩
        guard let cleanMaskCG = CIContext().createCGImage(maskCI, from: maskCI.extent) else { return nil }
        guard let cleanCtx = CGContext(data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        cleanCtx.draw(cleanMaskCG, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let cleanData = cleanCtx.data else { return nil }
        let cleanPixels = cleanData.bindMemory(to: UInt8.self, capacity: w * h)

        // 3. 边缘检测
        var edgePixels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let idx = y * w + x
                if cleanPixels[idx] < 128 { continue }
                var isEdge = false
                for dy in -1...1 {
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { isEdge = true; break }
                        if cleanPixels[ny * w + nx] < 128 { isEdge = true; break }
                    }
                    if isEdge { break }
                }
                edgePixels[idx] = isEdge ? 255 : 0
            }
        }

        // 4. 渲染彩色轮廓线
        let lineWidth = max(2.5, CGFloat(max(w, h)) / 250)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = foreground.scale
        return UIGraphicsImageRenderer(size: foreground.size, format: fmt).image { ctx in
            let cgCtx = ctx.cgContext
            cgCtx.setStrokeColor(UIColor(red: 0.2, green: 0.9, blue: 0.2, alpha: 0.85).cgColor)
            cgCtx.setLineWidth(lineWidth)
            cgCtx.setLineCap(.round)
            cgCtx.setLineJoin(.round)

            // 画水平线段
            for y in 0..<h {
                var runStart: Int?
                for x in 0..<w {
                    if edgePixels[y * w + x] > 128 {
                        if runStart == nil { runStart = x }
                    } else {
                        if let start = runStart, x - start > 0 {
                            cgCtx.move(to: CGPoint(x: start, y: y))
                            cgCtx.addLine(to: CGPoint(x: x - 1, y: y))
                            cgCtx.strokePath()
                            runStart = nil
                        } else { runStart = nil }
                    }
                }
                if let start = runStart, w - start > 0 {
                    cgCtx.move(to: CGPoint(x: start, y: y))
                    cgCtx.addLine(to: CGPoint(x: w - 1, y: y))
                    cgCtx.strokePath()
                }
            }

            // 画竖直线段
            for x in 0..<w {
                var runStart: Int?
                for y in 0..<h {
                    if edgePixels[y * w + x] > 128 {
                        if runStart == nil { runStart = y }
                    } else {
                        if let start = runStart, y - start > 0 {
                            cgCtx.move(to: CGPoint(x: x, y: start))
                            cgCtx.addLine(to: CGPoint(x: x, y: y - 1))
                            cgCtx.strokePath()
                            runStart = nil
                        } else { runStart = nil }
                    }
                }
                if let start = runStart, h - start > 0 {
                    cgCtx.move(to: CGPoint(x: x, y: start))
                    cgCtx.addLine(to: CGPoint(x: x, y: h - 1))
                    cgCtx.strokePath()
                }
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
