import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "discord-voice"

    property var popoutService: null

    // --- Bridge state ---
    property bool bridgeReady: false
    property bool authenticated: false
    property string authError: ""
    property string selfId: ""

    // --- Voice state ---
    property var currentChannel: null
    property var voiceUsers: []
    property var voiceSettings: ({mute: false, deaf: false})
    property var speakingUsers: ({})

    // --- Settings ---
    readonly property string clientId: "207646673902501888"
    readonly property int maxBarAvatars: parseInt(pluginData.maxBarAvatars) || 5

    // On DMS >= 1.5 the daemon surface owns the bridge process and the IPC
    // handler (it survives bar reloads on monitor sleep/wake; a per-widget
    // IpcHandler leaves a stale "discord" target behind when its bar window
    // is destroyed). On older DMS without composite plugin support this is
    // false and the widget self-hosts both, as before.
    readonly property bool daemonMode: !!(pluginService
        && pluginService.pluginDaemonComponents
        && pluginService.pluginDaemonComponents["discordVoice"])

    // --- Computed ---
    readonly property bool inVoice: currentChannel !== null && currentChannel !== undefined
    readonly property bool isMuted: voiceSettings.mute || false
    readonly property bool isDeafened: voiceSettings.deaf || false

    // --- Socket path ---
    readonly property string bridgeSocketPath: {
        const runtime = Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
        return runtime + "/dms-discord-voice.sock"
    }

    // --- Helpers (accessible from popout via root.xxx) ---
    function avatarUrl(userId, avatarHash) {
        if (!avatarHash) return ""
        return "https://cdn.discordapp.com/avatars/" + userId + "/" + avatarHash + ".png?size=64"
    }

    // Never log OAuth tokens: on systemd setups console output lands in
    // the journal, where any journal reader could lift a live token.
    function redactForLog(msg) {
        if (!msg || typeof msg !== "object") return JSON.stringify(msg)
        const copy = Object.assign({}, msg)
        for (const key of ["token", "access_token"]) {
            if (copy[key]) copy[key] = "<redacted>"
        }
        return JSON.stringify(copy)
    }

    function sendBridgeCommand(cmd) {
        console.warn("DiscordVoice: sendBridgeCommand", redactForLog(cmd))
        bridgeSocket.send(cmd)
    }

    // A drag emits a move event per pixel; sending each one would flood the
    // bridge and Discord's rate limiter. Coalesce to the latest value per
    // user and flush on a timer, with a guaranteed final send on release so
    // the value the user let go on is always the one that lands.
    property var _pendingVol: ({})

    Timer {
        id: volThrottle
        interval: 80
        repeat: false
        onTriggered: {
            for (var uid in root._pendingVol)
                root.sendBridgeCommand({cmd: "set_user_voice_settings",
                                        user_id: uid, volume: root._pendingVol[uid]})
            root._pendingVol = {}
        }
    }

    function queueUserVolume(uid, v) {
        root._pendingVol[uid] = v
        if (!volThrottle.running) volThrottle.start()
    }

    function sendUserVolume(uid, v) {
        volThrottle.stop()
        root._pendingVol = {}
        root.sendBridgeCommand({cmd: "set_user_voice_settings", user_id: uid, volume: v})
    }

    function setUserMute(uid, muted) {
        root.sendBridgeCommand({cmd: "set_user_voice_settings", user_id: uid, mute: muted})
    }

    // --- Visibility ---
    // Show the pill when in a voice call (participants), or when not
    // authenticated (login placeholder so the popout is reachable).
    // Hide only in the steady state: authenticated + idle.
    function updateVisibility() {
        if (inVoice || !authenticated) {
            clearVisibilityOverride()
        } else {
            setVisibilityOverride(false)
        }
    }

    Component.onCompleted: updateVisibility()
    onInVoiceChanged: updateVisibility()
    onAuthenticatedChanged: updateVisibility()

    // =====================================================================
    // Bridge process
    // =====================================================================

    Process {
        id: bridgeProcess
        command: ["python3", Qt.resolvedUrl("discord_bridge.py").toString().replace("file://", ""), root.bridgeSocketPath, root.clientId]
        running: false

        stderr: StdioCollector {
            onStreamFinished: {
                if (text && text.trim()) {
                    console.warn("DiscordVoice bridge:", text.trim())
                }
            }
        }

        onExited: (exitCode) => {
            // Exit 0 means another bridge instance already owns the socket;
            // just keep using it as a client.
            if (exitCode === 0) return
            console.warn("DiscordVoice bridge exited:", exitCode)
            root.bridgeReady = false
            root.authenticated = false
            root.currentChannel = null
            root.voiceUsers = []
            bridgeRestartTimer.start()
        }
    }

    // Start bridge after a short delay so the socket path is ready
    // before DankSocket tries to connect. In daemon mode the daemon
    // surface owns the process instead.
    Timer {
        id: bridgeStartTimer
        interval: 100
        running: true
        onTriggered: {
            if (!root.daemonMode) {
                bridgeProcess.running = true
            }
        }
    }

    Timer {
        id: bridgeRestartTimer
        interval: 3000
        onTriggered: bridgeProcess.running = true
    }

    // Legacy-mode watchdog: if the widget instance that owned the bridge
    // process was destroyed (bar reload on monitor sleep/wake), surviving
    // instances bring the bridge back up. Safe against races - extra
    // bridge processes exit immediately when the socket is already owned.
    Timer {
        interval: 5000
        repeat: true
        running: !root.daemonMode
        onTriggered: {
            if (!bridgeSocket.linkUp && !bridgeProcess.running) {
                bridgeProcess.running = true
            }
        }
    }

    // =====================================================================
    // DankSocket connection to bridge
    // =====================================================================

    DankSocket {
        id: bridgeSocket
        path: root.bridgeSocketPath
        // Don't connect until bridge has had time to start.
        connected: false

        parser: SplitParser {
            onRead: message => {
                if (!message || message.length === 0) return
                try {
                    const msg = JSON.parse(message)
                    root.handleBridgeMessage(msg)
                } catch (e) {
                    console.warn("DiscordVoice: parse error:", e)
                }
            }
        }
    }

    // Connect socket after the bridge (ours or the daemon's) has had time
    // to create its socket file. DankSocket retries with backoff until the
    // bridge is up, so a fixed delay is safe in both modes.
    Timer {
        id: socketConnectTimer
        interval: 800
        running: true
        onTriggered: {
            console.warn("DiscordVoice: connecting socket to bridge")
            bridgeSocket.connected = true
        }
    }

    // =====================================================================
    // Message handler
    // =====================================================================

    function handleBridgeMessage(msg) {
        console.warn("DiscordVoice: bridge msg:", redactForLog(msg))
        switch (msg.type) {
        case "ready":
            bridgeReady = true
            bridgeSocket.send({cmd: "connect"})
            break

        case "auth_required":
            authenticated = false
            authError = ""
            break

        case "auth_complete":
            authenticated = true
            authError = ""
            if (msg.user && msg.user.id) selfId = msg.user.id
            break

        case "auth_error":
            authError = msg.error || "Authentication failed"
            authenticated = false
            break

        case "voice_channel":
            currentChannel = msg.channel || null
            if (!msg.channel) {
                voiceUsers = []
                speakingUsers = {}
            }
            break

        case "voice_state":
            voiceUsers = msg.users || []
            break

        case "speaking":
            let updated = Object.assign({}, speakingUsers)
            updated[msg.user_id] = msg.speaking
            speakingUsers = updated
            break

        case "voice_settings":
            voiceSettings = {
                mute: msg.mute || false,
                deaf: msg.deaf || false
            }
            break

        case "disconnected":
            authenticated = false
            currentChannel = null
            voiceUsers = []
            speakingUsers = {}
            break

        case "error":
            console.warn("DiscordVoice bridge error:", msg.error)
            break
        }
    }

    // =====================================================================
    // IPC Handler (for keybinds: dms ipc call discord ...)
    // Legacy mode only - in daemon mode the daemon surface registers it,
    // since a handler tied to a bar widget goes stale when bar windows are
    // recreated on monitor sleep/wake.
    // =====================================================================

    Loader {
        active: !root.daemonMode

        sourceComponent: IpcHandler {
            target: "discord"

            function toggleMute(): string {
                root.sendBridgeCommand({cmd: "set_voice_settings", mute: !root.isMuted})
                return root.isMuted ? "UNMUTED" : "MUTED"
            }

            function toggleDeafen(): string {
                root.sendBridgeCommand({cmd: "set_voice_settings", deaf: !root.isDeafened})
                return root.isDeafened ? "UNDEAFENED" : "DEAFENED"
            }

            function muteOn(): string {
                root.sendBridgeCommand({cmd: "set_voice_settings", mute: true})
                return "MUTE_ON"
            }

            function muteOff(): string {
                root.sendBridgeCommand({cmd: "set_voice_settings", mute: false})
                return "MUTE_OFF"
            }

            function deafenOn(): string {
                root.sendBridgeCommand({cmd: "set_voice_settings", deaf: true})
                return "DEAFEN_ON"
            }

            function deafenOff(): string {
                root.sendBridgeCommand({cmd: "set_voice_settings", deaf: false})
                return "DEAFEN_OFF"
            }

            function status(): string {
                if (!root.authenticated) return "NOT_AUTHENTICATED"
                if (!root.inVoice) return "NOT_IN_VOICE"
                return JSON.stringify({
                    channel: root.currentChannel ? root.currentChannel.name : "",
                    users: root.voiceUsers.length,
                    muted: root.isMuted,
                    deafened: root.isDeafened
                })
            }
        }
    }

    // =====================================================================
    // Bar pills
    // =====================================================================

    horizontalBarPill: Component {
        Row {
            spacing: -4

            DankIcon {
                visible: !root.authenticated
                anchors.verticalCenter: parent.verticalCenter
                name: "headset_mic"
                size: Math.min(root.widgetThickness, 18)
                color: root.authError ? Theme.error : Theme.surfaceVariantText
            }

            Repeater {
                model: {
                    if (!root.inVoice) return []
                    const users = root.voiceUsers
                    return users.length > root.maxBarAvatars
                        ? users.slice(0, root.maxBarAvatars)
                        : users
                }

                Item {
                    width: root.widgetThickness
                    height: root.widgetThickness
                    anchors.verticalCenter: parent.verticalCenter

                    // Speaking / mute ring
                    Rectangle {
                        id: avatarRing
                        anchors.fill: parent
                        radius: width / 2
                        color: "transparent"
                        border.width: 2
                        border.color: {
                            const isMuted = modelData.self_mute || modelData.mute
                            const isDeaf = modelData.self_deaf || modelData.deaf
                            const isSpeaking = root.speakingUsers[modelData.id] === true

                            if (isDeaf || isMuted) return Theme.error
                            if (isSpeaking) return Theme.success || "#4CAF50"
                            return "transparent"
                        }

                        Behavior on border.color {
                            DankColorAnim {
                                duration: Theme.shorterDuration
                            }
                        }
                    }

                    // Avatar image
                    DankCircularImage {
                        anchors.fill: parent
                        anchors.margins: 2
                        imageSource: root.avatarUrl(modelData.id, modelData.avatar)
                        fallbackText: modelData.username ? modelData.username.charAt(0).toUpperCase() : "?"
                        fallbackIcon: ""
                    }

                    // Mute/deafen badge
                    Rectangle {
                        visible: modelData.self_mute || modelData.mute || modelData.self_deaf || modelData.deaf
                        width: Math.max(10, root.widgetThickness * 0.35)
                        height: width
                        radius: width / 2
                        color: Theme.error
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right

                        DankIcon {
                            anchors.centerIn: parent
                            name: (modelData.self_deaf || modelData.deaf) ? "headset_off" : "mic_off"
                            size: parent.width - 2
                            color: Theme.onError || "white"
                        }
                    }
                }
            }

            // Overflow count
            StyledText {
                visible: root.inVoice && root.voiceUsers.length > root.maxBarAvatars
                text: "+" + (root.voiceUsers.length - root.maxBarAvatars)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.widgetTextColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: -4

            DankIcon {
                visible: !root.authenticated
                anchors.horizontalCenter: parent.horizontalCenter
                name: "headset_mic"
                size: Math.min(root.widgetThickness, 18)
                color: root.authError ? Theme.error : Theme.surfaceVariantText
            }

            Repeater {
                model: {
                    if (!root.inVoice) return []
                    const users = root.voiceUsers
                    return users.length > root.maxBarAvatars
                        ? users.slice(0, root.maxBarAvatars)
                        : users
                }

                Item {
                    width: root.widgetThickness
                    height: root.widgetThickness
                    anchors.horizontalCenter: parent.horizontalCenter

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: "transparent"
                        border.width: 2
                        border.color: {
                            const isMuted = modelData.self_mute || modelData.mute
                            const isDeaf = modelData.self_deaf || modelData.deaf
                            const isSpeaking = root.speakingUsers[modelData.id] === true

                            if (isDeaf || isMuted) return Theme.error
                            if (isSpeaking) return Theme.success || "#4CAF50"
                            return "transparent"
                        }

                        Behavior on border.color {
                            DankColorAnim {
                                duration: Theme.shorterDuration
                            }
                        }
                    }

                    DankCircularImage {
                        anchors.fill: parent
                        anchors.margins: 2
                        imageSource: root.avatarUrl(modelData.id, modelData.avatar)
                        fallbackText: modelData.username ? modelData.username.charAt(0).toUpperCase() : "?"
                        fallbackIcon: ""
                    }

                    Rectangle {
                        visible: modelData.self_mute || modelData.mute || modelData.self_deaf || modelData.deaf
                        width: Math.max(10, root.widgetThickness * 0.35)
                        height: width
                        radius: width / 2
                        color: Theme.error
                        anchors.bottom: parent.bottom
                        anchors.right: parent.right

                        DankIcon {
                            anchors.centerIn: parent
                            name: (modelData.self_deaf || modelData.deaf) ? "headset_off" : "mic_off"
                            size: parent.width - 2
                            color: Theme.onError || "white"
                        }
                    }
                }
            }

            StyledText {
                visible: root.inVoice && root.voiceUsers.length > root.maxBarAvatars
                text: "+" + (root.voiceUsers.length - root.maxBarAvatars)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.widgetTextColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // =====================================================================
    // Popout
    // =====================================================================

    popoutWidth: 320
    popoutHeight: 400

    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: root.inVoice ? (root.currentChannel ? root.currentChannel.name : "Voice Channel") : "Discord Call Overlay"
            showCloseButton: false

            Column {
                width: parent.width
                spacing: Theme.spacingM

                // --- Not authenticated ---
                Column {
                    visible: !root.authenticated
                    width: parent.width
                    spacing: Theme.spacingM

                    DankIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: "link"
                        size: 48
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        width: parent.width
                        text: root.authError
                              ? root.authError
                              : "Connect to Discord to see voice channel participants and control mute/deafen."
                        color: root.authError ? Theme.error : Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeMedium
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: authRow.width + Theme.spacingL * 2
                        height: authRow.height + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.primary

                        Row {
                            id: authRow
                            anchors.centerIn: parent
                            spacing: Theme.spacingS

                            DankIcon {
                                name: "login"
                                size: Theme.fontSizeMedium
                                color: Theme.onPrimary || "white"
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            StyledText {
                                text: "Authorize Discord"
                                color: Theme.onPrimary || "white"
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                console.warn("DiscordVoice: authorize button clicked")
                                root.sendBridgeCommand({cmd: "authorize"})
                            }
                        }
                    }
                }

                // --- Authenticated, in voice ---
                Column {
                    visible: root.authenticated && root.inVoice
                    width: parent.width
                    spacing: Theme.spacingS

                    // Participant list
                    Repeater {
                        model: ScriptModel {
                            objectProp: "id"
                            values: root.voiceUsers
                        }

                        Rectangle {
                            id: pRow

                            property bool isSelf: modelData.id === root.selfId
                            property bool dragging: false
                            property bool showFill: false
                            property int dragVol: 100
                            readonly property int displayVol:
                                dragging ? dragVol
                                         : (modelData.volume === undefined ? 100 : modelData.volume)
                            readonly property bool micOff:
                                isSelf ? root.isMuted : (modelData.self_mute || modelData.mute)
                            readonly property bool headOff:
                                isSelf ? root.isDeafened : (modelData.self_deaf || modelData.deaf)

                            width: parent.width
                            height: 44
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh
                            clip: true

                            Timer {
                                id: fillRelease
                                interval: 600
                                onTriggered: pRow.showFill = false
                            }

                            Rectangle {
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: parent.width * (pRow.displayVol / 200)
                                radius: Theme.cornerRadius
                                color: Theme.withAlpha(Theme.success, 0.25)
                                opacity: pRow.showFill ? 1.0 : 0.0
                                visible: opacity > 0

                                Behavior on opacity {
                                    NumberAnimation { duration: Theme.mediumDuration }
                                }
                            }

                            Rectangle {
                                width: 1
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                x: parent.width * 0.5
                                color: Theme.outlineMedium
                                opacity: pRow.showFill ? 1.0 : 0.0
                                visible: opacity > 0

                                Behavior on opacity {
                                    NumberAnimation { duration: Theme.mediumDuration }
                                }
                            }

                            // Declared before the content Row on purpose: the
                            // mute and reset icons carry their own MouseAreas
                            // and must layer above this one to win their hit
                            // regions. preventStealing keeps the popout's
                            // Flickable from grabbing the horizontal drag.
                            MouseArea {
                                id: dragArea
                                anchors.fill: parent
                                enabled: !pRow.isSelf
                                preventStealing: true
                                property real startX: 0
                                onPressed: (mouse) => { startX = mouse.x }
                                onPositionChanged: (mouse) => {
                                    if (!pRow.dragging && Math.abs(mouse.x - startX) > 4) {
                                        fillRelease.stop()
                                        pRow.showFill = true
                                        pRow.dragging = true
                                    }
                                    if (pRow.dragging) {
                                        var frac = Math.max(0, Math.min(1, mouse.x / pRow.width))
                                        var v = Math.round(frac * 200)
                                        if (Math.abs(v - 100) <= 6) v = 100
                                        pRow.dragVol = v
                                        root.queueUserVolume(modelData.id, v)
                                    }
                                }
                                onReleased: {
                                    if (pRow.dragging) {
                                        root.sendUserVolume(modelData.id, pRow.dragVol)
                                        pRow.dragging = false
                                        fillRelease.restart()
                                    }
                                }
                                onCanceled: {
                                    pRow.dragging = false
                                    fillRelease.restart()
                                }
                            }

                            Row {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingS

                                // Hovering another participant's avatar reveals
                                // their local-mute toggle: the same slot
                                // overlay the volumeMixer plugin uses for
                                // reset-to-100%. Staying visible while muted
                                // keeps the state readable without a hover.
                                Item {
                                    id: avatarSlot
                                    width: 32
                                    height: 32
                                    anchors.verticalCenter: parent.verticalCenter

                                    property bool hovering: false
                                    readonly property bool showMute:
                                        !pRow.isSelf
                                        && (hovering || modelData.local_mute === true)

                                    Timer {
                                        id: hoverRelease
                                        interval: 450
                                        onTriggered: avatarSlot.hovering = false
                                    }

                                    DankCircularImage {
                                        anchors.fill: parent
                                        imageSource: root.avatarUrl(modelData.id, modelData.avatar)
                                        fallbackText: modelData.username ? modelData.username.charAt(0).toUpperCase() : "?"
                                        fallbackIcon: ""
                                        border.width: root.speakingUsers[modelData.id] === true ? 2 : 0
                                        border.color: Theme.success
                                        opacity: avatarSlot.showMute ? 0.15 : 1.0

                                        Behavior on opacity {
                                            NumberAnimation { duration: Theme.shortDuration }
                                        }
                                    }

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: width / 2
                                        opacity: avatarSlot.showMute ? 1.0 : 0.0
                                        visible: opacity > 0
                                        color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.85)

                                        Behavior on opacity {
                                            NumberAnimation { duration: Theme.shortDuration }
                                        }

                                        DankIcon {
                                            anchors.centerIn: parent
                                            name: modelData.local_mute ? "volume_off" : "volume_up"
                                            size: 18
                                            color: modelData.local_mute ? Theme.error : Theme.primary
                                        }
                                    }

                                    MouseArea {
                                        id: muteArea
                                        anchors.fill: parent
                                        anchors.margins: -Theme.spacingXS
                                        enabled: !pRow.isSelf
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onEntered: {
                                            hoverRelease.stop()
                                            avatarSlot.hovering = true
                                        }
                                        onExited: hoverRelease.restart()
                                        onClicked: root.setUserMute(modelData.id, !modelData.local_mute)
                                    }
                                }

                                StyledText {
                                    text: modelData.nick || modelData.username || "Unknown"
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    width: parent.width - 32 - statusRow.width - Theme.spacingS * 3
                                }

                                Row {
                                    id: statusRow
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 2

                                    DankIcon {
                                        visible: !pRow.isSelf && pRow.displayVol !== 100
                                        name: "replay"
                                        size: 16
                                        color: Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.sendUserVolume(modelData.id, 100)
                                        }
                                    }
                                    StyledText {
                                        visible: !pRow.isSelf
                                        text: pRow.displayVol + "%"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    DankIcon {
                                        visible: pRow.isSelf || pRow.micOff
                                        name: pRow.micOff ? "mic_off" : "mic"
                                        size: 16
                                        color: pRow.micOff ? Theme.error : Theme.surfaceVariantText

                                        MouseArea {
                                            anchors.fill: parent
                                            enabled: pRow.isSelf
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.sendBridgeCommand({cmd: "set_voice_settings",
                                                                               mute: !root.isMuted})
                                        }
                                    }
                                    DankIcon {
                                        visible: pRow.isSelf || pRow.headOff
                                        name: pRow.headOff ? "headset_off" : "headset"
                                        size: 16
                                        color: pRow.headOff ? Theme.error : Theme.surfaceVariantText

                                        MouseArea {
                                            anchors.fill: parent
                                            enabled: pRow.isSelf
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.sendBridgeCommand({cmd: "set_voice_settings",
                                                                               deaf: !root.isDeafened})
                                        }
                                    }
                                    // Same glyph Discord uses, tinted amber to
                                    // separate "no permission to speak here"
                                    // from the red self/server mute.
                                    DankIcon {
                                        visible: modelData.suppress === true && !pRow.micOff
                                        name: "mic_off"
                                        size: 16
                                        color: Theme.warning
                                    }
                                }
                            }
                        }
                    }
                }

                // --- Authenticated, not in voice ---
                Column {
                    visible: root.authenticated && !root.inVoice
                    width: parent.width
                    spacing: Theme.spacingS

                    StyledText {
                        width: parent.width
                        text: "No active Discord call found"
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeMedium
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
        }
    }
}
