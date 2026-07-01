import UIKit
import WebKit

final class ZeroNativeHostViewController: UIViewController {
    private let headerView = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let backButton = UIButton(type: .system)
    private let refreshButton = UIButton(type: .system)
    private let webView = WKWebView(frame: .zero)
    private var webViewBottomConstraint: NSLayoutConstraint?
    private var nativeApp: UnsafeMutableRawPointer?
    private var keyboardBottomInset: CGFloat = 0
    private var widgetAccessibilityElements: [UIAccessibilityElement] = []

    private struct WidgetSemantics {
        let id: UInt64
        let parentId: UInt64
        let role: Int32
        let flags: UInt32
        let actions: UInt32
        let bounds: CGRect
        let value: Float?
        let label: String
        let text: String
        let textSelectionStart: Int
        let textSelectionEnd: Int
        let textCompositionStart: Int
        let textCompositionEnd: Int
        let gridRowIndex: Int
        let gridColumnIndex: Int
        let gridRowCount: Int
        let gridColumnCount: Int
        let listItemIndex: Int
        let listItemCount: Int
        let scrollOffset: Float
        let scrollViewportExtent: Float
        let scrollContentExtent: Float
        let hasScroll: Bool
    }

    private struct WidgetTextGeometry {
        let id: UInt64
        let caretBounds: CGRect?
        let selectionBounds: CGRect?
        let selectionRectCount: Int
        let compositionBounds: CGRect?
        let compositionRectCount: Int
    }

    private final class WidgetAccessibilityElement: UIAccessibilityElement {
        private weak var owner: ZeroNativeHostViewController?
        private let node: WidgetSemantics

        init(accessibilityContainer container: Any, owner: ZeroNativeHostViewController, node: WidgetSemantics) {
            self.owner = owner
            self.node = node
            super.init(accessibilityContainer: container)
        }

        override func accessibilityActivate() -> Bool {
            owner?.activateWidgetAccessibilityNode(node) ?? false
        }

        override func accessibilityIncrement() {
            _ = owner?.incrementWidgetAccessibilityNode(node)
        }

        override func accessibilityDecrement() {
            _ = owner?.decrementWidgetAccessibilityNode(node)
        }

        override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
            switch direction {
            case .down, .right:
                return owner?.incrementWidgetAccessibilityNode(node) ?? false
            case .up, .left:
                return owner?.decrementWidgetAccessibilityNode(node) ?? false
            default:
                return false
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        configureHeader()

        headerView.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerView)
        view.addSubview(webView)
        let webViewBottomConstraint = webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        self.webViewBottomConstraint = webViewBottomConstraint
        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 104),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            webViewBottomConstraint,
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameWillChange), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)

        nativeApp = zero_native_app_create()
        if let nativeApp {
            zero_native_app_start(nativeApp)
            refreshWidgetAccessibility()
        }

        webView.loadHTMLString(Self.html, baseURL: nil)
    }

    func activateNativeApp() {
        guard let nativeApp else { return }
        zero_native_app_activate(nativeApp)
    }

    func deactivateNativeApp() {
        guard let nativeApp else { return }
        zero_native_app_deactivate(nativeApp)
    }

    private func configureHeader() {
        headerView.backgroundColor = .secondarySystemBackground

        titleLabel.text = "Mobile Shell"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true

        subtitleLabel.text = "Native header with WebView workspace"
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.adjustsFontForContentSizeCategory = true

        statusLabel.text = "System WebView"
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.backgroundColor = .tertiarySystemFill
        statusLabel.layer.cornerRadius = 11
        statusLabel.layer.masksToBounds = true
        statusLabel.textAlignment = .center

        backButton.setTitle("Back", for: .normal)
        backButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        backButton.addTarget(self, action: #selector(sendBackCommand), for: .touchUpInside)

        refreshButton.setTitle("Refresh", for: .normal)
        refreshButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        refreshButton.addTarget(self, action: #selector(sendRefreshCommand), for: .touchUpInside)

        [titleLabel, subtitleLabel, statusLabel, backButton, refreshButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            headerView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            statusLabel.heightAnchor.constraint(equalToConstant: 24),
            refreshButton.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            refreshButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            backButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -12),
            backButton.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: backButton.leadingAnchor, constant: -16),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
        ])
    }

    @objc private func sendBackCommand() {
        dispatchNativeCommand("mobile.back")
    }

    @objc private func sendRefreshCommand() {
        dispatchNativeCommand("mobile.refresh")
    }

    private func dispatchNativeCommand(_ command: String) {
        guard let nativeApp else { return }
        command.withCString { pointer in
            zero_native_app_command(nativeApp, pointer, UInt(command.utf8.count))
        }
        let count = zero_native_app_last_command_count(nativeApp)
        let name = String(cString: zero_native_app_last_command_name(nativeApp))
        statusLabel.text = "\(name) #\(count)"
        zero_native_app_frame(nativeApp)
        refreshWidgetAccessibility()
    }

    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        guard let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let keyboardFrame = view.convert(frameValue.cgRectValue, from: nil)
        let overlap = max(0, view.bounds.maxY - keyboardFrame.minY)
        keyboardBottomInset = overlap
        webViewBottomConstraint?.constant = -overlap
        animateKeyboardLayout(notification)
        sendViewportUpdate()
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboardBottomInset = 0
        webViewBottomConstraint?.constant = 0
        animateKeyboardLayout(notification)
        sendViewportUpdate()
    }

    private func animateKeyboardLayout(_ notification: Notification) {
        let userInfo = notification.userInfo ?? [:]
        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        let options = UIView.AnimationOptions(rawValue: curve << 16)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.view.layoutIfNeeded()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sendViewportUpdate()
    }

    private func sendViewportUpdate() {
        guard let nativeApp else { return }
        let scale = Float(view.window?.screen.scale ?? UIScreen.main.scale)
        let safe = view.safeAreaInsets
        zero_native_app_viewport(
            nativeApp,
            Float(webView.bounds.width),
            Float(webView.bounds.height),
            scale,
            nil,
            Float(safe.top),
            Float(safe.right),
            Float(safe.bottom),
            Float(safe.left),
            0,
            0,
            Float(keyboardBottomInset),
            0
        )
        zero_native_app_frame(nativeApp)
        refreshWidgetAccessibility()
    }

    private func widgetSemanticsSnapshot() -> [WidgetSemantics] {
        guard let nativeApp else { return [] }
        let count = Int(zero_native_app_widget_semantics_count(nativeApp))
        var nodes: [WidgetSemantics] = []
        nodes.reserveCapacity(count)
        for index in 0..<count {
            if let node = widgetSemantics(at: index) {
                nodes.append(node)
            }
        }
        return nodes
    }

    private func widgetSemantics(at index: Int) -> WidgetSemantics? {
        guard let nativeApp else { return nil }
        var node = zero_native_widget_semantics_t()
        guard zero_native_app_widget_semantics_at(nativeApp, UInt(index), &node) != 0 else { return nil }
        return widgetSemantics(from: node)
    }

    private func widgetSemantics(id: UInt64) -> WidgetSemantics? {
        guard let nativeApp else { return nil }
        var node = zero_native_widget_semantics_t()
        guard zero_native_app_widget_semantics_by_id(nativeApp, id, &node) != 0 else { return nil }
        return widgetSemantics(from: node)
    }

    private func widgetSemantics(from node: zero_native_widget_semantics_t) -> WidgetSemantics {
        return WidgetSemantics(
            id: node.id,
            parentId: node.parent_id,
            role: Int32(node.role),
            flags: node.flags,
            actions: node.actions,
            bounds: CGRect(x: CGFloat(node.x), y: CGFloat(node.y), width: CGFloat(node.width), height: CGFloat(node.height)),
            value: node.has_value != 0 ? node.value : nil,
            label: Self.utf8String(node.label, length: node.label_len),
            text: Self.utf8String(node.text, length: node.text_len),
            textSelectionStart: Int(node.text_selection_start),
            textSelectionEnd: Int(node.text_selection_end),
            textCompositionStart: Int(node.text_composition_start),
            textCompositionEnd: Int(node.text_composition_end),
            gridRowIndex: Int(node.grid_row_index),
            gridColumnIndex: Int(node.grid_column_index),
            gridRowCount: Int(node.grid_row_count),
            gridColumnCount: Int(node.grid_column_count),
            listItemIndex: Int(node.list_item_index),
            listItemCount: Int(node.list_item_count),
            scrollOffset: node.scroll_offset,
            scrollViewportExtent: node.scroll_viewport_extent,
            scrollContentExtent: node.scroll_content_extent,
            hasScroll: node.has_scroll != 0
        )
    }

    private func widgetTextGeometry(id: UInt64) -> WidgetTextGeometry? {
        guard let nativeApp else { return nil }
        var geometry = zero_native_widget_text_geometry_t()
        guard zero_native_app_widget_text_geometry(nativeApp, id, &geometry) != 0 else { return nil }
        return WidgetTextGeometry(
            id: id,
            caretBounds: geometry.has_caret_bounds != 0 ? CGRect(x: CGFloat(geometry.caret_x), y: CGFloat(geometry.caret_y), width: CGFloat(geometry.caret_width), height: CGFloat(geometry.caret_height)) : nil,
            selectionBounds: geometry.has_selection_bounds != 0 ? CGRect(x: CGFloat(geometry.selection_x), y: CGFloat(geometry.selection_y), width: CGFloat(geometry.selection_width), height: CGFloat(geometry.selection_height)) : nil,
            selectionRectCount: Int(geometry.selection_rect_count),
            compositionBounds: geometry.has_composition_bounds != 0 ? CGRect(x: CGFloat(geometry.composition_x), y: CGFloat(geometry.composition_y), width: CGFloat(geometry.composition_width), height: CGFloat(geometry.composition_height)) : nil,
            compositionRectCount: Int(geometry.composition_rect_count)
        )
    }

    @discardableResult
    private func dispatchWidgetAction(
        id: UInt64,
        action: Int32,
        text: String? = nil,
        selectionAnchor: UInt = 0,
        selectionFocus: UInt = 0,
        hasSelection: Bool = false
    ) -> Bool {
        guard let nativeApp else { return false }
        var request = zero_native_widget_action_t()
        request.id = id
        request.action = action
        request.selection_anchor = selectionAnchor
        request.selection_focus = selectionFocus
        request.has_selection = hasSelection ? 1 : 0
        let ok: Int32
        if let text {
            ok = text.withCString { pointer in
                request.text = pointer
                request.text_len = UInt(text.utf8.count)
                return zero_native_app_widget_action(nativeApp, &request)
            }
        } else {
            request.text = nil
            request.text_len = 0
            ok = zero_native_app_widget_action(nativeApp, &request)
        }
        if ok != 0 {
            zero_native_app_frame(nativeApp)
            refreshWidgetAccessibility()
        }
        return ok != 0
    }

    private func refreshWidgetAccessibility() {
        let semantics = widgetSemanticsSnapshot()
        statusLabel.accessibilityValue = "Accessible items: \(semantics.count)"
        widgetAccessibilityElements = semantics.map { node in
            let element = WidgetAccessibilityElement(accessibilityContainer: webView, owner: self, node: node)
            element.accessibilityIdentifier = "zero-native-widget-\(node.id)"
            element.accessibilityLabel = node.label.isEmpty ? node.text : node.label
            element.accessibilityValue = widgetAccessibilityValue(node)
            element.accessibilityFrameInContainerSpace = node.bounds
            element.accessibilityTraits = widgetAccessibilityTraits(node)
            return element
        }
        webView.accessibilityElements = widgetAccessibilityElements.isEmpty ? nil : widgetAccessibilityElements as [Any]
    }

    private func widgetAccessibilityValue(_ node: WidgetSemantics) -> String? {
        if (node.flags & UInt32(ZERO_NATIVE_WIDGET_FLAG_EXPANDED)) != 0 {
            return "Expanded"
        }
        if (node.flags & UInt32(ZERO_NATIVE_WIDGET_FLAG_COLLAPSED)) != 0 {
            return "Collapsed"
        }
        if let value = node.value {
            switch node.role {
            case Int32(ZERO_NATIVE_WIDGET_ROLE_CHECKBOX), Int32(ZERO_NATIVE_WIDGET_ROLE_SWITCH):
                return value >= 0.5 ? "On" : "Off"
            case Int32(ZERO_NATIVE_WIDGET_ROLE_SLIDER), Int32(ZERO_NATIVE_WIDGET_ROLE_PROGRESSBAR):
                return "\(Int((value * 100).rounded()))%"
            default:
                return "\(value)"
            }
        }
        return node.text.isEmpty ? nil : node.text
    }

    private func activateWidgetAccessibilityNode(_ node: WidgetSemantics) -> Bool {
        let current = widgetSemantics(id: node.id) ?? node
        if widgetSupportsAction(current, UInt32(ZERO_NATIVE_WIDGET_ACTION_TOGGLE)) {
            return dispatchWidgetAction(id: current.id, action: Int32(ZERO_NATIVE_WIDGET_ACTION_KIND_TOGGLE))
        }
        if widgetSupportsAction(current, UInt32(ZERO_NATIVE_WIDGET_ACTION_PRESS)) {
            return dispatchWidgetAction(id: current.id, action: Int32(ZERO_NATIVE_WIDGET_ACTION_KIND_PRESS))
        }
        if widgetSupportsAction(current, UInt32(ZERO_NATIVE_WIDGET_ACTION_SELECT)) {
            return dispatchWidgetAction(id: current.id, action: Int32(ZERO_NATIVE_WIDGET_ACTION_KIND_SELECT))
        }
        return false
    }

    private func incrementWidgetAccessibilityNode(_ node: WidgetSemantics) -> Bool {
        let current = widgetSemantics(id: node.id) ?? node
        guard widgetSupportsAction(current, UInt32(ZERO_NATIVE_WIDGET_ACTION_INCREMENT)) else { return false }
        return dispatchWidgetAction(id: current.id, action: Int32(ZERO_NATIVE_WIDGET_ACTION_KIND_INCREMENT))
    }

    private func decrementWidgetAccessibilityNode(_ node: WidgetSemantics) -> Bool {
        let current = widgetSemantics(id: node.id) ?? node
        guard widgetSupportsAction(current, UInt32(ZERO_NATIVE_WIDGET_ACTION_DECREMENT)) else { return false }
        return dispatchWidgetAction(id: current.id, action: Int32(ZERO_NATIVE_WIDGET_ACTION_KIND_DECREMENT))
    }

    private func widgetSupportsAction(_ node: WidgetSemantics, _ action: UInt32) -> Bool {
        return (node.actions & action) != 0
    }

    private func widgetAccessibilityTraits(_ node: WidgetSemantics) -> UIAccessibilityTraits {
        var traits: UIAccessibilityTraits = []
        switch node.role {
        case Int32(ZERO_NATIVE_WIDGET_ROLE_BUTTON), Int32(ZERO_NATIVE_WIDGET_ROLE_MENUITEM):
            traits.insert(.button)
        case Int32(ZERO_NATIVE_WIDGET_ROLE_CHECKBOX), Int32(ZERO_NATIVE_WIDGET_ROLE_SWITCH), Int32(ZERO_NATIVE_WIDGET_ROLE_TAB):
            traits.insert(.button)
        case Int32(ZERO_NATIVE_WIDGET_ROLE_SLIDER):
            traits.insert(.adjustable)
        case Int32(ZERO_NATIVE_WIDGET_ROLE_IMAGE):
            traits.insert(.image)
        case Int32(ZERO_NATIVE_WIDGET_ROLE_TEXT), Int32(ZERO_NATIVE_WIDGET_ROLE_PROGRESSBAR):
            traits.insert(.staticText)
        default:
            break
        }
        if (node.flags & UInt32(ZERO_NATIVE_WIDGET_FLAG_SELECTED)) != 0 {
            traits.insert(.selected)
        }
        if (node.flags & UInt32(ZERO_NATIVE_WIDGET_FLAG_DISABLED)) != 0 {
            traits.insert(.notEnabled)
        }
        return traits
    }

    private static func utf8String(_ pointer: UnsafePointer<CChar>?, length: UInt) -> String {
        guard let pointer, length > 0 else { return "" }
        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(length))
        return String(decoding: bytes, as: UTF8.self)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        guard let nativeApp else { return }
        zero_native_app_stop(nativeApp)
        zero_native_app_destroy(nativeApp)
    }

    private static let html = """
    <!doctype html>
    <html>
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <body style="margin:0;font-family:-apple-system,system-ui;background:#f7f8fa;color:#171717;">
        <main style="padding:28px 22px;display:grid;gap:16px;">
          <h1 style="margin:0;font-size:30px;letter-spacing:0;">Workspace</h1>
          <p style="margin:0;color:#5f6672;line-height:1.5;">This content is rendered by WKWebView while the header remains native UIKit.</p>
          <section style="display:grid;gap:10px;">
            <div style="padding:14px;border:1px solid #e1e5ea;border-radius:8px;background:white;">Inbox review</div>
            <div style="padding:14px;border:1px solid #e1e5ea;border-radius:8px;background:white;">Sync queue</div>
            <div style="padding:14px;border:1px solid #e1e5ea;border-radius:8px;background:white;">Offline cache</div>
          </section>
        </main>
      </body>
    </html>
    """
}
