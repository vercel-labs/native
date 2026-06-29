package dev.zero_native.examples.android

import android.app.Activity
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Rect
import android.os.Bundle
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeProvider
import android.webkit.WebView
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

class MainActivity : Activity(), SurfaceHolder.Callback {
    private var nativeApp: Long = 0
    private lateinit var statusLabel: TextView
    private lateinit var widgetSurface: WidgetSurfaceView
    private var currentSurfaceHolder: SurfaceHolder? = null

    data class WidgetSemantics(
        val id: Long,
        val parentId: Long,
        val role: Int,
        val flags: Int,
        val actions: Int,
        val x: Float,
        val y: Float,
        val width: Float,
        val height: Float,
        val value: Float?,
        val label: String,
        val text: String,
        val textSelectionStart: Long,
        val textSelectionEnd: Long,
        val textCompositionStart: Long,
        val textCompositionEnd: Long,
        val gridRowIndex: Long,
        val gridColumnIndex: Long,
        val gridRowCount: Long,
        val gridColumnCount: Long,
        val listItemIndex: Long,
        val listItemCount: Long,
        val scrollOffset: Float,
        val scrollViewportExtent: Float,
        val scrollContentExtent: Float,
        val hasScroll: Boolean,
    )

    data class WidgetTextGeometry(
        val id: Long,
        val hasCaretBounds: Boolean,
        val caretX: Float,
        val caretY: Float,
        val caretWidth: Float,
        val caretHeight: Float,
        val hasSelectionBounds: Boolean,
        val selectionX: Float,
        val selectionY: Float,
        val selectionWidth: Float,
        val selectionHeight: Float,
        val selectionRectCount: Int,
        val hasCompositionBounds: Boolean,
        val compositionX: Float,
        val compositionY: Float,
        val compositionWidth: Float,
        val compositionHeight: Float,
        val compositionRectCount: Int,
    )

    private inner class WidgetSurfaceView : SurfaceView(this@MainActivity) {
        private val provider = WidgetAccessibilityProvider(this)

        init {
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
            isFocusable = true
        }

        override fun getAccessibilityNodeProvider(): AccessibilityNodeProvider = provider

        fun notifyWidgetSemanticsChanged() {
            invalidate()
            provider.notifyWidgetSemanticsChanged()
        }
    }

    private inner class WidgetAccessibilityProvider(private val host: View) : AccessibilityNodeProvider() {
        private var accessibilityFocusedId: Long = 0

        override fun createAccessibilityNodeInfo(virtualViewId: Int): AccessibilityNodeInfo? {
            val nodes = widgetSemanticsSnapshot()
            return if (virtualViewId == View.NO_ID) {
                createHostNode(nodes)
            } else {
                nodes.firstOrNull { it.id.toInt() == virtualViewId }?.let { createWidgetNode(it, nodes) }
            }
        }

        override fun performAction(virtualViewId: Int, action: Int, arguments: Bundle?): Boolean {
            if (virtualViewId == View.NO_ID) return false
            val node = widgetSemanticsSnapshot().firstOrNull { it.id.toInt() == virtualViewId } ?: return false
            val id = node.id
            val handled = when (action) {
                AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS -> {
                    accessibilityFocusedId = id
                    host.invalidate()
                    sendVirtualEvent(id, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED)
                    true
                }
                AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS -> {
                    if (accessibilityFocusedId == id) accessibilityFocusedId = 0
                    host.invalidate()
                    sendVirtualEvent(id, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED)
                    true
                }
                AccessibilityNodeInfo.ACTION_FOCUS -> {
                    if (widgetSupportsAction(node, WIDGET_ACTION_FOCUS)) dispatchWidgetAction(id, WIDGET_ACTION_KIND_FOCUS) else false
                }
                AccessibilityNodeInfo.ACTION_CLICK -> performWidgetClick(id)
                AccessibilityNodeInfo.ACTION_SELECT -> {
                    if (widgetSupportsAction(node, WIDGET_ACTION_SELECT)) dispatchWidgetAction(id, WIDGET_ACTION_KIND_SELECT) else false
                }
                AccessibilityNodeInfo.ACTION_SCROLL_FORWARD -> {
                    if (widgetSupportsAction(node, WIDGET_ACTION_INCREMENT)) dispatchWidgetAction(id, WIDGET_ACTION_KIND_INCREMENT) else false
                }
                AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD -> {
                    if (widgetSupportsAction(node, WIDGET_ACTION_DECREMENT)) dispatchWidgetAction(id, WIDGET_ACTION_KIND_DECREMENT) else false
                }
                AccessibilityNodeInfo.ACTION_SET_TEXT -> {
                    val text = arguments?.getCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE)?.toString()
                    if (text != null && widgetSupportsAction(node, WIDGET_ACTION_SET_TEXT)) dispatchWidgetAction(id, WIDGET_ACTION_KIND_SET_TEXT, text) else false
                }
                AccessibilityNodeInfo.ACTION_SET_SELECTION -> {
                    val start = arguments?.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, -1) ?: -1
                    val end = arguments?.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, -1) ?: -1
                    if (start >= 0 && end >= 0 && widgetSupportsAction(node, WIDGET_ACTION_SET_SELECTION)) {
                        dispatchWidgetAction(id, WIDGET_ACTION_KIND_SET_SELECTION, selectionAnchor = start.toLong(), selectionFocus = end.toLong(), hasSelection = true)
                    } else {
                        false
                    }
                }
                else -> false
            }
            if (handled) host.invalidate()
            return handled
        }

        fun notifyWidgetSemanticsChanged() {
            val event = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
            event.setSource(host)
            event.packageName = packageName
            event.contentChangeTypes = AccessibilityEvent.CONTENT_CHANGE_TYPE_SUBTREE
            host.parent?.requestSendAccessibilityEvent(host, event)
        }

        private fun createHostNode(nodes: List<WidgetSemantics>): AccessibilityNodeInfo {
            val info = AccessibilityNodeInfo.obtain(host)
            host.onInitializeAccessibilityNodeInfo(info)
            info.className = SurfaceView::class.java.name
            for (node in nodes.filter { it.parentId == 0L }) {
                info.addChild(host, node.id.toInt())
            }
            return info
        }

        private fun createWidgetNode(node: WidgetSemantics, nodes: List<WidgetSemantics>): AccessibilityNodeInfo {
            val info = AccessibilityNodeInfo.obtain()
            val virtualId = node.id.toInt()
            val parentNode = nodes.firstOrNull { it.id == node.parentId }
            info.setSource(host, virtualId)
            if (parentNode != null) {
                info.setParent(host, parentNode.id.toInt())
            } else {
                info.setParent(host)
            }
            for (child in nodes.filter { it.parentId == node.id }) {
                info.addChild(host, child.id.toInt())
            }
            info.packageName = packageName
            info.className = widgetAccessibilityClassName(node)
            info.contentDescription = node.label.ifEmpty { node.text }
            if (node.text.isNotEmpty()) info.text = node.text
            info.isVisibleToUser = host.isShown
            info.isEnabled = (node.flags and WIDGET_FLAG_DISABLED) == 0
            info.isFocusable = (node.flags and WIDGET_FLAG_FOCUSABLE) != 0
            info.isFocused = (node.flags and WIDGET_FLAG_FOCUSED) != 0
            info.isAccessibilityFocused = accessibilityFocusedId == node.id
            info.isSelected = (node.flags and WIDGET_FLAG_SELECTED) != 0
            info.isCheckable = node.role == WIDGET_ROLE_CHECKBOX || node.role == WIDGET_ROLE_SWITCH
            info.isChecked = info.isCheckable && widgetValueSelected(node)
            info.isClickable = widgetSupportsAnyAction(node, WIDGET_ACTION_PRESS or WIDGET_ACTION_TOGGLE or WIDGET_ACTION_SELECT)
            info.isEditable = node.role == WIDGET_ROLE_TEXTBOX
            info.isScrollable = node.hasScroll
            if (node.value != null) {
                info.setRangeInfo(AccessibilityNodeInfo.RangeInfo.obtain(AccessibilityNodeInfo.RangeInfo.RANGE_TYPE_FLOAT, 0f, 1f, node.value))
            }
            setCollectionInfo(info, node, nodes)
            setCollectionItemInfo(info, node)
            if (node.textSelectionStart >= 0 && node.textSelectionEnd >= 0) {
                info.setTextSelection(node.textSelectionStart.toInt(), node.textSelectionEnd.toInt())
            }
            if (accessibilityFocusedId == node.id) {
                info.addAction(AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS)
            } else {
                info.addAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)
            }
            if (info.isFocusable) info.addAction(AccessibilityNodeInfo.ACTION_FOCUS)
            if (info.isClickable) info.addAction(AccessibilityNodeInfo.ACTION_CLICK)
            if (widgetSupportsAction(node, WIDGET_ACTION_SELECT)) info.addAction(AccessibilityNodeInfo.ACTION_SELECT)
            if (widgetSupportsAction(node, WIDGET_ACTION_INCREMENT)) info.addAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
            if (widgetSupportsAction(node, WIDGET_ACTION_DECREMENT)) info.addAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
            if (widgetSupportsAction(node, WIDGET_ACTION_SET_TEXT)) info.addAction(AccessibilityNodeInfo.ACTION_SET_TEXT)
            if (widgetSupportsAction(node, WIDGET_ACTION_SET_SELECTION)) info.addAction(AccessibilityNodeInfo.ACTION_SET_SELECTION)
            info.setBoundsInParent(boundsInParent(node, parentNode))
            val location = IntArray(2)
            host.getLocationOnScreen(location)
            val screenBounds = Rect(node.x.toInt(), node.y.toInt(), (node.x + node.width).toInt(), (node.y + node.height).toInt())
            info.setBoundsInScreen(Rect(screenBounds.left + location[0], screenBounds.top + location[1], screenBounds.right + location[0], screenBounds.bottom + location[1]))
            return info
        }

        private fun performWidgetClick(id: Long): Boolean {
            val node = widgetSemanticsSnapshot().firstOrNull { it.id == id } ?: return false
            return when {
                widgetSupportsAction(node, WIDGET_ACTION_TOGGLE) -> dispatchWidgetAction(id, WIDGET_ACTION_KIND_TOGGLE)
                widgetSupportsAction(node, WIDGET_ACTION_PRESS) -> dispatchWidgetAction(id, WIDGET_ACTION_KIND_PRESS)
                widgetSupportsAction(node, WIDGET_ACTION_SELECT) -> dispatchWidgetAction(id, WIDGET_ACTION_KIND_SELECT)
                else -> false
            }
        }

        private fun setCollectionInfo(info: AccessibilityNodeInfo, node: WidgetSemantics, nodes: List<WidgetSemantics>) {
            if (node.role == WIDGET_ROLE_GRID && node.gridRowCount >= 0 && node.gridColumnCount >= 0) {
                info.setCollectionInfo(AccessibilityNodeInfo.CollectionInfo.obtain(node.gridRowCount.toInt(), node.gridColumnCount.toInt(), false))
            } else if (node.role == WIDGET_ROLE_LIST) {
                val childCount = nodes.count { it.parentId == node.id && it.role == WIDGET_ROLE_LISTITEM }
                val itemCount = if (node.listItemCount >= 0) node.listItemCount.toInt() else childCount
                if (itemCount > 0) info.setCollectionInfo(AccessibilityNodeInfo.CollectionInfo.obtain(itemCount, 1, false))
            }
        }

        private fun setCollectionItemInfo(info: AccessibilityNodeInfo, node: WidgetSemantics) {
            if (node.gridRowIndex >= 0 && node.gridColumnIndex >= 0) {
                info.setCollectionItemInfo(AccessibilityNodeInfo.CollectionItemInfo.obtain(node.gridRowIndex.toInt(), 1, node.gridColumnIndex.toInt(), 1, false, info.isSelected))
            } else if (node.listItemIndex >= 0) {
                info.setCollectionItemInfo(AccessibilityNodeInfo.CollectionItemInfo.obtain(node.listItemIndex.toInt(), 1, 0, 1, false, info.isSelected))
            }
        }

        private fun boundsInParent(node: WidgetSemantics, parent: WidgetSemantics?): Rect {
            val parentX = parent?.x ?: 0f
            val parentY = parent?.y ?: 0f
            return Rect(
                (node.x - parentX).toInt(),
                (node.y - parentY).toInt(),
                (node.x - parentX + node.width).toInt(),
                (node.y - parentY + node.height).toInt(),
            )
        }

        private fun widgetValueSelected(node: WidgetSemantics): Boolean {
            return node.value != null && node.value >= 0.5f
        }

        private fun sendVirtualEvent(id: Long, type: Int) {
            val event = AccessibilityEvent.obtain(type)
            event.setSource(host, id.toInt())
            event.packageName = packageName
            host.parent?.requestSendAccessibilityEvent(host, event)
        }

        private fun widgetAccessibilityClassName(node: WidgetSemantics): String {
            return when (node.role) {
                WIDGET_ROLE_BUTTON, WIDGET_ROLE_MENUITEM -> "android.widget.Button"
                WIDGET_ROLE_TEXTBOX -> "android.widget.EditText"
                WIDGET_ROLE_CHECKBOX -> "android.widget.CheckBox"
                WIDGET_ROLE_SWITCH -> "android.widget.Switch"
                WIDGET_ROLE_SLIDER -> "android.widget.SeekBar"
                WIDGET_ROLE_PROGRESSBAR -> "android.widget.ProgressBar"
                WIDGET_ROLE_IMAGE -> "android.widget.ImageView"
                WIDGET_ROLE_LIST -> "android.widget.ListView"
                else -> "android.view.View"
            }
        }

        private fun widgetSupportsAction(node: WidgetSemantics, action: Int): Boolean {
            return (node.actions and action) != 0
        }

        private fun widgetSupportsAnyAction(node: WidgetSemantics, actions: Int): Boolean {
            return (node.actions and actions) != 0
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        System.loadLibrary("zero_native_example")

        widgetSurface = WidgetSurfaceView()
        widgetSurface.holder.addCallback(this)

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(245, 246, 248))
            setPadding(32, 28, 32, 24)
        }
        val title = TextView(this).apply {
            text = "Mobile Shell"
            textSize = 24f
            setTextColor(Color.rgb(24, 24, 27))
        }
        val subtitle = TextView(this).apply {
            text = "Native header with WebView workspace"
            textSize = 14f
            setTextColor(Color.rgb(95, 102, 114))
            setPadding(0, 6, 0, 0)
        }
        statusLabel = TextView(this).apply {
            text = "Native commands ready"
            textSize = 13f
            setTextColor(Color.rgb(95, 102, 114))
            setPadding(0, 12, 0, 0)
        }
        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, 12, 0, 0)
        }
        val back = Button(this).apply {
            text = "Back"
            setOnClickListener {
                dispatchNativeCommand("mobile.back")
            }
        }
        val refresh = Button(this).apply {
            text = "Refresh"
            setOnClickListener {
                dispatchNativeCommand("mobile.refresh")
            }
        }
        actions.addView(back, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        actions.addView(refresh, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        header.addView(title)
        header.addView(subtitle)
        header.addView(statusLabel)
        header.addView(actions)

        val webView = WebView(this).apply {
            settings.javaScriptEnabled = false
            loadDataWithBaseURL(null, html, "text/html", "UTF-8", null)
        }

        val content = FrameLayout(this)
        content.addView(widgetSurface, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
        ))
        content.addView(webView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
        ))

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
        }
        root.addView(header, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ))
        root.addView(content, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            0,
            1f,
        ))
        setContentView(root)

        nativeApp = nativeCreate()
        nativeStart(nativeApp)
        refreshWidgetSemanticsStatus()
    }

    private fun dispatchNativeCommand(command: String) {
        if (nativeApp == 0L) return
        val count = nativeCommand(nativeApp, command)
        if (::statusLabel.isInitialized) {
            statusLabel.text = "Command $count: $command"
        }
        nativeFrame(nativeApp)
        refreshWidgetSemanticsStatus()
    }

    override fun onResume() {
        super.onResume()
        if (nativeApp != 0L) {
            nativeActivate(nativeApp)
        }
    }

    override fun onPause() {
        if (nativeApp != 0L) {
            nativeDeactivate(nativeApp)
        }
        super.onPause()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        currentSurfaceHolder = holder
        sendViewport(width, height, holder.surface)
        nativeFrame(nativeApp)
        refreshWidgetSemanticsStatus()
    }

    override fun surfaceCreated(holder: SurfaceHolder) = Unit

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        if (currentSurfaceHolder == holder) currentSurfaceHolder = null
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (nativeApp != 0L) {
            nativeFrame(nativeApp)
            refreshWidgetSemanticsStatus()
        }
    }

    private fun widgetSemanticsSnapshot(): List<WidgetSemantics> {
        if (nativeApp == 0L) return emptyList()
        val count = nativeWidgetSemanticsCount(nativeApp)
        val items = mutableListOf<WidgetSemantics>()
        for (index in 0 until count) {
            widgetSemanticsAt(index)?.let { items.add(it) }
        }
        return items
    }

    private fun widgetSemanticsAt(index: Int): WidgetSemantics? {
        val ids = LongArray(12)
        val ints = IntArray(5)
        val floats = FloatArray(8)
        if (!nativeWidgetSemanticsFields(nativeApp, index, ids, ints, floats)) return null
        return WidgetSemantics(
            id = ids[0],
            parentId = ids[1],
            role = ints[0],
            flags = ints[1],
            actions = ints[2],
            x = floats[0],
            y = floats[1],
            width = floats[2],
            height = floats[3],
            value = if (ints[3] != 0) floats[4] else null,
            label = String(nativeWidgetSemanticsLabel(nativeApp, index), Charsets.UTF_8),
            text = String(nativeWidgetSemanticsText(nativeApp, index), Charsets.UTF_8),
            textSelectionStart = ids[2],
            textSelectionEnd = ids[3],
            textCompositionStart = ids[4],
            textCompositionEnd = ids[5],
            gridRowIndex = ids[6],
            gridColumnIndex = ids[7],
            gridRowCount = ids[8],
            gridColumnCount = ids[9],
            listItemIndex = ids[10],
            listItemCount = ids[11],
            scrollOffset = floats[5],
            scrollViewportExtent = floats[6],
            scrollContentExtent = floats[7],
            hasScroll = ints[4] != 0,
        )
    }

    private fun widgetTextGeometry(id: Long): WidgetTextGeometry? {
        val ints = IntArray(5)
        val floats = FloatArray(12)
        if (!nativeWidgetTextGeometry(nativeApp, id, ints, floats)) return null
        return WidgetTextGeometry(
            id = id,
            hasCaretBounds = ints[0] != 0,
            caretX = floats[0],
            caretY = floats[1],
            caretWidth = floats[2],
            caretHeight = floats[3],
            hasSelectionBounds = ints[1] != 0,
            selectionX = floats[4],
            selectionY = floats[5],
            selectionWidth = floats[6],
            selectionHeight = floats[7],
            selectionRectCount = ints[2],
            hasCompositionBounds = ints[3] != 0,
            compositionX = floats[8],
            compositionY = floats[9],
            compositionWidth = floats[10],
            compositionHeight = floats[11],
            compositionRectCount = ints[4],
        )
    }

    private fun dispatchWidgetAction(
        id: Long,
        action: Int,
        text: String? = null,
        selectionAnchor: Long = 0,
        selectionFocus: Long = 0,
        hasSelection: Boolean = false,
    ): Boolean {
        if (nativeApp == 0L) return false
        val ok = nativeWidgetAction(nativeApp, id, action, text, selectionAnchor, selectionFocus, hasSelection)
        if (ok) {
            nativeFrame(nativeApp)
            refreshWidgetSemanticsStatus()
        }
        return ok
    }

    private fun refreshWidgetSemanticsStatus() {
        if (nativeApp == 0L || !::statusLabel.isInitialized) return
        statusLabel.contentDescription = "Accessible items: ${widgetSemanticsSnapshot().size}"
        if (::widgetSurface.isInitialized) widgetSurface.notifyWidgetSemanticsChanged()
    }

    private fun sendViewport(width: Int, height: Int, surface: Any) {
        if (nativeApp == 0L) return
        val density = resources.displayMetrics.density
        val insets = window.decorView.rootWindowInsets
        val safeTop = ((insets?.systemWindowInsetTop ?: 0).toFloat()) / density
        val safeRight = ((insets?.systemWindowInsetRight ?: 0).toFloat()) / density
        val safeBottom = ((insets?.systemWindowInsetBottom ?: 0).toFloat()) / density
        val safeLeft = ((insets?.systemWindowInsetLeft ?: 0).toFloat()) / density
        nativeViewport(
            nativeApp,
            width.toFloat(),
            height.toFloat(),
            density,
            surface,
            safeTop,
            safeRight,
            safeBottom,
            safeLeft,
            0f,
            0f,
            keyboardBottomInset(density),
            0f,
        )
    }

    private fun keyboardBottomInset(density: Float): Float {
        val visibleFrame = Rect()
        window.decorView.getWindowVisibleDisplayFrame(visibleFrame)
        val hiddenBottom = (window.decorView.rootView.height - visibleFrame.bottom).coerceAtLeast(0)
        return if (hiddenBottom > (100 * density).toInt()) hiddenBottom.toFloat() / density else 0f
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        nativeTouch(nativeApp, event.getPointerId(0).toLong(), event.actionMasked, event.x, event.y, event.pressure)
        nativeFrame(nativeApp)
        return true
    }

    override fun onBackPressed() {
        if (nativeApp != 0L) {
            dispatchNativeCommand("mobile.back")
            return
        }
        super.onBackPressed()
    }

    override fun onDestroy() {
        if (nativeApp != 0L) {
            nativeStop(nativeApp)
            nativeDestroy(nativeApp)
            nativeApp = 0
        }
        super.onDestroy()
    }

    external fun nativeCreate(): Long
    external fun nativeDestroy(app: Long)
    external fun nativeStart(app: Long)
    external fun nativeActivate(app: Long)
    external fun nativeDeactivate(app: Long)
    external fun nativeStop(app: Long)
    external fun nativeResize(app: Long, width: Float, height: Float, scale: Float, surface: Any)
    external fun nativeViewport(app: Long, width: Float, height: Float, scale: Float, surface: Any, safeTop: Float, safeRight: Float, safeBottom: Float, safeLeft: Float, keyboardTop: Float, keyboardRight: Float, keyboardBottom: Float, keyboardLeft: Float)
    external fun nativeTouch(app: Long, id: Long, phase: Int, x: Float, y: Float, pressure: Float)
    external fun nativeKey(app: Long, phase: Int, key: String, text: String, modifiers: Int)
    external fun nativeText(app: Long, text: String)
    external fun nativeIme(app: Long, kind: Int, text: String, cursor: Long)
    external fun nativeCommand(app: Long, command: String): Int
    external fun nativeFrame(app: Long)
    external fun nativeWidgetSemanticsCount(app: Long): Int
    external fun nativeWidgetSemanticsFields(app: Long, index: Int, ids: LongArray, ints: IntArray, floats: FloatArray): Boolean
    external fun nativeWidgetSemanticsLabel(app: Long, index: Int): ByteArray
    external fun nativeWidgetSemanticsText(app: Long, index: Int): ByteArray
    external fun nativeWidgetTextGeometry(app: Long, id: Long, ints: IntArray, floats: FloatArray): Boolean
    external fun nativeWidgetAction(app: Long, id: Long, action: Int, text: String?, selectionAnchor: Long, selectionFocus: Long, hasSelection: Boolean): Boolean

    companion object {
        private const val WIDGET_ROLE_BUTTON = 4
        private const val WIDGET_ROLE_TEXTBOX = 5
        private const val WIDGET_ROLE_MENUITEM = 9
        private const val WIDGET_ROLE_LIST = 10
        private const val WIDGET_ROLE_LISTITEM = 11
        private const val WIDGET_ROLE_GRID = 13
        private const val WIDGET_ROLE_IMAGE = 3
        private const val WIDGET_ROLE_CHECKBOX = 16
        private const val WIDGET_ROLE_SWITCH = 17
        private const val WIDGET_ROLE_SLIDER = 18
        private const val WIDGET_ROLE_PROGRESSBAR = 19
        private const val WIDGET_FLAG_FOCUSED = 1 shl 0
        private const val WIDGET_FLAG_SELECTED = 1 shl 3
        private const val WIDGET_FLAG_DISABLED = 1 shl 4
        private const val WIDGET_FLAG_FOCUSABLE = 1 shl 5
        private const val WIDGET_ACTION_FOCUS = 1 shl 0
        private const val WIDGET_ACTION_PRESS = 1 shl 1
        private const val WIDGET_ACTION_TOGGLE = 1 shl 2
        private const val WIDGET_ACTION_INCREMENT = 1 shl 3
        private const val WIDGET_ACTION_DECREMENT = 1 shl 4
        private const val WIDGET_ACTION_SET_TEXT = 1 shl 5
        private const val WIDGET_ACTION_SET_SELECTION = 1 shl 6
        private const val WIDGET_ACTION_SELECT = 1 shl 7
        private const val WIDGET_ACTION_KIND_FOCUS = 0
        private const val WIDGET_ACTION_KIND_PRESS = 1
        private const val WIDGET_ACTION_KIND_TOGGLE = 2
        private const val WIDGET_ACTION_KIND_INCREMENT = 3
        private const val WIDGET_ACTION_KIND_DECREMENT = 4
        private const val WIDGET_ACTION_KIND_SET_TEXT = 5
        private const val WIDGET_ACTION_KIND_SET_SELECTION = 6
        private const val WIDGET_ACTION_KIND_SELECT = 10
        private const val html = """
            <!doctype html>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <body style="margin:0;font-family:system-ui,sans-serif;background:#f7f8fa;color:#18181b">
              <main style="padding:28px 22px;display:grid;gap:16px">
                <h1 style="margin:0;font-size:30px">Workspace</h1>
                <p style="margin:0;color:#5f6672;line-height:1.5">This content is rendered by Android WebView while the header remains native Android UI.</p>
                <section style="display:grid;gap:10px">
                  <div style="padding:14px;border:1px solid #e1e5ea;border-radius:8px;background:white">Inbox review</div>
                  <div style="padding:14px;border:1px solid #e1e5ea;border-radius:8px;background:white">Sync queue</div>
                  <div style="padding:14px;border:1px solid #e1e5ea;border-radius:8px;background:white">Offline cache</div>
                </section>
              </main>
            </body>
        """
    }
}
