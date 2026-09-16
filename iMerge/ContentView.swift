import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    /// Gestures measure against this fixed space, otherwise a dragged image's own
    /// moving coordinate space feeds back into the translation and it jitters.
    fileprivate static let canvasSpace = "iMergeCanvas"

    @State private var items: [ImageItem] = []
    @State private var selection: Set<UUID> = []
    @State private var gestureStart: [UUID: CGRect] = [:]
    @State private var guideX: [CGFloat] = []
    @State private var guideY: [CGFloat] = []
    @State private var transparentBackground = false
    @State private var status: String?
    @State private var isTargeted = false
    @State private var canvasSize: CGSize = .zero

    // Viewport panning. Item frames stay untouched, so the export is unaffected.
    @State private var panOffset: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var isSpaceHeld = false

    @State private var pointer: CGPoint?
    @State private var eventMonitors: [Any] = []

    // Sketch layer.
    @State private var annotations: [Annotation] = []
    @State private var annotationStart: [UUID: Annotation] = [:]
    @State private var draft: Annotation?
    @State private var tool: AnnotationTool = .select
    @State private var inkColor: Color = .red
    @State private var inkWidth: Double = 4

    private var exportBounds: CGRect { ImageMerger.bounds(of: items, annotations: annotations) }

    private var isCanvasEmpty: Bool { items.isEmpty && annotations.isEmpty }

    var body: some View {
        GeometryReader { proxy in
            canvas
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .onAppear { canvasSize = proxy.size }
                .onChange(of: proxy.size) { _, newValue in canvasSize = newValue }
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("iMerge")
        .toolbar { toolbarContent }
        .onDeleteCommand(perform: deleteSelected)
        .onAppear(perform: startEventMonitors)
        .onDisappear(perform: stopEventMonitors)
        .onChange(of: isSpaceHeld) { _, held in
            if held { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .onChange(of: inkColor) { _, _ in applyInkToSelection() }
        .onChange(of: inkWidth) { _, _ in applyInkToSelection() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if isSpaceHeld { isSpaceHeld = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAllElements)) { _ in selectAll() }
        .onReceive(NotificationCenter.default.publisher(for: .pasteImages)) { _ in pasteImages() }
        .onReceive(NotificationCenter.default.publisher(for: .copyMerged)) { _ in copyMerged() }
        .onReceive(NotificationCenter.default.publisher(for: .exportMerged)) { _ in exportMerged() }
        .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted) { providers in
            Task { @MainActor in
                add(images: await ImageMerger.imagesFromDroppedProviders(providers))
            }
            return true
        }
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            canvasBackground
                .zIndex(-1)

            content
                .offset(panOffset)
                .zIndex(0)

            crosshair
                .zIndex(1)

            // A drawing tool takes over the canvas so drags create ink instead of moving images.
            if tool.isDrawing && !isSpaceHeld {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(drawGesture)
                    .zIndex(2)
            }

            // While Space is held this layer swallows drags so panning wins over everything else.
            if isSpaceHeld {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .zIndex(3)
            }
        }
        .coordinateSpace(.named(Self.canvasSpace))
        .onContinuousHover(coordinateSpace: .named(Self.canvasSpace)) { phase in
            switch phase {
            case .active(let location):
                pointer = location
                // Re-set on every move so the cursor stays put without unbalanced push/pop.
                if !isSpaceHeld {
                    (tool.isDrawing ? NSCursor.crosshair : NSCursor.arrow).set()
                }
            case .ended:
                pointer = nil
            }
        }
        .overlay(alignment: .center) { emptyState }
        .overlay(alignment: .bottom) { statusBar }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            ForEach($items) { $item in
                CanvasItemView(
                    item: $item,
                    isSelected: selection.contains(item.id),
                    showsHandles: selection.count == 1 && selection.contains(item.id),
                    coordinateSpace: Self.canvasSpace,
                    onSelect: { select(item.id) },
                    onMove: { translation in move(id: item.id, translation: translation) },
                    onResize: { corner, translation in resize(id: item.id, corner: corner, translation: translation) },
                    onGestureEnd: endGesture,
                    onActualSize: { resetToActualSize(id: item.id) },
                    onDelete: { remove(id: item.id) }
                )
                .offset(x: item.frame.minX, y: item.frame.minY)
                .zIndex(item.z)
            }

            ForEach(annotations) { annotation in
                AnnotationView(
                    annotation: annotation,
                    isSelected: selection.contains(annotation.id),
                    showsHandles: selection.count == 1 && selection.contains(annotation.id),
                    coordinateSpace: Self.canvasSpace,
                    isInteractive: tool == .select && !isSpaceHeld,
                    onSelect: { select(annotation.id) },
                    onMove: { translation in move(id: annotation.id, translation: translation) },
                    onMoveEndpoint: { endpoint, translation in
                        moveArrowEndpoint(id: annotation.id, endpoint: endpoint, translation: translation)
                    },
                    onGestureEnd: endGesture,
                    onDelete: { removeAnnotation(id: annotation.id) }
                )
                .zIndex(1_000_000 + annotation.z)
            }

            if let draft {
                AnnotationView(
                    annotation: draft,
                    isSelected: false,
                    showsHandles: false,
                    coordinateSpace: Self.canvasSpace,
                    isInteractive: false,
                    onSelect: {},
                    onMove: { _ in },
                    onMoveEndpoint: { _, _ in },
                    onGestureEnd: {},
                    onDelete: {}
                )
                .zIndex(1_500_000)
            }

            if !isCanvasEmpty {
                exportOutline
                    .zIndex(2_000_000)
            }

            alignmentGuides
                .zIndex(2_000_001)
        }
    }

    /// One background for the whole window, and it is exactly the exported background.
    private var canvasBackground: some View {
        Group {
            if transparentBackground {
                Checkerboard()
            } else {
                Color.white
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = [] }
        .gesture(panGesture)
    }

    /// Neutral on purpose: the accent color is reserved for selection, so the two never compete.
    private var exportOutline: some View {
        Rectangle()
            .strokeBorder(Color.black.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .frame(width: exportBounds.width, height: exportBounds.height)
            .offset(x: exportBounds.minX, y: exportBounds.minY)
            .allowsHitTesting(false)
    }

    private var alignmentGuides: some View {
        ZStack(alignment: .topLeading) {
            ForEach(guideX, id: \.self) { x in
                Rectangle()
                    .fill(Color.pink.opacity(0.8))
                    .frame(width: 1, height: canvasSize.height * 3)
                    .offset(x: x, y: -canvasSize.height)
            }
            ForEach(guideY, id: \.self) { y in
                Rectangle()
                    .fill(Color.pink.opacity(0.8))
                    .frame(width: canvasSize.width * 3, height: 1)
                    .offset(x: -canvasSize.width, y: y)
            }
        }
        .allowsHitTesting(false)
    }

    /// Thin lines tracking the pointer, like the crosshair in Preview's selection tool.
    @ViewBuilder
    private var crosshair: some View {
        if let pointer, !isSpaceHeld, !isCanvasEmpty {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.black.opacity(0.13))
                    .frame(width: 1, height: canvasSize.height)
                    .offset(x: pointer.x.rounded())
                Rectangle()
                    .fill(Color.black.opacity(0.13))
                    .frame(width: canvasSize.width, height: 1)
                    .offset(y: pointer.y.rounded())
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 34, weight: .ultraLight))
                    .foregroundStyle(Color.black.opacity(0.18))
                Text("Paste or drop images")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.6))
                VStack(spacing: 3) {
                    Text("Drag to move · corner to resize")
                    Text("Space to pan · ⌘A select all · ⌫ delete")
                }
                .font(.caption)
                .foregroundStyle(Color.black.opacity(0.34))
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        let readouts = readouts
        if !readouts.isEmpty {
            Text(readouts.joined(separator: "   ·   "))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.black.opacity(0.62))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background {
                    Capsule()
                        .fill(.white)
                        .overlay(Capsule().strokeBorder(Color.black.opacity(0.07)))
                        .shadow(color: .black.opacity(0.10), radius: 5, y: 1)
                }
                .padding(.bottom, 18)
                .allowsHitTesting(false)
        }
    }

    private var readouts: [String] {
        var parts: [String] = []

        if let status {
            parts.append(status)
        }
        if isSpaceHeld {
            parts.append("Panning")
        }
        if let pointer {
            // Report canvas coordinates, so panning doesn't change an image's reported position.
            let x = Int((pointer.x - panOffset.width).rounded())
            let y = Int((pointer.y - panOffset.height).rounded())
            parts.append("x \(x)  y \(y)")
        }
        if selection.count > 1 {
            parts.append("\(selection.count) selected")
        } else if let id = selection.first, let item = items.first(where: { $0.id == id }) {
            parts.append("selected \(Int(item.frame.width)) × \(Int(item.frame.height)) pt")
        }
        if !isCanvasEmpty {
            let size = ImageMerger.exportPixelSize(for: items, annotations: annotations)
            parts.append("export \(Int(size.width)) × \(Int(size.height)) px")
        }

        return parts
    }

    private var isEditingInk: Bool {
        tool.isDrawing || annotations.contains { selection.contains($0.id) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Mode and its attributes sit centered; the title stays at the far left.
        ToolbarItemGroup(placement: .principal) {
            Picker("Tool", selection: $tool) {
                ForEach(AnnotationTool.allCases) { option in
                    Image(systemName: option.symbol)
                        .help(option.title)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Select, Arrow, Cursor marker, Sketch — Esc returns to Select")

            // Ink attributes only appear when they can actually do something.
            if isEditingInk {
                ColorPicker("Ink color", selection: $inkColor, supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .help("Annotation color")

                Menu {
                    Picker("Thickness", selection: $inkWidth) {
                        Text("Thin").tag(2.0)
                        Text("Medium").tag(4.0)
                        Text("Thick").tag(7.0)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Thickness", systemImage: "lineweight")
                }
                .help("Annotation thickness")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // Canvas actions read as one unit, separate from the output actions.
            ControlGroup {
                Button {
                    pasteImages()
                } label: {
                    Label("Paste", systemImage: "clipboard")
                }
                .help("Paste images from the clipboard (⌘V)")

                Button {
                    fitToView()
                } label: {
                    Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Scale everything to fit the window and recenter")
                .disabled(isCanvasEmpty)

                Button {
                    transparentBackground.toggle()
                } label: {
                    Label(
                        transparentBackground ? "Transparent background" : "White background",
                        systemImage: transparentBackground ? "square.grid.3x3" : "circle.lefthalf.filled"
                    )
                }
                .help("Toggle background between white and transparent")
                .disabled(isCanvasEmpty)
            }

            Button {
                copyMerged()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy the merged image (⇧⌘C)")
            .disabled(isCanvasEmpty)

            // The goal action carries a text label so it reads as primary.
            Button {
                exportMerged()
            } label: {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .labelStyle(.titleAndIcon)
            .help("Save the merged image as PNG (⌘E)")
            .disabled(isCanvasEmpty)
        }
    }

    // MARK: - Sketching

    /// View point to canvas point: undo the pan so ink lands where the images actually are.
    private func canvasPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - panOffset.width, y: point.y - panOffset.height)
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                let start = canvasPoint(value.startLocation)
                let current = canvasPoint(value.location)

                switch tool {
                case .select:
                    break
                case .arrow:
                    draft = makeDraft(.arrow(start: start, end: current))
                case .pointer:
                    draft = makeDraft(.pointer(tip: current))
                case .pen:
                    if case let .pen(points)? = draft?.kind {
                        // Skip samples that are too close together to matter.
                        if let last = points.last, hypot(current.x - last.x, current.y - last.y) < 1.5 {
                            return
                        }
                        draft?.kind = .pen(points: points + [current])
                    } else {
                        draft = makeDraft(.pen(points: [start]))
                    }
                }
            }
            .onEnded { _ in commitDraft() }
    }

    private func makeDraft(_ kind: AnnotationKind) -> Annotation {
        Annotation(
            kind: kind,
            color: NSColor(inkColor),
            lineWidth: inkWidth,
            z: (annotations.map(\.z).max() ?? 0) + 1
        )
    }

    private func commitDraft() {
        defer { draft = nil }
        guard let draft else { return }

        // Ignore a stray click that produced no real geometry.
        if case let .arrow(start, end) = draft.kind,
           hypot(end.x - start.x, end.y - start.y) < 6 {
            return
        }

        annotations.append(draft)
        selection = [draft.id]
    }

    private func moveArrowEndpoint(id: UUID, endpoint: ArrowEndpoint, translation: CGSize) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        if annotationStart[id] == nil {
            annotationStart[id] = annotations[index]
            selection = [id]
        }
        guard let start = annotationStart[id] else { return }
        annotations[index] = start.movingEndpoint(endpoint, by: translation)
    }

    private func removeAnnotation(id: UUID) {
        annotations.removeAll { $0.id == id }
        selection.remove(id)
    }

    /// Keeps the toolbar controls acting on whatever is selected.
    private func applyInkToSelection() {
        for index in annotations.indices where selection.contains(annotations[index].id) {
            annotations[index].color = NSColor(inkColor)
            annotations[index].lineWidth = inkWidth
        }
    }

    // MARK: - Panning

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                if panStart == nil {
                    panStart = panOffset
                    NSCursor.closedHand.set()
                }
                let base = panStart ?? .zero
                panOffset = CGSize(
                    width: base.width + (value.location.x - value.startLocation.x),
                    height: base.height + (value.location.y - value.startLocation.y)
                )
            }
            .onEnded { _ in
                panStart = nil
                if isSpaceHeld { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
            }
    }

    // MARK: - Keyboard & scroll

    /// A scoped local monitor: Space and ⌫ never reach text fields or modal sheets,
    /// so the Export dialog keeps working normally.
    private func startEventMonitors() {
        guard eventMonitors.isEmpty else { return }

        let keyDown = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard shouldHandleEvent(event) else { return event }

            switch event.keyCode {
            case 49: // space
                if !event.isARepeat { isSpaceHeld = true }
                return nil
            case 51, 117: // delete, forward delete
                guard !selection.isEmpty else { return event }
                deleteSelected()
                return nil
            case 53: // escape
                tool = .select
                selection = []
                return nil
            default:
                return event
            }
        }

        let keyUp = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            guard event.keyCode == 49 else { return event }
            isSpaceHeld = false
            return nil
        }

        let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard shouldHandleEvent(event), !isCanvasEmpty else { return event }
            panOffset.width += event.scrollingDeltaX
            panOffset.height += event.scrollingDeltaY
            return nil
        }

        eventMonitors = [keyDown, keyUp, scroll].compactMap { $0 }
    }

    private func stopEventMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors = []
    }

    private func shouldHandleEvent(_ event: NSEvent) -> Bool {
        guard NSApp.modalWindow == nil else { return false }
        guard let window = event.window, window == NSApp.keyWindow else { return false }
        guard !(window.firstResponder is NSTextView) else { return false }
        return true
    }

    // MARK: - Selection

    /// Shift or Command click extends the selection, a plain click replaces it.
    private func select(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) || flags.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
        } else {
            selection = [id]
        }
        bringToFront(id)
    }

    private func bringToFront(_ id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            let topZ = items.map(\.z).max() ?? 0
            if items[index].z < topZ { items[index].z = topZ + 1 }
        } else if let index = annotations.firstIndex(where: { $0.id == id }) {
            let topZ = annotations.map(\.z).max() ?? 0
            if annotations[index].z < topZ { annotations[index].z = topZ + 1 }
        }
    }

    private func selectAll() {
        selection = Set(items.map(\.id)).union(annotations.map(\.id))
        guard !selection.isEmpty else { return }
        flash(selection.count == 1 ? "1 element selected." : "\(selection.count) elements selected.")
    }

    // MARK: - Editing

    /// Captures the starting geometry of everything that should travel with this drag.
    private func beginDrag(anchor id: UUID) {
        guard gestureStart.isEmpty, annotationStart.isEmpty else { return }

        if !selection.contains(id) {
            selection = [id]
            bringToFront(id)
        }
        for item in items where selection.contains(item.id) {
            gestureStart[item.id] = item.frame
        }
        for annotation in annotations where selection.contains(annotation.id) {
            annotationStart[annotation.id] = annotation
        }
    }

    /// Moves every selected element together; snapping applies only to a lone image.
    private func move(id: UUID, translation: CGSize) {
        beginDrag(anchor: id)

        let isGroup = gestureStart.count + annotationStart.count > 1
        if !isGroup,
           let index = items.firstIndex(where: { $0.id == id }),
           let start = gestureStart[id] {
            let moved = CGRect(
                x: start.minX + translation.width,
                y: start.minY + translation.height,
                width: start.width,
                height: start.height
            )
            let others = items.filter { $0.id != id }.map(\.frame)
            let snapped = Snapper.snap(frame: moved, against: others)

            // Whole-point origins keep edges crisp and stop sub-pixel shimmer while dragging.
            items[index].frame.origin = CGPoint(x: snapped.origin.x.rounded(), y: snapped.origin.y.rounded())
            guideX = snapped.guideX
            guideY = snapped.guideY
            return
        }

        let delta = CGSize(width: translation.width.rounded(), height: translation.height.rounded())
        for index in items.indices {
            guard let start = gestureStart[items[index].id] else { continue }
            items[index].frame.origin = CGPoint(x: start.minX + delta.width, y: start.minY + delta.height)
        }
        for index in annotations.indices {
            guard let start = annotationStart[annotations[index].id] else { continue }
            annotations[index] = start.translated(by: delta)
        }
        guideX = []
        guideY = []
    }

    private func resize(id: UUID, corner: ResizeCorner, translation: CGSize) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if gestureStart[id] == nil {
            gestureStart[id] = items[index].frame
            selection = [id]
        }
        guard let start = gestureStart[id] else { return }

        items[index].frame = Snapper.resize(
            start: start,
            corner: corner,
            translation: translation,
            aspectRatio: items[index].aspectRatio
        )
    }

    private func endGesture() {
        gestureStart.removeAll()
        annotationStart.removeAll()
        guideX = []
        guideY = []
    }

    private func resetToActualSize(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let native = items[index].nativeSize
        items[index].frame.size = native
        flash("Actual size: \(Int(native.width)) × \(Int(native.height))")
    }

    private func remove(id: UUID) {
        items.removeAll { $0.id == id }
        selection.remove(id)
    }

    private func deleteSelected() {
        guard !selection.isEmpty else { return }

        let imageCount = items.filter { selection.contains($0.id) }.count
        let annotationCount = annotations.filter { selection.contains($0.id) }.count
        items.removeAll { selection.contains($0.id) }
        annotations.removeAll { selection.contains($0.id) }
        selection = []

        let total = imageCount + annotationCount
        switch (imageCount, annotationCount) {
        case (_, 0): flash(total == 1 ? "Deleted image." : "Deleted \(total) images.")
        case (0, _): flash(total == 1 ? "Deleted annotation." : "Deleted \(total) annotations.")
        default: flash("Deleted \(total) elements.")
        }
    }

    // MARK: - Adding images

    private func pasteImages() {
        let images = ImageMerger.imagesFromPasteboard()
        guard !images.isEmpty else {
            flash("Clipboard has no images.")
            return
        }
        add(images: images)
    }

    private func add(images: [NSImage]) {
        guard !images.isEmpty else { return }
        let viewport = canvasSize == .zero ? CGSize(width: 900, height: 600) : canvasSize

        for image in images {
            let native = image.size
            guard native.width > 0, native.height > 0 else { continue }

            // Shrink oversized pastes so the whole image is visible right away.
            let fit = min(1, min(viewport.width * 0.7 / native.width, viewport.height * 0.7 / native.height))
            let size = CGSize(width: native.width * fit, height: native.height * fit)

            let origin: CGPoint
            if items.isEmpty {
                // Place into the visible area, accounting for any panning.
                origin = CGPoint(
                    x: -panOffset.width + max((viewport.width - size.width) / 2, 20),
                    y: -panOffset.height + 24
                )
            } else {
                let bounds = ImageMerger.bounds(of: items)
                origin = CGPoint(x: bounds.minX, y: bounds.maxY)
            }

            let topZ = items.map(\.z).max() ?? 0
            let item = ImageItem(image: image, frame: CGRect(origin: origin, size: size), z: topZ + 1)
            items.append(item)
            selection = [item.id]
        }

        flash(images.count == 1 ? "Added 1 image." : "Added \(images.count) images.")
    }

    // MARK: - Canvas helpers

    /// Uniformly scales and recenters everything: layout is preserved, so the export looks identical.
    private func fitToView() {
        guard !items.isEmpty, canvasSize != .zero else { return }
        let bounds = exportBounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let inset: CGFloat = 48
        let available = CGSize(
            width: max(canvasSize.width - inset * 2, 100),
            height: max(canvasSize.height - inset * 2, 100)
        )
        let scale = min(available.width / bounds.width, available.height / bounds.height)
        let newSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let offset = CGPoint(
            x: (canvasSize.width - newSize.width) / 2,
            y: (canvasSize.height - newSize.height) / 2
        )

        for index in items.indices {
            let frame = items[index].frame
            items[index].frame = CGRect(
                x: offset.x + (frame.minX - bounds.minX) * scale,
                y: offset.y + (frame.minY - bounds.minY) * scale,
                width: frame.width * scale,
                height: frame.height * scale
            )
        }

        // Annotations follow the same transform, otherwise they'd drift off their targets.
        let map: (CGPoint) -> CGPoint = { point in
            CGPoint(
                x: offset.x + (point.x - bounds.minX) * scale,
                y: offset.y + (point.y - bounds.minY) * scale
            )
        }
        for index in annotations.indices {
            annotations[index] = annotations[index].mapped(map, widthScale: scale)
        }

        panOffset = .zero
    }

    // MARK: - Output

    private var mergedImage: NSImage? {
        ImageMerger.merge(
            items: items,
            annotations: annotations,
            backgroundColor: transparentBackground ? nil : .white
        )
    }

    private func copyMerged() {
        guard let mergedImage else { return }
        ImageMerger.copyToPasteboard(mergedImage)
        flash("Copied merged image.")
    }

    private func exportMerged() {
        guard let mergedImage, let data = ImageMerger.pngData(from: mergedImage) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "merged.png"
        panel.canCreateDirectories = true
        panel.title = "Export Merged Image"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                flash("Exported to \(url.lastPathComponent).")
            } catch {
                flash("Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func flash(_ message: String) {
        withAnimation { status = message }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if status == message {
                withAnimation { status = nil }
            }
        }
    }
}

private struct CanvasItemView: View {
    @Binding var item: ImageItem
    let isSelected: Bool
    let showsHandles: Bool
    let coordinateSpace: String
    let onSelect: () -> Void
    let onMove: (CGSize) -> Void
    let onResize: (ResizeCorner, CGSize) -> Void
    let onGestureEnd: () -> Void
    let onActualSize: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Image(nsImage: item.image)
            .resizable()
            .interpolation(.high)
            .frame(width: item.frame.width, height: item.frame.height)
            .overlay {
                if isSelected {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .overlay { if showsHandles { handles } }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace))
                    .onChanged { onMove(translation(of: $0)) }
                    .onEnded { _ in onGestureEnd() }
            )
            .transaction { $0.animation = nil }
            .contextMenu {
                Button("Actual Size", action: onActualSize)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            }
            .help("\(Int(item.frame.width)) × \(Int(item.frame.height)) pt")
    }

    private func translation(of value: DragGesture.Value) -> CGSize {
        CGSize(
            width: value.location.x - value.startLocation.x,
            height: value.location.y - value.startLocation.y
        )
    }

    private var handles: some View {
        ZStack {
            handle(.topLeading, alignment: .topLeading)
            handle(.topTrailing, alignment: .topTrailing)
            handle(.bottomLeading, alignment: .bottomLeading)
            handle(.bottomTrailing, alignment: .bottomTrailing)
        }
    }

    private func handle(_ corner: ResizeCorner, alignment: Alignment) -> some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.accentColor, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
            .frame(width: 10, height: 10)
            .contentShape(Rectangle().inset(by: -6))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
                    .onChanged { onResize(corner, translation(of: $0)) }
                    .onEnded { _ in onGestureEnd() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

private struct AnnotationView: View {
    let annotation: Annotation
    let isSelected: Bool
    let showsHandles: Bool
    let coordinateSpace: String
    let isInteractive: Bool
    let onSelect: () -> Void
    let onMove: (CGSize) -> Void
    let onMoveEndpoint: (ArrowEndpoint, CGSize) -> Void
    let onGestureEnd: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let bounds = annotation.bounds
        let origin = CGPoint(x: -bounds.minX, y: -bounds.minY)

        Canvas { context, _ in
            for op in annotation.drawOps {
                guard let path = translated(op.path, by: origin) else { continue }
                let shape = Path(path)
                let color = Color(nsColor: op.color)
                if op.isFill {
                    context.fill(shape, with: .color(color))
                } else {
                    context.stroke(
                        shape,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: op.lineWidth, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
        .frame(width: bounds.width, height: bounds.height)
        .overlay {
            if isSelected {
                Rectangle()
                    .strokeBorder(
                        Color.accentColor.opacity(0.9),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
        }
        .overlay { if showsHandles, isInteractive { arrowHandles(origin: origin) } }
        // Only the ink is clickable, so clicks elsewhere still reach the images below.
        .contentShape(InkShape(path: annotation.hitPath, offset: origin, padding: 16))
        .onTapGesture(perform: onSelect)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace))
                .onChanged { onMove(translation(of: $0)) }
                .onEnded { _ in onGestureEnd() }
        )
        .transaction { $0.animation = nil }
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
        .allowsHitTesting(isInteractive)
        .offset(x: bounds.minX, y: bounds.minY)
    }

    @ViewBuilder
    private func arrowHandles(origin: CGPoint) -> some View {
        if let endpoints = annotation.arrowEndpoints {
            ZStack(alignment: .topLeading) {
                endpointHandle(.start, at: endpoints.start, origin: origin)
                endpointHandle(.end, at: endpoints.end, origin: origin)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func endpointHandle(_ endpoint: ArrowEndpoint, at point: CGPoint, origin: CGPoint) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
            .frame(width: 11, height: 11)
            .contentShape(Circle().inset(by: -6))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
                    .onChanged { onMoveEndpoint(endpoint, translation(of: $0)) }
                    .onEnded { _ in onGestureEnd() }
            )
            .offset(x: point.x + origin.x - 5.5, y: point.y + origin.y - 5.5)
    }

    private func translation(of value: DragGesture.Value) -> CGSize {
        CGSize(
            width: value.location.x - value.startLocation.x,
            height: value.location.y - value.startLocation.y
        )
    }

    private func translated(_ path: CGPath, by offset: CGPoint) -> CGPath? {
        var transform = CGAffineTransform(translationX: offset.x, y: offset.y)
        return path.copy(using: &transform)
    }
}

/// Hit area that follows the ink: the stroked outline plus the filled shape.
private struct InkShape: Shape {
    let path: CGPath
    let offset: CGPoint
    let padding: CGFloat

    func path(in rect: CGRect) -> Path {
        var transform = CGAffineTransform(translationX: offset.x, y: offset.y)
        guard let moved = path.copy(using: &transform) else { return Path() }
        var result = Path(moved)
        result.addPath(
            Path(moved).strokedPath(StrokeStyle(lineWidth: padding, lineCap: .round, lineJoin: .round))
        )
        return result
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let cell: CGFloat = 10
            for y in stride(from: 0, to: size.height, by: cell) {
                for x in stride(from: 0, to: size.width, by: cell) {
                    if (Int(x / cell) + Int(y / cell)).isMultiple(of: 2) {
                        context.fill(
                            Path(CGRect(x: x, y: y, width: cell, height: cell)),
                            with: .color(Color.gray.opacity(0.22))
                        )
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 960, height: 640)
}
