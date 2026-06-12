--[[
    juanita.lua — full UI library (eskolz-style recreation) — Roblox Lua
    Self-contained. Returns the Library table; a demo config is built at the
    bottom of the file (clearly marked — delete it when using as a library).

    Music player: drop .mp3 / .ogg / .wav files into <executor workspace>/slurricane/music
    Menu toggle: RightShift
]]

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local Stats = game:GetService("Stats")

local LP = Players.LocalPlayer

-- service-level connections, disconnected by Library:Unload()
local Connections = {}
local function trackConn(conn)
    table.insert(Connections, conn)
    return conn
end

-- // theme ---------------------------------------------------------------------

local Theme = {
    Background = Color3.fromRGB(9, 9, 9),
    Panel      = Color3.fromRGB(12, 12, 12),
    Element    = Color3.fromRGB(21, 21, 21),
    Border     = Color3.fromRGB(58, 58, 58),
    BorderDark = Color3.fromRGB(32, 32, 32),
    Accent     = Color3.fromRGB(163, 135, 200),
    AccentDark = Color3.fromRGB(95, 75, 120),
    Text       = Color3.fromRGB(205, 205, 205),
    TextDim    = Color3.fromRGB(95, 95, 95),
    White      = Color3.fromRGB(240, 240, 240),
}
local ACCENT_HEX = "a387c8"
local FONT = Enum.Font.Code

-- // helpers -------------------------------------------------------------------

local function New(class, props, children)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        if k ~= "Parent" then inst[k] = v end
    end
    for _, child in ipairs(children or {}) do
        child.Parent = inst
    end
    if props and props.Parent then
        inst.Parent = props.Parent
    end
    return inst
end

local function Stroke(color, thickness)
    return New("UIStroke", {
        Color = color,
        Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })
end

local function tween(inst, props, time, style, dir)
    local t = TweenService:Create(
        inst,
        TweenInfo.new(time or 0.18, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out),
        props
    )
    t:Play()
    return t
end

-- inertia drag: target glides toward the cursor instead of snapping
local function SmoothDrag(handle, target)
    local dragging = false
    local dragStart, startPos, goal
    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = target.Position
            goal = startPos
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    trackConn(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            goal = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end))
    trackConn(RunService.RenderStepped:Connect(function(dt)
        if goal then
            target.Position = target.Position:Lerp(goal, 1 - math.exp(-14 * dt))
        end
    end))
end

local function getGuiParent()
    local ok, hui = pcall(function() return gethui and gethui() end)
    if ok and typeof(hui) == "Instance" then return hui end
    local ok2, core = pcall(function()
        local cg = game:GetService("CoreGui")
        cg:GetChildren()
        return cg
    end)
    if ok2 and core then return core end
    return LP:WaitForChild("PlayerGui")
end

-- // library root ----------------------------------------------------------------

local Library = {
    Windows = {},     -- { win = CanvasGroup, scale = UIScale, hidden = bool }
    Binds = {},       -- KeyCode -> fn
    Visible = true,
    _listening = nil, -- pending keybind capture
    _windowCount = 0,
    _sounds = {},     -- sounds owned by the library (music player)
}

-- override the theme accent (call BEFORE building any UI)
function Library:SetAccent(accent, accentDark)
    Theme.Accent = accent or Theme.Accent
    Theme.AccentDark = accentDark or Theme.AccentDark
    ACCENT_HEX = Theme.Accent:ToHex()
end

local gui = New("ScreenGui", {
    Name = "juanita",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    Parent = getGuiParent(),
})

-- tears down everything the library created: gui, service connections, sounds
function Library:Unload()
    for _, conn in ipairs(Connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(Connections)
    for _, s in ipairs(Library._sounds) do
        pcall(function() s:Stop() s:Destroy() end)
    end
    table.clear(Library._sounds)
    table.clear(Library.Binds)
    pcall(function() gui:Destroy() end)
end

local function showWindow(entry, on, instant)
    if on then
        entry.win.Visible = true
        tween(entry.win, { GroupTransparency = 0 }, instant and 0 or 0.25)
        tween(entry.scale, { Scale = 1 }, instant and 0 or 0.35, Enum.EasingStyle.Back)
    else
        tween(entry.win, { GroupTransparency = 1 }, 0.2)
        tween(entry.scale, { Scale = 0.95 }, 0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        task.delay(0.2, function()
            if entry.win.GroupTransparency > 0.9 then entry.win.Visible = false end
        end)
    end
end

-- every panel (menu, music player, etc.) is a bordered CanvasGroup that fades/pops
local function CreateWindowBase(size, position)
    local win = New("CanvasGroup", {
        Size = size,
        Position = position,
        BackgroundColor3 = Theme.Background,
        BorderSizePixel = 0,
        GroupTransparency = 1,
        Visible = true,
        Parent = gui,
    }, { Stroke(Theme.Border) })
    local scale = New("UIScale", { Scale = 0.95, Parent = win })
    local entry = { win = win, scale = scale, hidden = false }
    table.insert(Library.Windows, entry)
    Library._windowCount += 1
    task.delay(0.08 * Library._windowCount, function()
        if not entry.hidden and Library.Visible then showWindow(entry, true) end
    end)
    return win, entry
end

function Library:Toggle(on)
    if on == nil then on = not Library.Visible end
    Library.Visible = on
    for _, entry in ipairs(Library.Windows) do
        if not entry.hidden then showWindow(entry, on) end
    end
end

-- // global input: keybinds + menu toggle ------------------------------------------

trackConn(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

    -- capture mode for "[–]" keybind tags
    if Library._listening then
        local listen = Library._listening
        Library._listening = nil
        if input.KeyCode == Enum.KeyCode.Backspace or input.KeyCode == Enum.KeyCode.Escape then
            if listen.currentKey then Library.Binds[listen.currentKey()] = nil end
            listen.clear()
        else
            listen.assign(input.KeyCode)
        end
        return
    end

    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        Library:Toggle()
        return
    end
    local bound = Library.Binds[input.KeyCode]
    if bound then bound() end
end))

-- // watermark (same stack as the previous ui, restyled) ----------------------------

function Library:CreateWatermark(opts)
    opts = opts or {}
    local username = (LP and LP.Name) or "samet"
    local labels = {}
    local pillFrames = {}

    local function pill(order, richText)
        local y = 14 + (order - 1) * 34
        local frame = New("Frame", {
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, 320, 0, y),
            Size = UDim2.fromOffset(0, 26),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundColor3 = Theme.Panel,
            BorderSizePixel = 0,
            Parent = gui,
        }, {
            Stroke(Theme.Border),
            New("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
        })
        local label = New("TextLabel", {
            Size = UDim2.new(0, 0, 1, 0),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundTransparency = 1,
            Font = FONT,
            RichText = true,
            Text = richText,
            TextSize = 13,
            TextColor3 = Theme.Text,
            Parent = frame,
        })
        table.insert(pillFrames, frame)
        task.delay(0.1 * order, function()
            tween(frame, { Position = UDim2.new(1, -12, 0, y) }, 0.45, Enum.EasingStyle.Back)
        end)
        return label
    end

    pill(1, opts.Text or ('this is a <font color="#%s">watermark.</font>'):format(ACCENT_HEX))
    labels.fps  = pill(2, "◆  60 fps")
    labels.ping = pill(3, "📶  0 ping")
    pill(4, "👤  logged in as " .. username)

    trackConn(RunService.Heartbeat:Connect(function(dt)
        Library._wmFrames = (Library._wmFrames or 0) + 1
        Library._wmAcc = (Library._wmAcc or 0) + dt
        if Library._wmAcc >= 0.5 then
            labels.fps.Text = ("◆  %d fps"):format(Library._wmFrames / Library._wmAcc + 0.5)
            Library._wmFrames, Library._wmAcc = 0, 0
            local ok, ping = pcall(function()
                return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
            end)
            labels.ping.Text = ("📶  %d ping"):format(ok and ping or 0)
        end
    end))

    return {
        SetVisible = function(on)
            for _, frame in ipairs(pillFrames) do frame.Visible = on end
        end,
    }
end

-- // notifications -------------------------------------------------------------------

local notifContainer = New("Frame", {
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -12, 1, -12),
    Size = UDim2.fromOffset(300, 400),
    BackgroundTransparency = 1,
    Parent = gui,
}, {
    New("UIListLayout", {
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        VerticalAlignment = Enum.VerticalAlignment.Bottom,
    }),
})

function Library:Notify(title, desc, duration)
    duration = duration or 3
    local holder = New("Frame", {
        Size = UDim2.new(1, 0, 0, 52),
        BackgroundTransparency = 1,
        ClipsDescendants = true,
        Parent = notifContainer,
    })
    local card = New("Frame", {
        Size = UDim2.new(1, 0, 1, 0),
        Position = UDim2.new(0, 320, 0, 0),
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        Parent = holder,
    }, {
        Stroke(Theme.Border),
        New("TextLabel", {
            Size = UDim2.new(1, -20, 0, 16),
            Position = UDim2.fromOffset(10, 8),
            BackgroundTransparency = 1,
            Font = FONT,
            Text = title,
            TextSize = 13,
            TextColor3 = Theme.White,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }),
        New("TextLabel", {
            Size = UDim2.new(1, -20, 0, 14),
            Position = UDim2.fromOffset(10, 26),
            BackgroundTransparency = 1,
            Font = FONT,
            Text = desc or "",
            TextSize = 12,
            TextColor3 = Theme.TextDim,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }),
    })
    local progress = New("Frame", {
        Size = UDim2.new(1, 0, 0, 2),
        Position = UDim2.new(0, 0, 1, -2),
        BackgroundColor3 = Theme.Accent,
        BorderSizePixel = 0,
        Parent = card,
    })

    tween(card, { Position = UDim2.new(0, 0, 0, 0) }, 0.35, Enum.EasingStyle.Back)
    tween(progress, { Size = UDim2.new(0, 0, 0, 2) }, duration, Enum.EasingStyle.Linear)
    task.delay(duration, function()
        tween(card, { Position = UDim2.new(0, 320, 0, 0) }, 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        task.delay(0.35, function() holder:Destroy() end)
    end)
end

-- // element constructors -------------------------------------------------------------

local function AddCheckbox(holder, text, default, opts, callback)
    opts = opts or {}
    local state = default or false
    local currentKey = nil

    local row = New("Frame", {
        Size = UDim2.new(1, 0, 0, 15),
        BackgroundTransparency = 1,
        Parent = holder,
    })
    local box = New("Frame", {
        Size = UDim2.fromOffset(9, 9),
        Position = UDim2.new(0, 1, 0.5, -4),
        BackgroundColor3 = state and Theme.Accent or Theme.Element,
        BorderSizePixel = 0,
        Parent = row,
    }, { Stroke(state and Theme.AccentDark or Theme.BorderDark) })
    local boxScale = New("UIScale", { Parent = box })
    local label = New("TextLabel", {
        Size = UDim2.new(1, -60, 1, 0),
        Position = UDim2.fromOffset(17, 0),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = text,
        TextSize = 13,
        TextColor3 = state and Theme.Text or Theme.TextDim,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })

    local function set(v)
        state = v
        tween(box, { BackgroundColor3 = state and Theme.Accent or Theme.Element }, 0.18)
        tween(box.UIStroke, { Color = state and Theme.AccentDark or Theme.BorderDark }, 0.18)
        tween(label, { TextColor3 = state and Theme.Text or Theme.TextDim }, 0.18)
        tween(boxScale, { Scale = 1.5 }, 0.08)
        task.delay(0.08, function() tween(boxScale, { Scale = 1 }, 0.18, Enum.EasingStyle.Back) end)
        if callback then callback(state) end
    end

    if opts.Keybind then
        local tag = New("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5),
            Size = UDim2.fromOffset(40, 14),
            Position = UDim2.new(1, 0, 0.5, 0),
            BackgroundTransparency = 1,
            Font = FONT,
            Text = "[–]",
            TextSize = 12,
            TextColor3 = Theme.TextDim,
            TextXAlignment = Enum.TextXAlignment.Right,
            Parent = row,
        })
        tag.MouseEnter:Connect(function() tween(tag, { TextColor3 = Theme.Accent }, 0.12) end)
        tag.MouseLeave:Connect(function() tween(tag, { TextColor3 = Theme.TextDim }, 0.12) end)
        tag.MouseButton1Click:Connect(function()
            tag.Text = "[...]"
            tag.TextColor3 = Theme.Accent
            Library._listening = {
                currentKey = function() return currentKey end,
                clear = function()
                    currentKey = nil
                    tag.Text = "[–]"
                    tag.TextColor3 = Theme.TextDim
                end,
                assign = function(keyCode)
                    if currentKey then Library.Binds[currentKey] = nil end
                    currentKey = keyCode
                    local name = keyCode.Name
                    if #name > 5 then name = name:sub(1, 5) end
                    tag.Text = "[" .. name .. "]"
                    tag.TextColor3 = Theme.TextDim
                    Library.Binds[keyCode] = function() set(not state) end
                end,
            }
        end)
    end

    New("TextButton", {
        Size = UDim2.new(1, opts.Keybind and -44 or 0, 1, 0),
        BackgroundTransparency = 1,
        Text = "",
        Parent = row,
    }).MouseButton1Click:Connect(function()
        set(not state)
    end)

    if state and callback then callback(state) end
    return { Set = set, Get = function() return state end }
end

local function AddSlider(holder, text, min, max, default, suffix, callback, step)
    suffix = suffix or ""
    step = step or 1
    local value = math.clamp(default or min, min, max)

    local function quantize(v)
        v = math.clamp(v, min, max)
        return math.clamp(min + math.floor((v - min) / step + 0.5) * step, min, max)
    end
    local function display(v)
        if step < 1 then return string.format("%.2f", v) .. suffix end
        return math.floor(v + 0.5) .. suffix
    end
    value = quantize(value)

    local frame = New("Frame", {
        Size = UDim2.new(1, 0, 0, 26),
        BackgroundTransparency = 1,
        Parent = holder,
    })
    New("TextLabel", {
        Size = UDim2.new(1, -50, 0, 14),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = text,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
    local valueLabel = New("TextLabel", {
        Size = UDim2.new(0, 56, 0, 14),
        Position = UDim2.new(1, -56, 0, 0),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = display(value),
        TextSize = 13,
        TextColor3 = Theme.TextDim,
        TextXAlignment = Enum.TextXAlignment.Right,
        Parent = frame,
    })
    local track = New("Frame", {
        Size = UDim2.new(1, 0, 0, 7),
        Position = UDim2.new(0, 0, 1, -8),
        BackgroundColor3 = Theme.Element,
        BorderSizePixel = 0,
        Parent = frame,
    }, { Stroke(Theme.BorderDark) })
    local fill = New("Frame", {
        Size = UDim2.new((value - min) / (max - min), 0, 1, 0),
        BackgroundColor3 = Theme.Accent,
        BorderSizePixel = 0,
        Parent = track,
    }, {
        New("UIGradient", { Color = ColorSequence.new(Theme.AccentDark, Theme.Accent) }),
    })

    local function set(v, animate)
        value = quantize(v)
        local rel = (value - min) / math.max(max - min, 1e-9)
        valueLabel.Text = display(value)
        if animate then
            tween(fill, { Size = UDim2.new(rel, 0, 1, 0) }, 0.1)
        else
            fill.Size = UDim2.new(rel, 0, 1, 0)
        end
        if callback then callback(value) end
    end

    local dragging = false
    local function setFromX(x)
        local rel = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
        set(min + (max - min) * rel, true)
    end
    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            tween(track.UIStroke, { Color = Theme.AccentDark }, 0.12)
            setFromX(input.Position.X)
        end
    end)
    trackConn(UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            setFromX(input.Position.X)
        end
    end))
    trackConn(UserInputService.InputEnded:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
            tween(track.UIStroke, { Color = Theme.BorderDark }, 0.2)
        end
    end))

    return { Set = function(v) set(v, true) end, Get = function() return value end }
end

local function AddDropdown(holder, text, options, default, callback)
    local LABEL_H, BOX_H, OPTION_H = 14, 18, 16
    local BASE = LABEL_H + 4 + BOX_H
    local open = false
    options = options or {}
    local selected = default or options[1] or "—"

    local frame = New("Frame", {
        Size = UDim2.new(1, 0, 0, BASE),
        BackgroundTransparency = 1,
        ClipsDescendants = true,
        Parent = holder,
    })
    New("TextLabel", {
        Size = UDim2.new(1, 0, 0, LABEL_H),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = text,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
    local box = New("TextButton", {
        Size = UDim2.new(1, 0, 0, BOX_H),
        Position = UDim2.new(0, 0, 0, LABEL_H + 4),
        BackgroundColor3 = Theme.Element,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        Parent = frame,
    }, { Stroke(Theme.BorderDark) })
    local valueLabel = New("TextLabel", {
        Size = UDim2.new(1, -26, 1, 0),
        Position = UDim2.fromOffset(6, 0),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = selected,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = box,
    })
    local plus = New("TextLabel", {
        AnchorPoint = Vector2.new(1, 0.5),
        Size = UDim2.fromOffset(14, 14),
        Position = UDim2.new(1, -4, 0.5, 0),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "+",
        TextSize = 14,
        TextColor3 = Theme.TextDim,
        Parent = box,
    })

    local optionButtons = {}
    local function close()
        open = false
        tween(frame, { Size = UDim2.new(1, 0, 0, BASE) }, 0.22, Enum.EasingStyle.Back)
        tween(plus, { Rotation = 0, TextColor3 = Theme.TextDim }, 0.22)
        for _, b in ipairs(optionButtons) do b.Visible = false end
    end

    local function setValue(option, fire)
        selected = option
        valueLabel.Text = tostring(option)
        for _, b in ipairs(optionButtons) do
            b.TextColor3 = (b.Text == tostring(option)) and Theme.Accent or Theme.TextDim
        end
        if fire and callback then callback(option) end
    end

    local function rebuild()
        for _, b in ipairs(optionButtons) do b:Destroy() end
        optionButtons = {}
        for i, option in ipairs(options) do
            local btn = New("TextButton", {
                Size = UDim2.new(1, -6, 0, OPTION_H),
                Position = UDim2.new(0, 6, 0, BASE + 2 + (i - 1) * OPTION_H),
                BackgroundTransparency = 1,
                Font = FONT,
                Text = option,
                TextSize = 13,
                TextColor3 = option == selected and Theme.Accent or Theme.TextDim,
                TextTransparency = open and 0 or 1,
                TextXAlignment = Enum.TextXAlignment.Left,
                Visible = open,
                Parent = frame,
            })
            optionButtons[i] = btn
            btn.MouseEnter:Connect(function()
                if selected ~= option then tween(btn, { TextColor3 = Theme.Text }, 0.1) end
            end)
            btn.MouseLeave:Connect(function()
                if selected ~= option then tween(btn, { TextColor3 = Theme.TextDim }, 0.1) end
            end)
            btn.MouseButton1Click:Connect(function()
                setValue(option, true)
                close()
            end)
        end
        if open then
            frame.Size = UDim2.new(1, 0, 0, BASE + 4 + #options * OPTION_H)
        end
    end
    rebuild()

    box.MouseButton1Click:Connect(function()
        open = not open
        if open then
            tween(frame, { Size = UDim2.new(1, 0, 0, BASE + 4 + #options * OPTION_H) }, 0.25, Enum.EasingStyle.Back)
            tween(plus, { Rotation = 45, TextColor3 = Theme.Accent }, 0.25, Enum.EasingStyle.Back)
            for i, btn in ipairs(optionButtons) do
                btn.Visible = true
                btn.TextTransparency = 1
                task.delay(0.03 * i, function() tween(btn, { TextTransparency = 0 }, 0.15) end)
            end
        else
            close()
        end
    end)
    box.MouseEnter:Connect(function() tween(box, { BackgroundColor3 = Color3.fromRGB(28, 28, 28) }, 0.12) end)
    box.MouseLeave:Connect(function() tween(box, { BackgroundColor3 = Theme.Element }, 0.12) end)

    return {
        Get = function() return selected end,
        Set = function(option) setValue(option, true) end,
        Refresh = function(newOptions)
            options = newOptions or {}
            if not table.find(options, selected) then
                selected = options[1] or "—"
                valueLabel.Text = tostring(selected)
            end
            rebuild()
        end,
    }
end

local function AddButton(holder, text, callback)
    local btn = New("TextButton", {
        Size = UDim2.new(1, 0, 0, 18),
        BackgroundColor3 = Theme.Element,
        BorderSizePixel = 0,
        Font = FONT,
        Text = text,
        TextSize = 13,
        TextColor3 = Theme.Text,
        AutoButtonColor = false,
        Parent = holder,
    }, { Stroke(Theme.BorderDark) })
    btn.MouseEnter:Connect(function() tween(btn.UIStroke, { Color = Theme.AccentDark }, 0.12) end)
    btn.MouseLeave:Connect(function() tween(btn.UIStroke, { Color = Theme.BorderDark }, 0.12) end)
    btn.MouseButton1Click:Connect(function()
        tween(btn, { BackgroundColor3 = Theme.AccentDark }, 0.06)
        task.delay(0.07, function() tween(btn, { BackgroundColor3 = Theme.Element }, 0.25) end)
        if callback then callback() end
    end)
end

local function AddTextLabel(holder, text)
    New("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = text,
        TextSize = 13,
        TextColor3 = Theme.TextDim,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = holder,
    })
end

local COLOR_PALETTE = {
    Color3.fromRGB(255, 255, 255), Color3.fromRGB(220, 60, 60),
    Color3.fromRGB(235, 150, 50),  Color3.fromRGB(230, 215, 70),
    Color3.fromRGB(80, 215, 100),  Color3.fromRGB(80, 200, 215),
    Color3.fromRGB(70, 120, 220),  Color3.fromRGB(163, 135, 200),
    Color3.fromRGB(235, 110, 170),
}

local function AddColorpicker(holder, text, default, callback)
    local ROW_H, OPEN_H = 15, 15 + 26
    local color = default or Color3.fromRGB(255, 255, 255)
    local open = false

    local frame = New("Frame", {
        Size = UDim2.new(1, 0, 0, ROW_H),
        BackgroundTransparency = 1,
        ClipsDescendants = true,
        Parent = holder,
    })
    New("TextLabel", {
        Size = UDim2.new(1, -40, 0, ROW_H),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = text,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
    local swatch = New("Frame", {
        AnchorPoint = Vector2.new(1, 0),
        Size = UDim2.fromOffset(24, 11),
        Position = UDim2.new(1, 0, 0, 2),
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        Parent = frame,
    }, { Stroke(Theme.BorderDark) })

    local function set(c, fire)
        color = c
        tween(swatch, { BackgroundColor3 = c }, 0.2)
        if fire and callback then callback(c) end
    end

    for i, c in ipairs(COLOR_PALETTE) do
        local btn = New("TextButton", {
            Size = UDim2.fromOffset(18, 18),
            Position = UDim2.fromOffset(1 + (i - 1) * 22, ROW_H + 5),
            BackgroundColor3 = c,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
            Parent = frame,
        }, { Stroke(Theme.BorderDark) })
        local scale = New("UIScale", { Parent = btn })
        btn.MouseEnter:Connect(function() tween(scale, { Scale = 1.2 }, 0.12, Enum.EasingStyle.Back) end)
        btn.MouseLeave:Connect(function() tween(scale, { Scale = 1 }, 0.12) end)
        btn.MouseButton1Click:Connect(function()
            set(c, true)
            open = false
            tween(frame, { Size = UDim2.new(1, 0, 0, ROW_H) }, 0.22, Enum.EasingStyle.Back)
        end)
    end

    New("TextButton", {
        Size = UDim2.new(1, 0, 0, ROW_H),
        BackgroundTransparency = 1,
        Text = "",
        Parent = frame,
    }).MouseButton1Click:Connect(function()
        open = not open
        tween(frame, { Size = UDim2.new(1, 0, 0, open and OPEN_H or ROW_H) }, 0.25, Enum.EasingStyle.Back)
    end)

    return {
        Get = function() return color end,
        Set = function(c) set(c, true) end,
    }
end

local function AddTextbox(holder, text, placeholder, default, callback)
    local LABEL_H, BOX_H = 14, 18
    local frame = New("Frame", {
        Size = UDim2.new(1, 0, 0, LABEL_H + 4 + BOX_H),
        BackgroundTransparency = 1,
        Parent = holder,
    })
    New("TextLabel", {
        Size = UDim2.new(1, 0, 0, LABEL_H),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = text,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
    local box = New("Frame", {
        Size = UDim2.new(1, 0, 0, BOX_H),
        Position = UDim2.new(0, 0, 0, LABEL_H + 4),
        BackgroundColor3 = Theme.Element,
        BorderSizePixel = 0,
        Parent = frame,
    }, { Stroke(Theme.BorderDark) })
    local stroke = box.UIStroke
    local textBox = New("TextBox", {
        Size = UDim2.new(1, -12, 1, 0),
        Position = UDim2.fromOffset(6, 0),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = default or "",
        PlaceholderText = placeholder or "",
        PlaceholderColor3 = Theme.TextDim,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        Parent = box,
    })
    textBox.Focused:Connect(function()
        tween(stroke, { Color = Theme.AccentDark }, 0.15)
    end)
    textBox.FocusLost:Connect(function()
        tween(stroke, { Color = Theme.BorderDark }, 0.2)
        if callback then callback(textBox.Text) end
    end)
    return {
        Get = function() return textBox.Text end,
        Set = function(v)
            textBox.Text = v or ""
            if callback then callback(textBox.Text) end
        end,
    }
end

-- // groupbox + tab + window ----------------------------------------------------------

local function CreateGroupbox(column, title)
    local card = New("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        Parent = column,
    }, { Stroke(Theme.BorderDark) })

    -- "── Title ─────" header: line behind an opaque label
    local headerLine = New("Frame", {
        Size = UDim2.new(1, -12, 0, 1),
        Position = UDim2.new(0, 6, 0, 9),
        BackgroundColor3 = Theme.Border,
        BorderSizePixel = 0,
        Parent = card,
    })
    New("TextLabel", {
        Size = UDim2.new(0, 0, 0, 14),
        Position = UDim2.fromOffset(12, 2),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        Font = FONT,
        Text = " " .. title .. " ",
        TextSize = 13,
        TextColor3 = Theme.Text,
        Parent = card,
    })
    -- header line shimmer
    local sheen = New("UIGradient", {
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.4),
            NumberSequenceKeypoint.new(0.5, 0),
            NumberSequenceKeypoint.new(1, 0.4),
        }),
        Offset = Vector2.new(-1, 0),
        Parent = headerLine,
    })
    TweenService:Create(sheen,
        TweenInfo.new(3, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1),
        { Offset = Vector2.new(1, 0) }
    ):Play()

    local holder = New("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        Position = UDim2.new(0, 0, 0, 18),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = card,
    }, {
        New("UIPadding", {
            PaddingLeft = UDim.new(0, 8),
            PaddingRight = UDim.new(0, 8),
            PaddingTop = UDim.new(0, 4),
            PaddingBottom = UDim.new(0, 8),
        }),
        New("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
    })

    local groupbox = {}
    function groupbox:AddCheckbox(...) return AddCheckbox(holder, ...) end
    function groupbox:AddSlider(...) return AddSlider(holder, ...) end
    function groupbox:AddDropdown(...) return AddDropdown(holder, ...) end
    function groupbox:AddButton(...) return AddButton(holder, ...) end
    function groupbox:AddLabel(...) return AddTextLabel(holder, ...) end
    function groupbox:AddColorpicker(...) return AddColorpicker(holder, ...) end
    function groupbox:AddTextbox(...) return AddTextbox(holder, ...) end
    return groupbox
end

function Library:CreateWindow(opts)
    opts = opts or {}
    local W = opts.Width or 388
    local H = opts.Height or 420
    local win = CreateWindowBase(
        UDim2.fromOffset(W, H),
        opts.Position or UDim2.new(0.5, -W / 2 + 130, 0.5, -H / 2 + 20)
    )

    local header = New("Frame", {
        Size = UDim2.new(1, 0, 0, 28),
        BackgroundTransparency = 1,
        Parent = win,
    }, {
        New("TextLabel", {
            Size = UDim2.new(1, -20, 1, 0),
            Position = UDim2.fromOffset(10, 0),
            BackgroundTransparency = 1,
            Font = FONT,
            RichText = true,
            Text = opts.Title or "window",
            TextSize = 14,
            TextColor3 = Theme.White,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        New("Frame", {
            Size = UDim2.new(1, 0, 0, 1),
            Position = UDim2.new(0, 0, 1, 0),
            BackgroundColor3 = Theme.BorderDark,
            BorderSizePixel = 0,
        }),
    })
    SmoothDrag(header, win)

    local tabbar = New("Frame", {
        Size = UDim2.new(1, 0, 0, 30),
        Position = UDim2.new(0, 0, 0, 29),
        BackgroundTransparency = 1,
        Parent = win,
    })
    local underline = New("Frame", {
        Size = UDim2.fromOffset(56, 2),
        Position = UDim2.new(0, 0, 1, -2),
        BackgroundColor3 = Theme.White,
        BorderSizePixel = 0,
        Parent = tabbar,
    })
    New("Frame", {
        Size = UDim2.new(1, 0, 0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = Theme.BorderDark,
        BorderSizePixel = 0,
        Parent = tabbar,
    })

    local content = New("Frame", {
        Size = UDim2.new(1, 0, 1, -60),
        Position = UDim2.new(0, 0, 0, 60),
        BackgroundTransparency = 1,
        ClipsDescendants = true,
        Parent = win,
    })

    local window = { Tabs = {}, Selected = nil }

    local function layoutTabs()
        local n = #window.Tabs
        for i, tab in ipairs(window.Tabs) do
            tab.Button.Size = UDim2.new(1 / n, 0, 1, -1)
            tab.Button.Position = UDim2.new((i - 1) / n, 0, 0, 0)
        end
    end

    local function moveUnderline(tab, instant)
        local n = #window.Tabs
        local i = table.find(window.Tabs, tab)
        local target = UDim2.new((i - 0.5) / n, -28, 1, -2)
        if instant then
            underline.Position = target
        else
            tween(underline, { Position = target }, 0.3, Enum.EasingStyle.Back)
        end
    end

    local function selectTab(tab, instant)
        if window.Selected == tab then return end
        window.Selected = tab
        moveUnderline(tab, instant)
        for _, t in ipairs(window.Tabs) do
            local on = (t == tab)
            tween(t.Label, { TextColor3 = on and Theme.White or Theme.TextDim }, 0.15)
            if on then
                t.Page.Visible = true
                if not instant then
                    t.Page.Position = UDim2.new(0, 0, 0, 14)
                    tween(t.Page, { Position = UDim2.new(0, 0, 0, 0) }, 0.25, Enum.EasingStyle.Back)
                end
            else
                t.Page.Visible = false
            end
        end
    end

    function window:AddTab(name)
        local button = New("TextButton", {
            BackgroundTransparency = 1,
            Text = "",
            Parent = tabbar,
        })
        local label = New("TextLabel", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            Font = FONT,
            Text = name,
            TextSize = 13,
            TextColor3 = Theme.TextDim,
            Parent = button,
        })
        local page = New("Frame", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            Visible = false,
            Parent = content,
        })

        local function makeColumn(xScale)
            local column = New("ScrollingFrame", {
                Size = UDim2.new(0.5, -12, 1, -12),
                Position = UDim2.new(xScale, xScale == 0 and 8 or 4, 0, 6),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                ScrollBarThickness = 2,
                ScrollBarImageColor3 = Theme.BorderDark,
                CanvasSize = UDim2.new(0, 0, 0, 0),
                Parent = page,
            })
            local layout = New("UIListLayout", {
                Padding = UDim.new(0, 8),
                SortOrder = Enum.SortOrder.LayoutOrder,
                Parent = column,
            })
            layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
                column.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 8)
            end)
            return column
        end

        local tab = {
            Name = name,
            Button = button,
            Label = label,
            Page = page,
            LeftColumn = makeColumn(0),
            RightColumn = makeColumn(0.5),
        }
        function tab:AddGroupbox(side, title)
            local column = (side == "Right") and tab.RightColumn or tab.LeftColumn
            return CreateGroupbox(column, title)
        end

        table.insert(window.Tabs, tab)
        layoutTabs()
        button.MouseButton1Click:Connect(function() selectTab(tab) end)
        button.MouseEnter:Connect(function()
            if window.Selected ~= tab then tween(label, { TextColor3 = Theme.Text }, 0.12) end
        end)
        button.MouseLeave:Connect(function()
            if window.Selected ~= tab then tween(label, { TextColor3 = Theme.TextDim }, 0.12) end
        end)

        if not window.Selected then
            task.defer(function()
                -- only the first added tab wins; later deferred calls bail
                if not window.Selected then selectTab(tab, true) end
            end)
        end
        return tab
    end

    return window
end

-- // music player ------------------------------------------------------------------------
-- drop .mp3 / .ogg / .wav files into the executor workspace folder (default
-- "slurricane/music"); loaded via getcustomasset and played through a Sound.

function Library:CreateMusicPlayer(opts)
    opts = opts or {}
    local folder = opts.Folder or "slurricane/music"

    pcall(function()
        if makefolder then
            if not (isfolder and isfolder("slurricane")) then makefolder("slurricane") end
            if not (isfolder and isfolder(folder)) then makefolder(folder) end
        end
    end)

    local sound = New("Sound", { Name = "juanita_player", Volume = 1, Parent = SoundService })
    table.insert(Library._sounds, sound)
    local tracks, idx, playing = {}, 0, false

    local function trackMeta(path)
        local name = path:match("([^/\\]+)%.%w+$") or tostring(path)
        local artist, title = name:match("^(.-)%s*%-%s*(.+)$")
        if artist and #artist > 0 then return title, artist end
        return name, "unknown artist"
    end

    local function scan()
        local found = {}
        local ok, files = pcall(function() return listfiles(folder) end)
        if ok and files then
            for _, f in ipairs(files) do
                local ext = f:match("%.(%w+)$")
                if ext and (ext:lower() == "mp3" or ext:lower() == "ogg" or ext:lower() == "wav") then
                    table.insert(found, f)
                end
            end
            table.sort(found)
        end
        return found
    end

    -- player panel ------------------------------------------------------------
    local PW, PH = 252, 104
    local player = CreateWindowBase(UDim2.fromOffset(PW, PH), opts.Position or UDim2.new(0.5, -PW / 2 - 290, 0.5, -200))

    local art = New("Frame", {
        Size = UDim2.fromOffset(38, 38),
        Position = UDim2.fromOffset(8, 8),
        BackgroundColor3 = Theme.Element,
        BorderSizePixel = 0,
        Parent = player,
    }, {
        Stroke(Theme.BorderDark),
        New("TextLabel", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            Font = FONT,
            Text = "♪",
            TextSize = 18,
            TextColor3 = Theme.Accent,
        }),
    })
    local artScale = New("UIScale", { Parent = art })

    local titleLabel = New("TextLabel", {
        Size = UDim2.new(1, -62, 0, 16),
        Position = UDim2.fromOffset(54, 10),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "no tracks found",
        TextSize = 13,
        TextColor3 = Theme.White,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = player,
    })
    local artistLabel = New("TextLabel", {
        Size = UDim2.new(1, -62, 0, 14),
        Position = UDim2.fromOffset(54, 27),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "add mp3s to " .. folder,
        TextSize = 12,
        TextColor3 = Theme.TextDim,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = player,
    })

    local dragZone = New("Frame", {
        Size = UDim2.new(1, 0, 0, 50),
        BackgroundTransparency = 1,
        Parent = player,
    })
    SmoothDrag(dragZone, player)

    local curTime = New("TextLabel", {
        Size = UDim2.fromOffset(32, 12),
        Position = UDim2.fromOffset(8, 56),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "0:00",
        TextSize = 11,
        TextColor3 = Theme.TextDim,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = player,
    })
    local totalTime = New("TextLabel", {
        AnchorPoint = Vector2.new(1, 0),
        Size = UDim2.fromOffset(32, 12),
        Position = UDim2.new(1, -8, 0, 56),
        BackgroundTransparency = 1,
        Font = FONT,
        Text = "0:00",
        TextSize = 11,
        TextColor3 = Theme.TextDim,
        TextXAlignment = Enum.TextXAlignment.Right,
        Parent = player,
    })
    local progress = New("Frame", {
        Size = UDim2.new(1, -88, 0, 5),
        Position = UDim2.fromOffset(44, 59),
        BackgroundColor3 = Theme.Element,
        BorderSizePixel = 0,
        Parent = player,
    }, { Stroke(Theme.BorderDark) })
    local progressFill = New("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = Theme.Accent,
        BorderSizePixel = 0,
        Parent = progress,
    }, {
        New("UIGradient", { Color = ColorSequence.new(Theme.AccentDark, Theme.Accent) }),
    })

    local function fmt(t)
        t = math.max(t or 0, 0)
        return ("%d:%02d"):format(t / 60, t % 60)
    end

    -- seeking
    local seeking = false
    local function seekFromX(x)
        local rel = math.clamp((x - progress.AbsolutePosition.X) / progress.AbsoluteSize.X, 0, 1)
        if sound.TimeLength > 0 then
            sound.TimePosition = rel * sound.TimeLength
        end
    end
    progress.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            seeking = true
            seekFromX(input.Position.X)
        end
    end)
    trackConn(UserInputService.InputChanged:Connect(function(input)
        if seeking and input.UserInputType == Enum.UserInputType.MouseMovement then
            seekFromX(input.Position.X)
        end
    end))
    trackConn(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            seeking = false
        end
    end))

    -- control buttons
    local function controlButton(text, anchorX, x, size, callback)
        local btn = New("TextButton", {
            AnchorPoint = Vector2.new(anchorX, 0),
            Size = UDim2.fromOffset(size, 20),
            Position = UDim2.new(anchorX, x, 0, 76),
            BackgroundTransparency = 1,
            Font = FONT,
            Text = text,
            TextSize = 14,
            TextColor3 = Theme.Text,
            Parent = player,
        })
        local s = New("UIScale", { Parent = btn })
        btn.MouseEnter:Connect(function()
            tween(btn, { TextColor3 = Theme.Accent }, 0.12)
            tween(s, { Scale = 1.2 }, 0.15, Enum.EasingStyle.Back)
        end)
        btn.MouseLeave:Connect(function()
            tween(btn, { TextColor3 = Theme.Text }, 0.12)
            tween(s, { Scale = 1 }, 0.15)
        end)
        btn.MouseButton1Click:Connect(callback)
        return btn
    end

    -- visualizer panel ---------------------------------------------------------
    local visualizer, visEntry = CreateWindowBase(UDim2.fromOffset(PW, 74), UDim2.new(0.5, -PW / 2 - 290, 0.5, -86))
    SmoothDrag(visualizer, visualizer)
    local BAR_COUNT = 26
    local bars, heights = {}, {}
    local barW = (PW - 14) / BAR_COUNT
    for i = 1, BAR_COUNT do
        heights[i] = 0
        bars[i] = New("Frame", {
            AnchorPoint = Vector2.new(0, 1),
            Size = UDim2.fromOffset(math.floor(barW) - 2, 2),
            Position = UDim2.new(0, 7 + (i - 1) * barW, 1, -7),
            BackgroundColor3 = Theme.Accent,
            BorderSizePixel = 0,
            Parent = visualizer,
        }, {
            New("UIGradient", { Rotation = -90, Color = ColorSequence.new(Theme.AccentDark, Theme.Accent) }),
        })
    end

    -- playlist panel -------------------------------------------------------------
    local playlist, playlistEntry = CreateWindowBase(UDim2.fromOffset(310, 134), UDim2.new(0.5, -PW / 2 - 350, 0.5, 6))
    local playlistHeader = New("Frame", {
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Parent = playlist,
    }, {
        New("TextLabel", {
            Size = UDim2.new(1, -40, 1, 0),
            Position = UDim2.fromOffset(8, 0),
            BackgroundTransparency = 1,
            Font = FONT,
            Text = "playlist",
            TextSize = 12,
            TextColor3 = Theme.TextDim,
            TextXAlignment = Enum.TextXAlignment.Left,
        }),
        New("Frame", {
            Size = UDim2.new(1, 0, 0, 1),
            Position = UDim2.new(0, 0, 1, 0),
            BackgroundColor3 = Theme.BorderDark,
            BorderSizePixel = 0,
        }),
    })
    SmoothDrag(playlistHeader, playlist)

    local playlistScroll = New("ScrollingFrame", {
        Size = UDim2.new(1, -8, 1, -26),
        Position = UDim2.fromOffset(4, 23),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 2,
        ScrollBarImageColor3 = Theme.BorderDark,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        Parent = playlist,
    })
    local playlistLayout = New("UIListLayout", {
        Padding = UDim.new(0, 2),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = playlistScroll,
    })
    playlistLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        playlistScroll.CanvasSize = UDim2.new(0, 0, 0, playlistLayout.AbsoluteContentSize.Y + 4)
    end)

    local playIndex -- forward declaration
    local entryButtons = {}

    local function refreshPlaylistHighlight()
        for i, btn in ipairs(entryButtons) do
            local current = (i == idx)
            local trackTitle, trackArtist = trackMeta(tracks[i])
            btn.Text = (current and "▸ " or "  ") .. trackArtist .. " - " .. trackTitle
            tween(btn, { TextColor3 = current and Theme.Accent or Theme.TextDim }, 0.2)
        end
    end

    local function rebuildPlaylist()
        for _, b in ipairs(entryButtons) do b:Destroy() end
        entryButtons = {}
        for i, path in ipairs(tracks) do
            local trackTitle, trackArtist = trackMeta(path)
            local btn = New("TextButton", {
                Size = UDim2.new(1, 0, 0, 16),
                BackgroundTransparency = 1,
                Font = FONT,
                Text = "  " .. trackArtist .. " - " .. trackTitle,
                TextSize = 12,
                TextColor3 = Theme.TextDim,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Parent = playlistScroll,
            })
            entryButtons[i] = btn
            btn.MouseEnter:Connect(function()
                if i ~= idx then tween(btn, { TextColor3 = Theme.Text }, 0.1) end
            end)
            btn.MouseLeave:Connect(function()
                if i ~= idx then tween(btn, { TextColor3 = Theme.TextDim }, 0.1) end
            end)
            btn.MouseButton1Click:Connect(function() playIndex(i) end)
        end
        refreshPlaylistHighlight()
    end

    -- playback core ---------------------------------------------------------------
    local playBtn

    playIndex = function(i, autoplay)
        if autoplay == nil then autoplay = true end
        if #tracks == 0 then return end
        idx = ((i - 1) % #tracks) + 1
        local path = tracks[idx]
        local getasset = (getcustomasset or getsynasset)
        if not getasset then
            titleLabel.Text = "executor lacks getcustomasset"
            return
        end
        local ok, asset = pcall(getasset, path)
        if not ok or not asset then
            titleLabel.Text = "failed to load file"
            return
        end
        sound:Stop()
        sound.SoundId = asset
        sound.TimePosition = 0
        if autoplay then sound:Play() end
        playing = autoplay
        playBtn.Text = playing and "II" or "▶"
        local trackTitle, trackArtist = trackMeta(path)
        titleLabel.Text = trackTitle
        artistLabel.Text = trackArtist
        refreshPlaylistHighlight()
        -- pop the album art on track change
        tween(artScale, { Scale = 1.25 }, 0.1)
        task.delay(0.1, function() tween(artScale, { Scale = 1 }, 0.25, Enum.EasingStyle.Back) end)
    end

    local function togglePlay()
        if #tracks == 0 then return end
        if idx == 0 then playIndex(1) return end
        playing = not playing
        if playing then
            if sound.TimePosition > 0 then sound:Resume() else sound:Play() end
        else
            sound:Pause()
        end
        playBtn.Text = playing and "II" or "▶"
    end

    controlButton("▁▅▃", 0, 8, 28, function()
        visEntry.hidden = not visEntry.hidden
        showWindow(visEntry, not visEntry.hidden)
    end)
    controlButton("≪", 0.5, -28, 20, function() playIndex(idx - 1) end)
    playBtn = controlButton("▶", 0.5, 0, 20, togglePlay)
    controlButton("≫", 0.5, 28, 20, function() playIndex(idx + 1) end)
    controlButton("♪", 1, -8, 20, function()
        playlistEntry.hidden = not playlistEntry.hidden
        showWindow(playlistEntry, not playlistEntry.hidden)
    end)

    sound.Ended:Connect(function()
        if playing then playIndex(idx + 1) end
    end)

    -- per-frame: progress, time labels, visualizer, art pulse ------------------------
    local clock = 0
    trackConn(RunService.Heartbeat:Connect(function(dt)
        clock += dt
        local length = sound.TimeLength
        curTime.Text = fmt(sound.TimePosition)
        totalTime.Text = fmt(length)
        local rel = length > 0 and (sound.TimePosition / length) or 0
        progressFill.Size = progressFill.Size:Lerp(UDim2.new(rel, 0, 1, 0), math.min(dt * 16, 1))

        local loud = (sound.IsPlaying and sound.PlaybackLoudness or 0)
        local base = math.clamp(loud / 420, 0, 1)
        artScale.Scale = artScale.Scale + ((1 + base * 0.08) - artScale.Scale) * math.min(dt * 8, 1)

        local maxH = visualizer.AbsoluteSize.Y - 16
        for i = 1, BAR_COUNT do
            local weight = 1 / (1 + (i - 1) * 0.16)
            local wave = 0.55 + 0.45 * math.abs(math.sin(clock * (1.6 + i * 0.53)))
            local target = base * weight * wave
            heights[i] = heights[i] + (target - heights[i]) * math.min(dt * 9, 1)
            bars[i].Size = UDim2.fromOffset(math.floor(barW) - 2, math.max(2, heights[i] * maxH))
        end
    end))

    -- scan + load first track paused (no auto-blast on inject)
    local function rescan()
        tracks = scan()
        rebuildPlaylist()
        if #tracks > 0 then
            playIndex(1, false)
        else
            titleLabel.Text = "no tracks found"
            artistLabel.Text = "add mp3s to " .. folder
        end
    end
    rescan()

    return {
        Rescan = rescan,
        Play = playIndex,
        Toggle = togglePlay,
        Sound = sound,
        Folder = folder,
    }
end

-- ============================================================================
-- // DEMO CONFIG — recreates the screenshot. Skipped when the loader sets
-- // getgenv().SLURRICANE_LIB = true before loadstring-ing this file.
-- ============================================================================

if not (getgenv and getgenv().SLURRICANE_LIB) then

local Window = Library:CreateWindow({
    Title = ('<font color="#ffffff">juanita</font><font color="#%s">haxx</font> <font color="#5a5a5a">| uid 1337</font>'):format(ACCENT_HEX),
})

local Combat   = Window:AddTab("Combat")
local Visuals  = Window:AddTab("Visuals")
local Misc     = Window:AddTab("Misc")
local Settings = Window:AddTab("Settings")

local Ragebot = Combat:AddGroupbox("Left", "Ragebot")
Ragebot:AddCheckbox("Enabled", true, { Keybind = true })
Ragebot:AddCheckbox("Silent aim", false, { Keybind = true })
Ragebot:AddCheckbox("Auto fire", true)
Ragebot:AddCheckbox("Auto stop", false)
Ragebot:AddSlider("FOV", 0, 30, 5, "")
Ragebot:AddSlider("Smoothing", 0, 30, 12, "")
Ragebot:AddSlider("Hitchance", 0, 100, 65, "")
Ragebot:AddDropdown("Hitbox", { "Head", "Neck", "Chest", "Stomach" }, "Head")

local AntiAim = Combat:AddGroupbox("Left", "Anti-aim")
AntiAim:AddCheckbox("Fake lag", true, { Keybind = true })
AntiAim:AddCheckbox("LBY breaker", false)

local Exploits = Combat:AddGroupbox("Right", "Exploits")
Exploits:AddCheckbox("Bunny hop", false, { Keybind = true })
Exploits:AddCheckbox("Auto strafe", true)

for _, tab in ipairs({ Visuals, Misc, Settings }) do
    local gb = tab:AddGroupbox("Left", tab.Name)
    gb:AddLabel("nothing here yet")
end

Library:CreateWatermark()
Library:CreateMusicPlayer({ Folder = "slurricane/music" })

end -- demo

return Library

