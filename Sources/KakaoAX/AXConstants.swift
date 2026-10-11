// Derived from kmsg (https://github.com/channprj/kmsg) @54cbff7 — MIT License, Copyright (c) 2026 Park Hee Chan. Modifications: role constants moved into an `AXRole` namespace (avoids clashing with ApplicationServices globals); added attribute and notification name namespaces; no action names.
// SPDX-License-Identifier: MIT
//
// String values of the accessibility roles, attributes and notifications that TalkLens reads.
// Only read-side names live here: no action names are defined on purpose (read-only design, see README "What it never does").

import Foundation

public enum AXRole {
    public static let staticText = "AXStaticText"
    public static let textField = "AXTextField"
    public static let textArea = "AXTextArea"
    public static let button = "AXButton"
    public static let table = "AXTable"
    public static let row = "AXRow"
    public static let cell = "AXCell"
    public static let list = "AXList"
    public static let outline = "AXOutline"
    public static let group = "AXGroup"
    public static let scrollArea = "AXScrollArea"
    public static let window = "AXWindow"
    public static let sheet = "AXSheet"
    public static let application = "AXApplication"
    public static let image = "AXImage"
    public static let toolbar = "AXToolbar"
    public static let menu = "AXMenu"
    public static let menuItem = "AXMenuItem"
    public static let popUpButton = "AXPopUpButton"
    public static let checkBox = "AXCheckBox"
    public static let radioButton = "AXRadioButton"
    public static let tabGroup = "AXTabGroup"
    public static let splitGroup = "AXSplitGroup"
    public static let scrollBar = "AXScrollBar"
    public static let webArea = "AXWebArea"
    public static let link = "AXLink"
    public static let column = "AXColumn"
}

public enum AXAttr {
    public static let role = "AXRole"
    public static let subrole = "AXSubrole"
    public static let identifier = "AXIdentifier"
    public static let title = "AXTitle"
    public static let value = "AXValue"
    public static let description = "AXDescription"
    public static let help = "AXHelp"
    public static let position = "AXPosition"
    public static let size = "AXSize"
    public static let enabled = "AXEnabled"
    public static let children = "AXChildren"
    public static let windows = "AXWindows"
    public static let focusedWindow = "AXFocusedWindow"
    public static let mainWindow = "AXMainWindow"
    public static let minimized = "AXMinimized"
    public static let editable = "AXEditable"
}

/// Notification names observed (never posted) by `tlctl watch` and the app's window tracker.
public enum AXNotificationName {
    public static let focusedWindowChanged = "AXFocusedWindowChanged"
    public static let mainWindowChanged = "AXMainWindowChanged"
    public static let windowCreated = "AXWindowCreated"
    public static let moved = "AXMoved"
    public static let resized = "AXResized"
    public static let uiElementDestroyed = "AXUIElementDestroyed"
    public static let titleChanged = "AXTitleChanged"
    public static let windowMiniaturized = "AXWindowMiniaturized"
    public static let windowDeminiaturized = "AXWindowDeminiaturized"
    public static let rowCountChanged = "AXRowCountChanged"
    public static let created = "AXCreated"
    public static let valueChanged = "AXValueChanged"
    public static let layoutChanged = "AXLayoutChanged"
    public static let selectedChildrenChanged = "AXSelectedChildrenChanged"

    public static let application: [String] = [focusedWindowChanged, mainWindowChanged, windowCreated]
    public static let window: [String] = [moved, resized, uiElementDestroyed, titleChanged,
                                          windowMiniaturized, windowDeminiaturized]
    public static let transcript: [String] = [rowCountChanged, created, valueChanged, layoutChanged,
                                              selectedChildrenChanged]

    /// Notifications that may mean the transcript content changed (debounced re-read).
    public static let content: Set<String> = [rowCountChanged, created, valueChanged, layoutChanged,
                                              selectedChildrenChanged, titleChanged, focusedWindowChanged,
                                              mainWindowChanged, windowCreated, uiElementDestroyed,
                                              windowDeminiaturized]
}
