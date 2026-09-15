//
//  MenuBarOverlayPanel.swift
//  Ice
//

import AXSwift
import Cocoa
import Combine
import QuartzCore

// MARK: - Overlay Panel

/// A subclass of `NSPanel` that sits atop the menu bar to alter its appearance.
final class MenuBarOverlayPanel: NSPanel {
    /// Flags representing the updatable components of a panel.
    enum UpdateFlag: String, CustomStringConvertible {
        case applicationMenuFrame

        var description: String { rawValue }
    }

    /// The kind of validation that occurs before an update.
    private enum ValidationKind {
        case showing
        case updates
    }

    /// A context that manages panel update tasks.
    private final class UpdateTaskContext {
        private var tasks = [UpdateFlag: Task<Void, any Error>]()

        /// Sets the task for the given update flag.
        ///
        /// Setting the task cancels the previous task for the flag, if there is one.
        ///
        /// - Parameters:
        ///   - flag: The update flag to set the task for.
        ///   - timeout: The timeout of the task.
        ///   - operation: The operation for the task to perform.
        func setTask(for flag: UpdateFlag, timeout: Duration, operation: @escaping () async throws -> Void) {
            cancelTask(for: flag)
            tasks[flag] = Task.detached(timeout: timeout) {
                try await operation()
            }
        }

        /// Cancels the task for the given update flag.
        ///
        /// - Parameter flag: The update flag to cancel the task for.
        func cancelTask(for flag: UpdateFlag) {
            tasks.removeValue(forKey: flag)?.cancel()
        }
    }

    /// A Boolean value that indicates whether the panel needs to be shown.
    @Published var needsShow = false

    /// A Boolean value that indicates whether the user is dragging a menu bar item.
    @Published var isDraggingMenuBarItem = false

    /// Flags representing the components of the panel currently in need of an update.
    @Published private(set) var updateFlags = Set<UpdateFlag>()

    /// The frame of the application menu.
    @Published private(set) var applicationMenuFrame: CGRect?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The context that manages panel update tasks.
    private let updateTaskContext = UpdateTaskContext()

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// The screen that owns the panel.
    let owningScreen: NSScreen

    /// Creates an overlay panel with the given app state and owning screen.
    init(appState: AppState, owningScreen: NSScreen) {
        self.appState = appState
        self.owningScreen = owningScreen
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Level 24 (same as the menu bar background): the tint is fully
        // opaque, so the panel must never sit above the status-item windows
        // (level 25) or it would cover the menu bar icons. show() orders it
        // just above the menu bar background window instead.
        self.level = .mainMenu
        self.title = "Menu Bar Overlay"
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.fullScreenNone, .ignoresCycle, .moveToActiveSpace]
        self.contentView = MenuBarOverlayPanelContentView()
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        // Show the panel on the active space.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .debounce(for: 0.1, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.needsShow = true
            }
            .store(in: &c)

        // Redraw with the correct light/dark tint when the system
        // appearance changes. The stored configuration holds both variants,
        // so no publisher fires for the switch — trigger a redraw directly.
        DistributedNotificationCenter.default()
            .publisher(for: DistributedNotificationCenter.interfaceThemeChangedNotification)
            .debounce(for: 0.1, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.contentView?.needsDisplay = true
            }
            .store(in: &c)

        // Update application menu frame when the menu bar owning or frontmost app changes.
        Publishers.Merge(
            NSWorkspace.shared.publisher(for: \.menuBarOwningApplication, options: .old)
                .combineLatest(NSWorkspace.shared.publisher(for: \.menuBarOwningApplication, options: .new))
                .compactMap { $0 == $1 ? nil : $0 },
            NSWorkspace.shared.publisher(for: \.frontmostApplication, options: .old)
                .combineLatest(NSWorkspace.shared.publisher(for: \.frontmostApplication, options: .new))
                .compactMap { $0 == $1 ? nil : $0 }
        )
        .removeDuplicates()
        .sink { [weak self] _ in
            guard
                let self,
                let appState
            else {
                return
            }
            let displayID = owningScreen.displayID
            updateTaskContext.setTask(for: .applicationMenuFrame, timeout: .seconds(10)) {
                var hasDoneInitialUpdate = false
                while true {
                    try Task.checkCancellation()
                    guard
                        let latestFrame = appState.menuBarManager.getApplicationMenuFrame(for: displayID),
                        latestFrame != self.applicationMenuFrame
                    else {
                        if hasDoneInitialUpdate {
                            try await Task.sleep(for: .seconds(1))
                        } else {
                            try await Task.sleep(for: .milliseconds(1))
                        }
                        continue
                    }
                    self.insertUpdateFlag(.applicationMenuFrame)
                    hasDoneInitialUpdate = true
                }
            }
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                if self.owningScreen != NSScreen.main {
                    self.updateTaskContext.cancelTask(for: .applicationMenuFrame)
                }
            }
        }
        .store(in: &c)

        // Special cases for when the user drags an app onto or clicks into another space.
        Publishers.Merge(
            publisher(for: \.isOnActiveSpace)
                .receive(on: DispatchQueue.main)
                .mapToVoid(),
            UniversalEventMonitor.publisher(for: .leftMouseUp)
                .filter { [weak self] _ in self?.isOnActiveSpace ?? false }
                .mapToVoid()
        )
        .debounce(for: 0.05, scheduler: DispatchQueue.main)
        .sink { [weak self] in
            self?.insertUpdateFlag(.applicationMenuFrame)
        }
        .store(in: &c)

        Timer.publish(every: 10, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                self?.insertUpdateFlag(.applicationMenuFrame)
            }
            .store(in: &c)

        $needsShow
            .debounce(for: 0.05, scheduler: DispatchQueue.main)
            .sink { [weak self] needsShow in
                guard let self, needsShow else {
                    return
                }
                defer {
                    self.needsShow = false
                }
                show()
            }
            .store(in: &c)

        $updateFlags
            .sink { [weak self] flags in
                guard let self, !flags.isEmpty else {
                    return
                }
                Task {
                    // Must be run async, or this will not remove the flags.
                    self.updateFlags.removeAll()
                }
                let windows = WindowInfo.getOnScreenWindows()
                guard let owningDisplay = self.validate(for: .updates, with: windows) else {
                    return
                }
                performUpdates(for: flags, windows: windows, display: owningDisplay)
            }
            .store(in: &c)

        if let appState {
            appState.menuBarManager.$isMenuBarHiddenBySystem
                .sink { [weak self] isHidden in
                    self?.alphaValue = isHidden ? 0 : 1
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Inserts the given update flag into the panel's current list of update flags.
    private func insertUpdateFlag(_ flag: UpdateFlag) {
        updateFlags.insert(flag)
    }

    /// Performs validation for the given validation kind. Returns the panel's
    /// owning display if successful. Returns `nil` on failure.
    private func validate(for kind: ValidationKind, with windows: [WindowInfo]) -> CGDirectDisplayID? {
        lazy var actionMessage = switch kind {
        case .showing: "Preventing overlay panel from showing."
        case .updates: "Preventing overlay panel from updating."
        }
        guard let appState else {
            Logger.overlayPanel.debug("No app state. \(actionMessage)")
            return nil
        }
        guard !appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults else {
            Logger.overlayPanel.debug("Menu bar is hidden by system. \(actionMessage)")
            return nil
        }
        guard !appState.isActiveSpaceFullscreen else {
            Logger.overlayPanel.debug("Active space is fullscreen. \(actionMessage)")
            return nil
        }
        let owningDisplay = owningScreen.displayID
        guard appState.menuBarManager.hasValidMenuBar(in: windows, for: owningDisplay) else {
            Logger.overlayPanel.debug("No valid menu bar found. \(actionMessage)")
            return nil
        }
        return owningDisplay
    }

    /// Stores the frame of the menu bar's application menu.
    private func updateApplicationMenuFrame(for display: CGDirectDisplayID) {
        guard
            let menuBarManager = appState?.menuBarManager,
            !menuBarManager.isMenuBarHiddenBySystem
        else {
            return
        }
        applicationMenuFrame = menuBarManager.getApplicationMenuFrame(for: display)
    }

    /// Updates the panel to prepare for display.
    private func performUpdates(for flags: Set<UpdateFlag>, windows: [WindowInfo], display: CGDirectDisplayID) {
        if flags.contains(.applicationMenuFrame) {
            updateApplicationMenuFrame(for: display)
        }
    }

    /// Shows the panel.
    private func show() {
        guard
            let appState,
            !appState.isPreview
        else {
            return
        }

        guard appState.appearanceManager.overlayPanels.contains(self) else {
            Logger.overlayPanel.warning("Overlay panel \(self) not retained")
            return
        }

        guard let menuBarHeight = owningScreen.getMenuBarHeight() else {
            return
        }

        let newFrame = CGRect(
            x: owningScreen.frame.minX,
            y: (owningScreen.frame.maxY - menuBarHeight) - 5,
            width: owningScreen.frame.width,
            height: menuBarHeight + 5
        )

        alphaValue = 0
        setFrame(newFrame, display: false)
        orderFrontRegardless()
        // The tint is opaque: keep the panel below the status-item windows
        // (level 25) by pinning it just above the menu bar background window
        // (same level 24). Otherwise the pills would cover the menu bar icons.
        if let menuBarWindowID = WindowInfo.getMenuBarWindow(for: owningScreen.displayID)?.windowID {
            order(.above, relativeTo: Int(menuBarWindowID))
        }

        updateFlags = [.applicationMenuFrame]

        if !appState.menuBarManager.isMenuBarHiddenBySystem {
            animator().alphaValue = 1
        }
    }

    override func isAccessibilityElement() -> Bool {
        return false
    }
}

// MARK: - Content View

private final class MenuBarOverlayPanelContentView: NSView {
    /// Last-known trailing status widths per display.
    ///
    /// The Accessibility fallback scan blocks in cross-process IPC, so it must
    /// never run inside `draw(_:)`. Draws read this cache (main thread only);
    /// stale entries trigger a background rescan that redisplay on completion.
    private var trailingWidthCache = [CGDirectDisplayID: (width: CGFloat, date: Date)]()

    /// Displays with a background trailing-width rescan in flight.
    private var trailingWidthScanInFlight = Set<CGDirectDisplayID>()

    /// How long a cached trailing width is trusted before rescanning.
    private static let trailingWidthTTL: TimeInterval = 2

    /// Burst-rescan deadlines per display.
    ///
    /// While a hide/show slide animation is in flight, each completed scan
    /// chains another one so the trailing pill tracks the sliding icons
    /// instead of jumping on the 2s TTL.
    private var trailingBurstUntil = [CGDirectDisplayID: Date]()

    /// Currently drawn trailing widths per display.
    ///
    /// The AX rescan lands once per ~0.3s, but the native icon slide runs at
    /// 60fps. Draws read this value and ease it toward the cached target a
    /// third of the remaining distance per frame (~0.25s to converge), so the
    /// pill's leading edge slides with the icons — shrinking rightwards on
    /// hide, expanding leftwards on show — instead of jumping after them.
    private var displayedTrailingWidth = [CGDirectDisplayID: CGFloat]()

    /// Settled trailing widths remembered per display: concealed (hidden
    /// section put away) vs revealed. Toggles alternate between these two
    /// values, so a hide/show can start gliding toward the remembered
    /// opposite end instantly — ~1s before the AX rescan lands to confirm.
    private var settledConcealedWidth = [CGDirectDisplayID: CGFloat]()
    private var settledRevealedWidth = [CGDirectDisplayID: CGFloat]()

    /// Predictive target per display, active while a toggle burst is in
    /// flight. Draws ease toward this instead of the stale cache; cleared
    /// when the burst settles and the rescan confirms the real width.
    private var predictiveTarget = [CGDirectDisplayID: CGFloat]()

    /// Frosted-glass blur of the live background, masked to the pills.
    ///
    /// Sits below `tintView`: blur first, then the (possibly translucent)
    /// tint on top.
    private lazy var blurView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.mask = blurMask
        return view
    }()

    /// Mask that clips `blurView` to the pills.
    private let blurMask = CAShapeLayer()

    /// Draws the pill tint (and border) above `blurView`.
    private lazy var tintView = MenuBarTintView()

    @Published private var fullConfiguration: MenuBarAppearanceConfigurationV2 = .defaultConfiguration

    @Published private var previewConfiguration: MenuBarAppearancePartialConfiguration?

    private var cancellables = Set<AnyCancellable>()

    /// The overlay panel that contains the content view.
    private var overlayPanel: MenuBarOverlayPanel? {
        window as? MenuBarOverlayPanel
    }

    /// The currently displayed configuration.
    private var configuration: MenuBarAppearancePartialConfiguration {
        previewConfiguration ?? fullConfiguration.current
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // blurView below, tintView above: blur first, then tint on top.
        addSubview(blurView)
        addSubview(tintView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let overlayPanel {
            if let appState = overlayPanel.appState {
                appState.appearanceManager.$configuration
                    .removeDuplicates()
                    .assign(to: &$fullConfiguration)

                appState.appearanceManager.$previewConfiguration
                    .removeDuplicates()
                    .assign(to: &$previewConfiguration)

                for section in appState.menuBarManager.sections {
                    // Redraw whenever the window frame of a control item changes.
                    //
                    // - NOTE: A previous attempt was made to redraw the view when the
                    //   section's `isHidden` property was changed. This would be semantically
                    //   ideal, but the property sometimes changes before the menu bar items
                    //   are actually updated on-screen. Since the view's drawing process relies
                    //   on getting an accurate position of each menu bar item, we need to use
                    //   something that publishes its changes only after the items are updated.
                    section.controlItem.$windowFrame
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] _ in
                            self?.noteControlItemMoved()
                        }
                        .store(in: &c)

                    // Redraw whenever the visibility of a control item changes.
                    //
                    // - NOTE: If the "ShowSectionDividers" setting is disabled, the window
                    //   frame does not update when the section is hidden or shown, but the
                    //   visibility does. We observe both to ensure the update occurs.
                    section.controlItem.$isVisible
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] _ in
                            self?.noteControlItemMoved()
                        }
                        .store(in: &c)
                }
            }

            // Fade out whenever a menu bar item is being dragged.
            overlayPanel.$isDraggingMenuBarItem
                .removeDuplicates()
                .sink { [weak self] isDragging in
                    if isDragging {
                        self?.animator().alphaValue = 0
                    } else {
                        self?.animator().alphaValue = 1
                    }
                }
                .store(in: &c)
            // Redraw whenever the application menu frame changes.
            overlayPanel.$applicationMenuFrame
                .sink { [weak self] _ in
                    self?.needsDisplay = true
                }
                .store(in: &c)
        }

        // Redraw whenever the configurations change.
        $fullConfiguration.mapToVoid()
            .merge(with: $previewConfiguration.mapToVoid())
            .sink { [weak self] _ in
                self?.needsDisplay = true
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a path in the given rectangle, with the given end caps,
    /// and inset by the given amounts.
    private func shapePath(in rect: CGRect, leadingEndCap: MenuBarEndCap, trailingEndCap: MenuBarEndCap, screen: NSScreen) -> NSBezierPath {
        let insetRect: CGRect = if !screen.hasNotch {
            switch (leadingEndCap, trailingEndCap) {
            case (.square, .square):
                CGRect(x: rect.origin.x, y: rect.origin.y + 1, width: rect.width, height: rect.height - 2)
            case (.square, .round):
                CGRect(x: rect.origin.x, y: rect.origin.y + 1, width: rect.width - 1, height: rect.height - 2)
            case (.round, .square):
                CGRect(x: rect.origin.x + 1, y: rect.origin.y + 1, width: rect.width - 1, height: rect.height - 2)
            case (.round, .round):
                CGRect(x: rect.origin.x + 1, y: rect.origin.y + 1, width: rect.width - 2, height: rect.height - 2)
            }
        } else {
            rect
        }

        let shapeBounds = CGRect(
            x: insetRect.minX + insetRect.height / 2,
            y: insetRect.minY,
            width: insetRect.width - insetRect.height,
            height: insetRect.height
        )
        let leadingEndCapBounds = CGRect(
            x: insetRect.minX,
            y: insetRect.minY,
            width: insetRect.height,
            height: insetRect.height
        )
        let trailingEndCapBounds = CGRect(
            x: insetRect.maxX - insetRect.height,
            y: insetRect.minY,
            width: insetRect.height,
            height: insetRect.height
        )

        var path = NSBezierPath(rect: shapeBounds)

        path = switch leadingEndCap {
        case .square: path.union(NSBezierPath(rect: leadingEndCapBounds))
        case .round: path.union(NSBezierPath(ovalIn: leadingEndCapBounds))
        }

        path = switch trailingEndCap {
        case .square: path.union(NSBezierPath(rect: trailingEndCapBounds))
        case .round: path.union(NSBezierPath(ovalIn: trailingEndCapBounds))
        }

        return path
    }

    /// Returns a path for the ``MenuBarShapeKind/full`` shape kind.
    private func pathForFullShape(in rect: CGRect, info: MenuBarFullShapeInfo, isInset: Bool, screen: NSScreen) -> NSBezierPath {
        guard let appearanceManager = overlayPanel?.appState?.appearanceManager else {
            return NSBezierPath()
        }
        var rect = rect
        let shouldInset = isInset && screen.hasNotch
        if shouldInset {
            rect = rect.insetBy(dx: 0, dy: appearanceManager.menuBarInsetAmount)
            if info.leadingEndCap == .round {
                rect.origin.x += appearanceManager.menuBarInsetAmount
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
            if info.trailingEndCap == .round {
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
        }
        return shapePath(
            in: rect,
            leadingEndCap: info.leadingEndCap,
            trailingEndCap: info.trailingEndCap,
            screen: screen
        )
    }

    /// Returns a path for the ``MenuBarShapeKind/split`` shape kind.
    private func pathForSplitShape(in rect: CGRect, info: MenuBarSplitShapeInfo, isInset: Bool, screen: NSScreen) -> NSBezierPath {
        guard let appearanceManager = overlayPanel?.appState?.appearanceManager else {
            return NSBezierPath()
        }
        var rect = rect
        let shouldInset = isInset && screen.hasNotch
        if shouldInset {
            rect = rect.insetBy(dx: 0, dy: appearanceManager.menuBarInsetAmount)
            if info.leading.leadingEndCap == .round {
                rect.origin.x += appearanceManager.menuBarInsetAmount
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
            if info.trailing.trailingEndCap == .round {
                rect.size.width -= appearanceManager.menuBarInsetAmount
            }
        }
        let leadingPathBounds: CGRect = {
            guard
                var maxX = overlayPanel?.applicationMenuFrame?.width,
                maxX > 0
            else {
                return .zero
            }
            if shouldInset {
                maxX += 10
                if info.leading.leadingEndCap == .square {
                    maxX += appearanceManager.menuBarInsetAmount
                }
            } else {
                maxX += 20
            }
            return CGRect(x: rect.minX, y: rect.minY, width: maxX, height: rect.height)
        }()
        let trailingPathBounds: CGRect = {
            let items = MenuBarItem.getMenuBarItems(on: screen.displayID, onScreenOnly: true, activeSpaceOnly: false)
            let totalWidth: CGFloat = if items.isEmpty {
                // macOS 27: CGSGetProcessMenuBarWindowList no longer returns status
                // items, so fall back to a cached Accessibility-based estimate.
                // The live AX scan blocks in IPC and must stay off the draw path.
                cachedTrailingStatusWidth(for: screen.displayID)
            } else {
                items.reduce(into: 0) { width, item in
                    width += item.frame.width
                }
            }
            guard totalWidth > 0 else {
                return .zero
            }
            var position = rect.maxX - totalWidth
            if shouldInset {
                position += 4
                if info.trailing.trailingEndCap == .square {
                    position -= appearanceManager.menuBarInsetAmount
                }
            } else {
                position -= 7
            }
            return CGRect(x: position, y: rect.minY, width: rect.maxX - position, height: rect.height)
        }()

        let hasLeading = leadingPathBounds != .zero
        let hasTrailing = trailingPathBounds != .zero

        if hasLeading, hasTrailing {
            if leadingPathBounds.intersects(trailingPathBounds) {
                // Genuinely crowded bar: fall back to a full-width shape.
                return shapePath(
                    in: rect,
                    leadingEndCap: info.leading.leadingEndCap,
                    trailingEndCap: info.trailing.trailingEndCap,
                    screen: screen
                )
            }
            let leadingPath = shapePath(
                in: leadingPathBounds,
                leadingEndCap: info.leading.leadingEndCap,
                trailingEndCap: info.leading.trailingEndCap,
                screen: screen
            )
            let trailingPath = shapePath(
                in: trailingPathBounds,
                leadingEndCap: info.trailing.leadingEndCap,
                trailingEndCap: info.trailing.trailingEndCap,
                screen: screen
            )
            let path = NSBezierPath()
            path.append(leadingPath)
            path.append(trailingPath)
            return path
        }
        // Only one side is known (the other is still resolving, e.g. the
        // trailing width on macOS 26+ where the CGS menu-bar-item list comes
        // back empty until the AX rescan lands). Draw just the known pill so
        // the rest of the bar keeps showing the wallpaper instead of
        // collapsing to a full-width tint, which paints the transparent gap
        // gray and makes tint/wallpaper look swapped.
        if hasLeading {
            return shapePath(
                in: leadingPathBounds,
                leadingEndCap: info.leading.leadingEndCap,
                trailingEndCap: info.leading.trailingEndCap,
                screen: screen
            )
        }
        if hasTrailing {
            return shapePath(
                in: trailingPathBounds,
                leadingEndCap: info.trailing.leadingEndCap,
                trailingEndCap: info.trailing.trailingEndCap,
                screen: screen
            )
        }
        // Nothing known yet: leave the whole bar as wallpaper.
        return NSBezierPath()
    }

    /// Returns the last-known trailing status width for the display without
    /// blocking. Kicks off a background rescan when the cached value is stale;
    /// the view redisplays when the rescan completes. While a toggle burst is
    /// in flight the returned value eases toward the predicted end position,
    /// so hide/show renders as one continuous glide starting with the icons,
    /// not a jump ~1s after them.
    private func cachedTrailingStatusWidth(for display: CGDirectDisplayID) -> CGFloat {
        refreshTrailingStatusWidth(for: display, force: false)
        let target = predictiveTarget[display] ?? trailingWidthCache[display]?.width ?? 0
        guard target > 0 else {
            displayedTrailingWidth[display] = 0
            return 0
        }
        let current = displayedTrailingWidth[display] ?? target
        guard abs(current - target) >= 0.5 else {
            displayedTrailingWidth[display] = target
            return target
        }
        // ~22% per frame converges in ~0.3s, matching the native icon slide.
        let next = current + (target - current) * 0.22
        displayedTrailingWidth[display] = next
        DispatchQueue.main.async { [weak self] in
            self?.needsDisplay = true
        }
        return next
    }

    /// A control item moved or toggled: redraw now, jump the pill toward the
    /// remembered end position at once, and keep chaining scans for ~2s so the
    /// rescan confirms (and corrects) the prediction mid-slide.
    private func noteControlItemMoved() {
        needsDisplay = true
        guard let panel = overlayPanel, let appState = panel.appState else {
            return
        }
        let display = panel.owningScreen.displayID
        // Toggles alternate concealed <-> revealed: predict the destination
        // now instead of waiting ~1s for the AX rescan. Hide => shrink toward
        // the remembered concealed width; show => expand toward revealed.
        let concealing = appState.menuBarManager.section(withName: .hidden)?.controlItem.state == .hideItems
        if concealing, let remembered = settledConcealedWidth[display], remembered > 0 {
            predictiveTarget[display] = remembered
        } else if !concealing, let remembered = settledRevealedWidth[display], remembered > 0 {
            predictiveTarget[display] = remembered
        }
        trailingBurstUntil[display] = Date().addingTimeInterval(2.0)
        refreshTrailingStatusWidth(for: display, force: true)
    }

    /// Kicks off a background trailing-width rescan unless one is already in
    /// flight. Completions redisplay and, while a toggle burst is active,
    /// chain the next scan.
    private func refreshTrailingStatusWidth(for display: CGDirectDisplayID, force: Bool) {
        let cached = trailingWidthCache[display]
        let isStale = force || cached.map { Date().timeIntervalSince($0.date) > Self.trailingWidthTTL } ?? true
        guard isStale, !trailingWidthScanInFlight.contains(display) else {
            return
        }
        trailingWidthScanInFlight.insert(display)
        let previous = cached?.width ?? 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let width = self?.trailingStatusWidthFallback(for: display) ?? previous
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.trailingWidthCache[display] = (width, Date())
                self.trailingWidthScanInFlight.remove(display)
                self.needsDisplay = true
                if let until = self.trailingBurstUntil[display], Date() < until {
                    self.refreshTrailingStatusWidth(for: display, force: true)
                } else {
                    self.trailingBurstUntil.removeValue(forKey: display)
                    // Burst settled: this is the real end position. Remember
                    // it so the next toggle can predict instantly, and drop
                    // the prediction it was gliding toward.
                    if width > 0, let appState = self.overlayPanel?.appState {
                        let concealed = appState.menuBarManager.section(withName: .hidden)?.controlItem.state == .hideItems
                        if concealed {
                            self.settledConcealedWidth[display] = width
                        } else {
                            self.settledRevealedWidth[display] = width
                        }
                    }
                    self.predictiveTarget.removeValue(forKey: display)
                }
            }
        }
    }

    /// Estimates the width of the trailing status-item cluster using Accessibility.
    ///
    /// On macOS 27, `CGSGetProcessMenuBarWindowList` returns only the Menubar
    /// itself, so `MenuBarItem.getMenuBarItems` comes back empty and split
    /// shapes collapse to full. This scans the top strip from right to left
    /// and returns the distance from the right edge to the leftmost status
    /// element. Returns `nil` when nothing status-like is found.
    ///
    /// - ponytail: O(n) AX scan per call; always call via cachedTrailingStatusWidth
    ///   (background + TTL), never directly from draw.
    private func trailingStatusWidthFallback(for display: CGDirectDisplayID) -> CGFloat? {
        let displayBounds = CGDisplayBounds(display)
        guard displayBounds.width > 0 else {
            return nil
        }
        let y = Float(displayBounds.origin.y + 16)
        // Middle of the (now 33pt on macOS 27) bar hits items reliably;
        // the top edge can return the WindowManager glass container instead.
        let appMenuPid: pid_t? = (try? systemWideElement.elementAtPosition(
            Float(displayBounds.origin.x + 2),
            y
        )?.pid())

        var leftmostX: CGFloat?
        // Status cluster lives at the right edge; 800pt covers even wide clusters.
        // Scan the whole window: some third-party items report their parent
        // AXMenuBar instead of a button, so early-exit on gaps stops too soon.
        // Step 16pt stays below the narrowest icon (~20pt) so nothing is
        // skipped, but cuts AX round-trips ~40% vs 10pt — the scan, not the
        // animation, was the ~1s lag behind the icons.
        let step: CGFloat = 16
        var x = displayBounds.maxX - 2
        let stopX = max(displayBounds.minX, displayBounds.maxX - 800)
        while x > stopX {
            guard let element = try? systemWideElement.elementAtPosition(Float(x), y) else {
                x -= step
                continue
            }
            let role: String? = try? element.attribute("AXRole")
            if role == "AXMenuBar" {
                x -= step
                continue
            }
            let frame: CGRect? = try? element.attribute("AXFrame")
            let pid: pid_t? = try? element.pid()
            // macOS 27 roles observed in the status cluster: AXGroup
            // (MenuBarAgent/ControlCenter), AXMenuBarItem, AXButton
            // (third-party extras). App-menu items share the frontmost pid.
            let isStatusElement: Bool = if role == "AXGroup" {
                true
            } else if role == "AXMenuBarItem" || role == "AXButton" {
                pid != nil && pid != appMenuPid
            } else {
                false
            }
            if
                isStatusElement,
                let frame,
                frame.width > 0, frame.height > 0, frame.height <= 50,
                frame.minY <= displayBounds.origin.y + 10
            {
                leftmostX = min(leftmostX ?? frame.minX, frame.minX)
                // Skip past this element to cut down on AX calls.
                // min() guarantees progress when the frame edge lands on x.
                x = min(frame.minX - 2, x - step)
                continue
            }
            x -= step
        }
        guard let leftmostX else {
            return nil
        }
        let width = displayBounds.maxX - leftmostX
        guard width > 0 else {
            return nil
        }
        // The sweep only covers the trailing 800pt. A width pinned at that
        // cap means the scan swallowed a glass container (or a cluster wider
        // than the scan window) — treat it as unknown so split doesn't paint
        // an over-wide pill over the transparent gap.
        let scanWindow = min(displayBounds.width, 800)
        guard width < scanWindow - 10 else {
            return nil
        }
        return width
    }

    /// Returns the bounds that the view's drawn content can occupy.
    private func getDrawableBounds() -> CGRect {
        return CGRect(
            x: bounds.origin.x,
            y: bounds.origin.y + 5,
            width: bounds.width,
            height: bounds.height - 5
        )
    }

    /// Syncs the blur and tint layers with the given shape.
    private func updateChrome(with shapePath: NSBezierPath, fillRect: CGRect, shapeKind: MenuBarShapeKind) {
        if blurView.frame != bounds {
            blurView.frame = bounds
        }
        if tintView.frame != bounds {
            tintView.frame = bounds
        }
        let isEmpty = shapePath.isEmpty
        // Blur only matters when enabled and visible through the tint.
        // NSVisualEffectView has no radius API, so the amount drives the
        // layer opacity: it fades between fully blurred and the sharp live
        // background, which reads as blur strength.
        blurView.isHidden = configuration.blurAmount <= 0
            || isEmpty
            || (configuration.tintKind != .none && configuration.tintOpacity >= 1)
        blurView.alphaValue = configuration.blurAmount
        blurMask.frame = blurView.bounds
        blurMask.path = shapePath.cgPath
        tintView.shapePath = shapePath
        tintView.fillRect = fillRect
        tintView.shapeKind = shapeKind
        tintView.tintKind = configuration.tintKind
        tintView.tintColor = configuration.tintColor
        tintView.tintGradient = configuration.tintGradient
        tintView.tintOpacity = configuration.tintOpacity
        tintView.hasBorder = configuration.hasBorder
        tintView.borderColor = configuration.borderColor
        tintView.borderWidth = configuration.borderWidth
        tintView.isHidden = isEmpty || (configuration.tintKind == .none && !configuration.hasBorder)
        tintView.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard
            let overlayPanel,
            let context = NSGraphicsContext.current
        else {
            return
        }

        let drawableBounds = getDrawableBounds()

        let shapePath = switch fullConfiguration.shapeKind {
        case .none:
            NSBezierPath(rect: drawableBounds)
        case .full:
            pathForFullShape(
                in: drawableBounds,
                info: fullConfiguration.fullShapeInfo,
                isInset: fullConfiguration.isInset,
                screen: overlayPanel.owningScreen
            )
        case .split:
            pathForSplitShape(
                in: drawableBounds,
                info: fullConfiguration.splitShapeInfo,
                isInset: fullConfiguration.isInset,
                screen: overlayPanel.owningScreen
            )
        }

        switch fullConfiguration.shapeKind {
        case .none:
            if configuration.hasShadow {
                let gradient = NSGradient(
                    colors: [
                        NSColor(white: 0.0, alpha: 0.0),
                        NSColor(white: 0.0, alpha: 0.2),
                    ]
                )
                let shadowBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: 5
                )
                gradient?.draw(in: shadowBounds, angle: 90)
            }
        case .full, .split:
            // Nothing is drawn outside the shape: the panel is transparent
            // there, so the live background shows through.
            if configuration.hasShadow {
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                let shadowClipPath = NSBezierPath(rect: bounds)
                shadowClipPath.append(shapePath.reversed)
                shadowClipPath.setClip()

                shapePath.drawShadow(color: .black.withAlphaComponent(0.5), radius: 5)
            }
        }

        // Tint and border live in layers above the blur; sync them here.
        updateChrome(with: shapePath, fillRect: drawableBounds, shapeKind: fullConfiguration.shapeKind)
    }
}

// MARK: - Tint View

/// Draws the pill tint (and border) above the blur layer.
private final class MenuBarTintView: NSView {
    var shapePath = NSBezierPath()
    var fillRect = CGRect.zero
    var shapeKind = MenuBarShapeKind.none
    var tintKind = MenuBarTintKind.none
    var tintColor: CGColor = NSColor.black.cgColor ?? CGColor(gray: 0, alpha: 1)
    var tintGradient = CustomGradient.defaultMenuBarTint
    var tintOpacity = 1.0
    var hasBorder = false
    var borderColor: CGColor = NSColor.black.cgColor ?? CGColor(gray: 0, alpha: 1)
    var borderWidth = 1.0

    override func draw(_ dirtyRect: NSRect) {
        guard
            !shapePath.isEmpty,
            let context = NSGraphicsContext.current
        else {
            return
        }

        context.saveGraphicsState()
        shapePath.setClip()

        switch tintKind {
        case .none:
            break
        case .solid:
            if let tintColor = NSColor(cgColor: tintColor)?.withAlphaComponent(tintOpacity) {
                tintColor.setFill()
                fillRect.fill()
            }
        case .gradient:
            if let tintGradient = tintGradient.withAlphaComponent(tintOpacity).nsGradient {
                tintGradient.draw(in: fillRect, angle: 0)
            }
        }

        context.restoreGraphicsState()

        if hasBorder {
            switch shapeKind {
            case .none:
                let borderBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY + 5,
                    width: bounds.width,
                    height: borderWidth
                )
                NSColor(cgColor: borderColor)?.setFill()
                NSBezierPath(rect: borderBounds).fill()
            case .full, .split:
                guard let borderColor = NSColor(cgColor: borderColor) else {
                    return
                }
                context.saveGraphicsState()
                defer {
                    context.restoreGraphicsState()
                }

                // HACK: Insetting a path to get an "inside" stroke is surprisingly
                // difficult. We can fake the correct line width by doubling it, as
                // anything outside the shape path will be clipped.
                shapePath.lineWidth = borderWidth * 2
                shapePath.setClip()

                borderColor.setStroke()
                shapePath.stroke()
            }
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let overlayPanel = Logger(category: "MenuBarOverlayPanel")
}
