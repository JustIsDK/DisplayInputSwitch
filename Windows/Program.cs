using System.Runtime.InteropServices;
using System.Text.Json;
using System.Reflection;

namespace DisplayInputSwitch;
internal static class Program {
    [STAThread] static void Main() {
        using var mutex = new Mutex(true, "Local\\DisplayInputSwitch", out bool first);
        if (!first) { MessageBox.Show("显示器切换已经在托盘中运行。", "显示器切换"); return; }
        ApplicationConfiguration.Initialize();
        using var form = new SwitchForm();
        Application.Run(new ApplicationContext());
    }
}
internal sealed class SwitchForm : Form {
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] static extern short GetKeyState(int key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr window, int id);
    readonly string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DisplayInputSwitch");
    readonly NotifyIcon tray = new();
    readonly ContextMenuStrip menu = new();
    readonly Label status = new() { AutoSize = false, Dock = DockStyle.Bottom, Height = 110, Padding = new Padding(12), AutoEllipsis = true };
    readonly Label saved = new() { AutoSize = true };
    readonly Label shortcuts = new() { AutoSize = true };
    readonly Label detected = new() { AutoSize = true, MaximumSize = new Size(720, 0) };
    readonly TextBox log = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, Dock = DockStyle.Fill, WordWrap = false };
    readonly DataGridView grid = new() { Dock = DockStyle.Top, Height = 270, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, AllowUserToAddRows = false, AllowUserToDeleteRows = false, RowHeadersVisible = false, SelectionMode = DataGridViewSelectionMode.FullRowSelect };
    readonly CheckBox enableKeys = new() { Text = "启用全局快捷键", AutoSize = true };
    readonly CheckBox launchAtLogin = new() { Text = "开机启动", AutoSize = true };
    readonly Label loginStatus = new() { AutoSize = true, MaximumSize = new Size(700, 0) };
    readonly TabControl tabs = new() { Dock = DockStyle.Fill };
    readonly FlowLayoutPanel softwarePanel = Flow(), hardwarePanel = Flow();
    readonly TabControl brightnessTabs = new() { Dock = DockStyle.Fill };
    readonly SoftwareDimming dimming = new();
    string brightnessMode = Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\DisplayInputSwitch", "BrightnessPolicy", "auto") as string ?? "auto";
    bool softwareDimming => brightnessMode != "hardware";
    readonly Dictionary<string,bool?> hdrStates = [];
    bool UsesSoftware(string serial) => Brightness.UsesSoftware(brightnessMode,hdrStates.GetValueOrDefault(serial));
    int MinimumBrightness(string[] serials) => serials.Any(UsesSoftware) ? 10 : 0;
    string RouteName(string serial) => brightnessMode == "auto" ? hdrStates.GetValueOrDefault(serial) is bool hdr ? hdr ? "HDR 已开启 · 软件调暗" : "HDR 已关闭 · 硬件调光" : "HDR 未知 · 软件调暗" : UsesSoftware(serial) ? "软件调暗" : "硬件调光";
    FlowLayoutPanel brightnessPanel => softwareDimming ? softwarePanel : hardwarePanel;
    readonly Dictionary<string, int> levels = [];
    readonly Dictionary<string, string> levelErrors = [];
    readonly List<(string[] Serials, TrackBar Slider, Label Value, Button Apply)> brightnessControls = [];
    readonly Dictionary<int, string> keyGroups = [];
    readonly FlowLayoutPanel shortcutPanel = Flow();
    readonly DataGridView shortcutGrid = new() { Width = 700,Height = 320,ReadOnly = true,AllowUserToAddRows = false,AllowUserToDeleteRows = false,RowHeadersVisible = false,AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill };
    readonly ComboBox menuLayout = new() { DropDownStyle = ComboBoxStyle.DropDownList,Width = 270 };
    readonly NumericUpDown brightnessStep = new() { Minimum = 1,Maximum = 20,Width = 80 };
    readonly TextBox recordBox = new() { ReadOnly = true,Width = 660,Text = "点击操作旁的“录制”，再按组合键。Esc 取消。" };
    readonly Label keyStatus = new() { AutoSize = true,MaximumSize = new Size(700,0) };
    readonly CheckBox settingsKeys = new() { Text = "启用全局快捷键",AutoSize = true };
    readonly List<(string[] Serials,TrackBar Slider,Label Value)> traySliders = [];
    string? recordingAction;
    Configuration? appliedConfig;
    Configuration config;
    bool busy, adjustingBrightness;
    Func<Task>? pendingBrightness;
    int brightnessGeneration;
    string ConfigPath => Path.Combine(folder, "config.json");
    string LogPath => Path.Combine(folder, "switch.log");
    public SwitchForm() {
        AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = AutoScaleMode.Dpi;
        Text = "显示器切换"; Font = new Font("Microsoft YaHei UI", 9.5f);
        Size = new Size(1020, 780); MinimumSize = new Size(920, 660); StartPosition = FormStartPosition.CenterScreen;
        BackColor = Appearance.Canvas;
        using (var iconStream = Assembly.GetExecutingAssembly().GetManifestResourceStream("DisplayInputSwitch.AppIcon.ico")) {
            if (iconStream != null) { using var source = new Icon(iconStream); Icon = (Icon)source.Clone(); }
        }
        Directory.CreateDirectory(folder);
        string? loadError = null;
        using var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("DisplayInputSwitch.default.json") ?? throw new Exception("缺少默认配置。");
        using var reader = new StreamReader(resource); config = Configuration.Parse(reader.ReadToEnd());
        if (File.Exists(ConfigPath)) try { config = Configuration.Parse(File.ReadAllText(ConfigPath)); } catch (Exception e) { loadError = "配置读取失败，显示默认配置；原文件保留：" + e.Message; }
        Controls.Add(tabs); Controls.Add(status);
        var generalPage = new TabPage("通用") { Padding = new Padding(12) };
        var general = Flow();
        general.Controls.Add(launchAtLogin); general.SetFlowBreak(launchAtLogin, true);
        general.Controls.Add(new Label { Text = "登录后自动在系统托盘运行。更改立即生效，仅用于本机。请将程序保存在固定位置。", AutoSize = true, MaximumSize = new Size(700, 0) });
        general.SetFlowBreak(general.Controls[^1], true);
        general.Controls.Add(loginStatus); general.SetFlowBreak(loginStatus, true);
        general.Controls.Add(Button("打开系统启动应用设置…", () => {
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:startupapps") { UseShellExecute = true }); }
            catch (Exception e) { loginStatus.Text = e.Message; }
        }));
        generalPage.Controls.Add(general); tabs.TabPages.Add(generalPage);
        RefreshLoginStatus();
        launchAtLogin.Click += (_, _) => {
            try { Startup.SetEnabled(launchAtLogin.Checked); RefreshLoginStatus(); SetStatus("开机启动：" + loginStatus.Text); }
            catch (Exception e) { RefreshLoginStatus(); loginStatus.Text = "更改失败：" + e.Message; SetStatus(loginStatus.Text); }
        };
        Activated += (_, _) => RefreshLoginStatus();
        Deactivate += (_, _) => CancelRecording();
        var groupsPage = new TabPage("组别") { Padding = new Padding(12) };
        var groupActions = Flow(); groupActions.Dock = DockStyle.Fill;
        groupActions.Controls.Add(Button("添加组别", () => {
            if (grid.Rows.Count >= 9) return;
            var values = new List<object> { "新组别" }; values.AddRange(config.Monitors.Select(_ => (object)27)); values.Add(0);
            int index = grid.Rows.Add(values.ToArray()); grid.Rows[index].Tag = Guid.NewGuid().ToString();
        }));
        groupActions.Controls.Add(Button("删除选中组别", () => { if (grid.CurrentRow != null && grid.Rows.Count > 1) grid.Rows.Remove(grid.CurrentRow); }));
        groupActions.Controls.Add(Button("保存配置", SaveFromGrid));
        groupActions.Controls.Add(Button("切换选中组别", () => {
            if (grid.CurrentRow is not DataGridViewRow row) return;
            string? id = row.Tag as string;
            if (!SaveFromGridResult()) return;
            var g = config.Groups.First(x => x.Id == id); _ = Run(() => ApplyGroup(g));
        }));
        groupActions.SetFlowBreak(groupActions.Controls[^1], true);
        groupActions.Controls.Add(enableKeys); groupActions.SetFlowBreak(enableKeys, true);
        groupActions.Controls.Add(shortcuts); groupActions.SetFlowBreak(shortcuts, true);
        groupActions.Controls.Add(Button("导入 JSON…", Import)); groupActions.Controls.Add(Button("导出 JSON…", Export));
        var groupSaved = new Label { AutoSize = true,MaximumSize = new Size(700,0) };
        saved.TextChanged += (_, _) => groupSaved.Text = saved.Text;
        groupActions.Controls.Add(groupSaved);
        groupsPage.Controls.Add(groupActions); groupsPage.Controls.Add(grid); tabs.TabPages.Add(groupsPage);
        var brightnessPage = new TabPage("亮度") { Padding = new Padding(12) };
        var autoPage = new TabPage("自动 · 检测 HDR");
        var softwarePage = new TabPage("软件调暗 · HDR"); softwarePage.Controls.Add(softwarePanel);
        var hardwarePage = new TabPage("硬件调光 · SDR"); hardwarePage.Controls.Add(hardwarePanel);
        brightnessTabs.TabPages.Add(autoPage); brightnessTabs.TabPages.Add(softwarePage); brightnessTabs.TabPages.Add(hardwarePage);
        brightnessTabs.SelectedIndex = brightnessMode == "auto" ? 0 : brightnessMode == "software" ? 1 : 2;
        brightnessTabs.SelectedTab!.Controls.Add(brightnessPanel);
        brightnessPage.Controls.Add(brightnessTabs); tabs.TabPages.Add(brightnessPage);
        brightnessTabs.Selecting += (_, e) => { if (busy) e.Cancel = true; };
        brightnessTabs.SelectedIndexChanged += (_, _) => {
            dimming.Reset(); brightnessMode = brightnessTabs.SelectedIndex == 0 ? "auto" : brightnessTabs.SelectedIndex == 1 ? "software" : "hardware";
            brightnessTabs.SelectedTab!.Controls.Add(brightnessPanel);
            levels.Clear(); levelErrors.Clear(); BuildBrightnessControls();
            try { Microsoft.Win32.Registry.SetValue(@"HKEY_CURRENT_USER\Software\DisplayInputSwitch", "BrightnessPolicy", brightnessMode); }
            catch (Exception e) { SetStatus("无法保存调光方式：" + e.Message); }
            _ = Run(LoadBrightness, brightness: true);
        };
        BuildBrightnessControls();
        var shortcutPage = new TabPage("状态栏与快捷键"); shortcutPage.Controls.Add(shortcutPanel); tabs.TabPages.Add(shortcutPage);
        BuildShortcutSettings();
        var monitorPage = new TabPage("显示器") { Padding = new Padding(12) };
        var monitors = Flow(); monitors.Controls.Add(Button("检测 / 读取", () => _ = Run(RefreshDisplays)));
        monitors.SetFlowBreak(monitors.Controls[^1], true); monitors.Controls.Add(detected);
        monitors.SetFlowBreak(detected, true); monitors.Controls.Add(new Label { Text = "按 EDID 序列号识别显示器。更换显示器：导出 JSON，修改 monitors、groups 的 serial 后导入。", AutoSize = true, MaximumSize = new Size(700, 0) });
        monitorPage.Controls.Add(monitors); tabs.TabPages.Add(monitorPage);
        var logPage = new TabPage("日志"); logPage.Controls.Add(log); tabs.TabPages.Add(logPage);
        grid.DataError += (_, e) => { e.ThrowException = false; SetStatus("组别字段值无效，请重新选择。"); };
        InitializeAppearance();
        tray.Text = "显示器切换"; tray.Icon = Icon; tray.ContextMenuStrip = menu; tray.Visible = true;
        tray.DoubleClick += (_, _) => ShowSettings();
        FormClosing += (_, e) => { e.Cancel = true; Hide(); };
        BuildGrid(); RegisterKeys(); BuildMenu();
        if (loadError != null) SetStatus(loadError); else SetStatus("已在托盘运行。DDC 回读仅确认输入源；画面需实际观察。");
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += DisplaySettingsChanged;
        _ = Run(RefreshDisplays);
    }
    void DisplaySettingsChanged(object? sender, EventArgs args) {
        if (IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke((Action)(() => {
            try { dimming.Reconcile(); } catch (Exception e) { dimming.Reset(); SetStatus(e.Message); }
            if (softwareDimming) _ = Run(LoadBrightness, brightness: true);
        })); } catch (InvalidOperationException) { }
    }
    static FlowLayoutPanel Flow() => Appearance.Flow();
    void InitializeAppearance() {
        string[] titles = ["通用设置", "输入源组别", "亮度调节", "状态栏与快捷键", "已连接的显示器", "运行日志"];
        string[] descriptions = ["设置本机启动方式，关闭窗口后继续在托盘运行。", "为每台电脑配置一组输入源，一次切换多台显示器。", "按显示器独立调节，也可以同时调整所有屏幕。", "选择托盘滑块布局，并为常用操作设置全局快捷键。", "读取当前连接、输入源与显示器身份。", "查看操作结果、DDC 回读和错误详情。"];
        for (int i = 0; i < tabs.TabPages.Count; i++) {
            var page = tabs.TabPages[i]; page.Padding = new Padding(8);
            page.Controls.Add(Appearance.Heading(titles[i], descriptions[i]));
        }
        Appearance.Style(this);
        Appearance.Tabs(tabs, navigation: true); Appearance.Tabs(brightnessTabs, navigation: false);
        var header = new Panel { Dock = DockStyle.Top, Height = 96, Padding = new Padding(24, 16, 24, 16), BackColor = Appearance.Canvas };
        var image = new PictureBox { Image = Icon?.ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom,
            Dock = DockStyle.Left, Width = 56, TabStop = false };
        image.Disposed += (_, _) => image.Image?.Dispose();
        var text = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 0, 0, 0) };
        text.Controls.Add(new Label { Text = "输入源 · 亮度 · 全局快捷键", Dock = DockStyle.Fill, ForeColor = Appearance.Muted });
        text.Controls.Add(new Label { Text = "显示器切换", Dock = DockStyle.Top, Height = 36,
            Font = new Font(Font.FontFamily, 19, FontStyle.Bold), ForeColor = Appearance.Ink });
        header.Controls.Add(text); header.Controls.Add(image);
        Controls.Add(header);
        status.Height = 84; status.Padding = new Padding(24, 12, 24, 12);
        status.BackColor = Appearance.Canvas; status.ForeColor = Appearance.Ink;
        status.AccessibleName = "运行状态";
        log.Font = new Font("Consolas", 10); log.BorderStyle = BorderStyle.None;
        log.BackColor = Appearance.Surface; log.ForeColor = Appearance.Ink;
        menu.Font = Font; menu.ShowImageMargin = false;
    }
    void RefreshLoginStatus() {
        try {
            launchAtLogin.Checked = Startup.IsRegistered();
            launchAtLogin.Enabled = true;
            loginStatus.Text = launchAtLogin.Checked ? "已注册当前路径的启动项；若被系统禁用，请在“启动应用”中启用。" : "当前路径未注册开机启动。";
        } catch (Exception e) { launchAtLogin.Enabled = false; loginStatus.Text = "无法读取启动项：" + e.Message; }
    }
    void BuildBrightnessControls() {
        foreach (var panel in new[] { softwarePanel, hardwarePanel }) {
            foreach (Control c in panel.Controls.Cast<Control>().ToList()) c.Dispose();
            panel.Controls.Clear();
        }
        brightnessControls.Clear();
        var note = new Label { Text = brightnessMode == "auto" ? "每屏分别检测 HDR：开启时软件调暗，关闭时硬件调光；未知时使用软件调暗。快捷键跟随每屏方式。软件 100% 为原画面，硬件 100% 为最大背光。" : softwareDimming ? "保留 HDR，调暗当前画面。100% 为原画面，最低 10%。不修改 HDR、背光或伽马；启动时不调暗，退出后恢复。" : "显示器硬件亮度，适用于关闭 HDR 的显示器。HDR 下 DDC 数值变化可能不影响画面。拖动松手后应用，或点击“应用”。", AutoSize = true, MaximumSize = new Size(700, 0) };
        brightnessPanel.Controls.Add(note); brightnessPanel.SetFlowBreak(note, true);
        if (softwareDimming) {
            brightnessPanel.Controls.Add(Button("恢复所有屏幕到 100%", ResetSoftwareDimming));
            brightnessPanel.SetFlowBreak(brightnessPanel.Controls[^1], true);
        }
        foreach (var m in config.Monitors) AddBrightnessControl(m.Name, [m.Serial]);
        if (config.Monitors.Count > 1) AddBrightnessControl("所有显示器联动", config.Monitors.Select(m => m.Serial).ToArray());
        brightnessPanel.Controls.Add(Button("读取当前亮度", () => _ = Run(RefreshBrightness, brightness: true)));
        brightnessPanel.SetFlowBreak(brightnessPanel.Controls[^1], true);
        brightnessPanel.Controls.Add(new Label { Text = softwareDimming ? "联动将所有屏幕设置为相同比例。软件遮罩方案来自 MonitorControl；其他工具的调暗效果会叠加。独占全屏、受保护视频和系统安全界面可能不受影响。" : "联动滑块显示第一台屏幕的值，应用时设为相同比例。工具不会自动修改 HDR。", AutoSize = true, MaximumSize = new Size(700, 0) });
        Appearance.Style(brightnessPanel);
    }
    void AddBrightnessControl(string name, string[] serials) {
        var row = new TableLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Width = 700,
            ColumnCount = 2, RowCount = 3, Margin = new Padding(0, 12, 0, 16), Padding = new Padding(0, 8, 0, 8) };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var title = new Label { Text = name, AutoSize = true, Font = new Font(Font, FontStyle.Bold) };
        var value = new Label { Text = "未读取", AutoSize = true, MaximumSize = new Size(650, 0) };
        var slider = new TrackBar { Minimum = MinimumBrightness(serials), Maximum = 100, Dock = DockStyle.Fill, AccessibleName = name + "亮度", Enabled = false };
        var apply = Button("应用", () => ApplyBrightness(serials, slider.Value)); apply.Enabled = false;
        slider.ValueChanged += (_, _) => value.Text = slider.Value + "%";
        slider.MouseUp += (_, e) => { if (e.Button == MouseButtons.Left && slider.Enabled) ApplyBrightness(serials, slider.Value); };
        slider.KeyUp += (_, e) => { if (e.KeyCode is Keys.Left or Keys.Right or Keys.Up or Keys.Down or Keys.Home or Keys.End or Keys.PageUp or Keys.PageDown) ApplyBrightness(serials, slider.Value); };
        title.Tag = "heading";
        row.Controls.Add(title, 0, 0); row.SetColumnSpan(title, 2);
        row.Controls.Add(value, 0, 1); row.SetColumnSpan(value, 2);
        row.Controls.Add(slider, 0, 2); row.Controls.Add(apply, 1, 2);
        brightnessPanel.Controls.Add(row); brightnessPanel.SetFlowBreak(row, true);
        brightnessControls.Add((serials, slider, value, apply));
    }
    void UpdateBrightnessControls() {
        foreach (var c in brightnessControls) {
            bool available = c.Serials.All(levels.ContainsKey);
            c.Slider.Enabled = c.Apply.Enabled = available;
            c.Slider.Minimum = MinimumBrightness(c.Serials);
            if (available && !c.Slider.Capture) c.Slider.Value = Math.Max(c.Slider.Minimum,levels[c.Serials[0]]);
            c.Value.Text = available ? c.Slider.Value + "%" + (c.Serials.Length == 1 ? " · " + RouteName(c.Serials[0]) : "") : string.Join("；", c.Serials.Where(s => !levels.ContainsKey(s)).Select(s => levelErrors.GetValueOrDefault(s, "显示器当前不可见或亮度不可用")));
        }
        foreach (var c in traySliders) {
            bool available = c.Serials.All(levels.ContainsKey);
            c.Slider.Enabled = available; c.Slider.Minimum = MinimumBrightness(c.Serials);
            string name = c.Serials.Length > 1 ? "所有显示器联动" : config.Monitors.First(m => m.Serial == c.Serials[0]).Name;
            if (available && !c.Slider.Capture) c.Slider.Value = Math.Max(c.Slider.Minimum,levels[c.Serials[0]]);
            c.Value.Text = name + (available ? "  " + c.Slider.Value + "%" : " · 不可用");
        }
    }
    static Button Button(string text, Action action) { var b = new Button { Text = text, AutoSize = true }; Appearance.Style(b); b.Click += (_, _) => action(); return b; }
    void ShowSettings() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    void BuildGrid() {
        grid.Columns.Clear(); grid.Rows.Clear();
        grid.Columns.Add("name", "组名");
        foreach (var m in config.Monitors) grid.Columns.Add(new DataGridViewComboBoxColumn { Name = m.Serial, HeaderText = m.Name, DataSource = new[] { new Choice(27,"USB-C 90W"), new Choice(15,"DP"), new Choice(17,"HDMI") }, DisplayMember = "Name", ValueMember = "Value" });
        grid.Columns.Add("shortcut", "快捷键数字 (0–9)");
        foreach (var g in config.Groups) {
            var values = new List<object> { g.Name };
            values.AddRange(config.Monitors.Select(m => (object)(g.Displays.FirstOrDefault(a => a.Serial == m.Serial)?.Input ?? 27)));
            values.Add(g.Shortcut);
            int i = grid.Rows.Add(values.ToArray()); grid.Rows[i].Tag = g.Id;
        }
        enableKeys.Checked = config.ShortcutsEnabled;
        RefreshShortcutGrid();
    }
    sealed record Choice(int Value, string Name);
    bool SaveFromGridResult() {
        if (busy) { saved.Text = "操作进行中，请稍后保存配置。"; return false; }
        try {
            grid.EndEdit();
            var next = Configuration.Parse(JsonSerializer.Serialize(config, Configuration.Json));
            next.Groups = grid.Rows.Cast<DataGridViewRow>().Select(r => new SwitchGroup {
                Id = (string)r.Tag!, Name = Convert.ToString(r.Cells[0].Value) ?? "",
                Displays = config.Monitors.Select((m,i) => new Assignment { Serial = m.Serial, Input = Convert.ToInt32(r.Cells[i+1].Value) }).ToList(),
                Shortcut = Convert.ToInt32(r.Cells[config.Monitors.Count+1].Value)
            }).ToList();
            next.ShortcutsEnabled = enableKeys.Checked;
            next.MenuBrightnessLinked = menuLayout.SelectedIndex == 1; next.BrightnessStep = (int)brightnessStep.Value;
            next.Hotkeys.RemoveAll(h => !next.ShortcutActions.Any(a => a.Id == h.Action));
            next.Validate(); Store(next); config = next;
            RefreshShortcutGrid(); RegisterKeys(); BuildMenu(); saved.Text = "配置已保存"; return true;
        } catch (Exception e) { saved.Text = "保存失败：" + e.Message; return false; }
    }
    void SaveFromGrid() => SaveFromGridResult();
    void Store(Configuration value) {
        value.Validate(); string temp = ConfigPath + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(value, Configuration.Json)); File.Move(temp, ConfigPath, true);
    }
    void UnregisterKeys() { foreach (int id in keyGroups.Keys) UnregisterHotKey(Handle,id); keyGroups.Clear(); }
    void RegisterKeys(Configuration? source = null) {
        source ??= config;
        try { source.Validate(); } catch (Exception e) { shortcuts.Text = keyStatus.Text = e.Message; return; }
        recordingAction = null; UnregisterKeys();
        var failed = new List<string>();
        if (source.ShortcutsEnabled) {
            int id = 1;
            foreach (var b in source.EffectiveHotkeys(false)) {
                if (RegisterHotKey(Handle,id,0x4000 | HotkeyCodes.Modifiers(b.Modifiers),HotkeyCodes.Codes[b.Key])) keyGroups[id] = b.Action;
                else failed.Add(source.ShortcutActions.First(a => a.Id == b.Action).Name);
                id++;
            }
        }
        appliedConfig = Configuration.Parse(JsonSerializer.Serialize(source,Configuration.Json));
        shortcuts.Text = keyStatus.Text = !source.ShortcutsEnabled ? "全局快捷键已关闭" : failed.Count == 0 ? "全局快捷键已注册（其他应用中也可使用）" : "快捷键被占用或系统拒绝：" + string.Join("、",failed);
    }
    async Task PerformShortcut(string action) {
        if (action == "brightness:restore") { ResetSoftwareDimming(); return; }
        var group = config.Groups.FirstOrDefault(g => "group:" + g.Id == action);
        if (group != null) { await ApplyGroup(group); return; }
        var adjustment = config.BrightnessActions.FirstOrDefault(a => a.Id == action);
        if (adjustment == null) return;
        await LoadBrightness();
        if (adjustment.Serials.Any(s => !levels.ContainsKey(s))) throw new Exception("目标显示器亮度不可用；快捷键未执行。");
        int target = Brightness.Adjusted(levels[adjustment.Serials[0]],adjustment.Direction * config.BrightnessStep,MinimumBrightness(adjustment.Serials) == 10);
        await SetBrightness(adjustment.Serials,target);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && recordingAction == null && keyGroups.TryGetValue(m.WParam.ToInt32(),out string? action)) _ = Run(() => PerformShortcut(action), brightness: action.StartsWith("brightness:"));
        base.WndProc(ref m);
    }
    void BuildShortcutSettings() {
        shortcutPanel.Controls.Add(new Label { Text = "状态栏亮度显示方式",AutoSize = true });
        menuLayout.Items.AddRange(["分开调节 · 每屏一条","一起调节 · 仅一条"]);
        menuLayout.SelectedIndex = config.MenuBrightnessLinked ? 1 : 0;
        shortcutPanel.Controls.Add(menuLayout); shortcutPanel.SetFlowBreak(menuLayout,true);
        shortcutPanel.Controls.Add(new Label { Text = "联动显示第一台的值，应用时设为相同比例。改变显示方式不会修改亮度。",AutoSize = true,MaximumSize = new Size(700,0) });
        shortcutPanel.SetFlowBreak(shortcutPanel.Controls[^1],true);
        settingsKeys.Checked = config.ShortcutsEnabled;
        settingsKeys.CheckedChanged += (_, _) => enableKeys.Checked = settingsKeys.Checked;
        enableKeys.CheckedChanged += (_, _) => settingsKeys.Checked = enableKeys.Checked;
        shortcutPanel.Controls.Add(settingsKeys); shortcutPanel.SetFlowBreak(settingsKeys,true);
        brightnessStep.Value = config.BrightnessStep;
        shortcutPanel.Controls.Add(new Label { Text = "每次调亮 / 调暗的百分比",AutoSize = true }); shortcutPanel.Controls.Add(brightnessStep); shortcutPanel.SetFlowBreak(brightnessStep,true);
        shortcutPanel.Controls.Add(new Label { Text = "亮度快捷键跟随每屏当前调光方式。保存后在所有应用中生效。",AutoSize = true }); shortcutPanel.SetFlowBreak(shortcutPanel.Controls[^1],true);
        shortcutGrid.Columns.Add("action","操作"); shortcutGrid.Columns.Add("key","全局快捷键");
        shortcutGrid.Columns.Add(new DataGridViewButtonColumn { Name = "record",Text = "录制",UseColumnTextForButtonValue = true,FillWeight = 35 });
        shortcutGrid.Columns.Add(new DataGridViewButtonColumn { Name = "clear",Text = "清除",UseColumnTextForButtonValue = true,FillWeight = 35 });
        shortcutGrid.CellContentClick += (_, e) => {
            if (e.RowIndex < 0) return;
            string action = (string)shortcutGrid.Rows[e.RowIndex].Tag!;
            if (e.ColumnIndex == 2) { UnregisterKeys(); recordingAction = action; recordBox.Text = "请按组合键（须包含 Ctrl、Alt 或 Win；Esc 取消）"; recordBox.Focus(); }
            if (e.ColumnIndex == 3) { CancelRecording(); SetBinding(new KeyBinding { Action = action }); }
        };
        shortcutPanel.Controls.Add(shortcutGrid); shortcutPanel.SetFlowBreak(shortcutGrid,true);
        shortcutPanel.Controls.Add(recordBox); shortcutPanel.SetFlowBreak(recordBox,true);
        shortcutPanel.Controls.Add(keyStatus); shortcutPanel.SetFlowBreak(keyStatus,true);
        shortcutPanel.Controls.Add(Button("保存配置",SaveFromGrid)); shortcutPanel.Controls.Add(saved);
        RefreshShortcutGrid();
    }
    void RefreshShortcutGrid() {
        shortcutGrid.Rows.Clear();
        foreach (var action in config.ShortcutActions) {
            int row = shortcutGrid.Rows.Add(action.Name,HotkeyCodes.Label(config.EffectiveHotkeys(false).FirstOrDefault(b => b.Action == action.Id)));
            shortcutGrid.Rows[row].Tag = action.Id;
        }
    }
    void SetBinding(KeyBinding binding) {
        config.Hotkeys.RemoveAll(b => b.Action == binding.Action); config.Hotkeys.Add(binding); RefreshShortcutGrid();
        saved.Text = "快捷键已编辑，请保存配置";
    }
    void CancelRecording() {
        if (recordingAction == null) return;
        recordingAction = null; if (appliedConfig != null) RegisterKeys(appliedConfig);
        recordBox.Text = "点击操作旁的“录制”，再按组合键。Esc 取消。";
    }
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData) {
        if (recordingAction == null) return base.ProcessCmdKey(ref msg,keyData);
        var code = keyData & Keys.KeyCode;
        if (code == Keys.Escape) { CancelRecording(); return true; }
        if (!HotkeyCodes.Codes.ContainsValue((uint)code)) return true;
        var b = new KeyBinding { Action = recordingAction,Key = HotkeyCodes.Codes.First(p => p.Value == (uint)code).Key,
            Modifiers = ((keyData & Keys.Control) != 0 ? 1 : 0) | ((keyData & Keys.Alt) != 0 ? 2 : 0) | ((keyData & Keys.Shift) != 0 ? 4 : 0) | (GetKeyState(0x5b) < 0 || GetKeyState(0x5c) < 0 ? 8 : 0) };
        try { b.Validate(); CancelRecording(); SetBinding(b); }
        catch (Exception e) { recordBox.Text = e.Message; }
        return true;
    }
    void BuildMenu() {
        traySliders.Clear();
        foreach (ToolStripItem item in menu.Items.Cast<ToolStripItem>().ToList()) item.Dispose(); menu.Items.Clear();
        foreach (var g in config.Groups) menu.Items.Add(g.Name + (config.ShortcutsEnabled ? "   " + HotkeyCodes.Label(config.EffectiveHotkeys(false).FirstOrDefault(b => b.Action == "group:" + g.Id)) : ""), null, (_, _) => _ = Run(() => ApplyGroup(g)));
        menu.Items.Add(new ToolStripSeparator());
        if (config.MenuBrightnessLinked) AddTraySlider("所有显示器联动",config.Monitors.Select(m => m.Serial).ToArray());
        else foreach (var m in config.Monitors) AddTraySlider(m.Name,[m.Serial]);
        UpdateBrightnessControls();
        menu.Items.Add(new ToolStripSeparator()); menu.Items.Add("检测 / 读取", null, (_, _) => _ = Run(RefreshDisplays));
        menu.Items.Add("亮度调节…", null, (_, _) => { tabs.SelectedIndex = 2; ShowSettings(); });
        menu.Items.Add("恢复原画面（100%）", null, (_, _) => ResetSoftwareDimming());
        menu.Items.Add("设置与日志…", null, (_, _) => ShowSettings());
        menu.Items.Add("退出", null, (_, _) => { tray.Visible = false; Application.ExitThread(); });
    }
    void AddTraySlider(string name,string[] serials) {
        var panel = new Panel { Width = 310,Height = 80,Padding = new Padding(8) };
        var label = new Label { AutoSize = false,Dock = DockStyle.Top,Height = 25,Text = name };
        var slider = new TrackBar { Minimum = MinimumBrightness(serials),Maximum = 100,TickStyle = TickStyle.None,Dock = DockStyle.Bottom,AccessibleName = name + "亮度" };
        panel.Controls.Add(label); panel.Controls.Add(slider);
        slider.ValueChanged += (_, _) => label.Text = name + "  " + slider.Value + "%";
        slider.MouseUp += (_, e) => { if (e.Button == MouseButtons.Left && slider.Enabled) ApplyBrightness(serials,slider.Value); };
        slider.KeyUp += (_, e) => { if (e.KeyCode is Keys.Left or Keys.Right or Keys.Up or Keys.Down or Keys.Home or Keys.End or Keys.PageUp or Keys.PageDown) ApplyBrightness(serials,slider.Value); };
        traySliders.Add((serials,slider,label)); menu.Items.Add(new ToolStripControlHost(panel) { AutoSize = false,Width = 320,Height = 80 });
    }
    void ApplyBrightness(string[] serials, int percent) => _ = Run(() => SetBrightness(serials,percent), brightness: true);
    async Task Run(Func<Task> action, bool brightness = false) {
        if (busy) { if (brightness && adjustingBrightness) pendingBrightness = action; return; }
        busy = true; adjustingBrightness = brightness;
        if (!brightness) { tabs.Enabled = false; menu.Enabled = false; }
        try { await action(); } catch (Exception e) { SetStatus(e.Message); }
        finally {
            busy = false; adjustingBrightness = false;
            if (!brightness) { tabs.Enabled = true; menu.Enabled = true; }
            var pending = pendingBrightness; pendingBrightness = null;
            if (pending != null) _ = Run(pending, brightness: true);
            else UpdateBrightnessControls();
        }
    }
    void SetStatus(string message) {
        status.Text = message;
        string line = $"[{DateTimeOffset.Now:O}] {message}{Environment.NewLine}";
        log.AppendText(line);
        if (log.TextLength > 60000) log.Text = log.Text[^40000..];
        try { File.AppendAllText(LogPath, line); } catch (Exception e) { saved.Text = "日志写入失败：" + e.Message; }
    }
    async Task RefreshDisplays() {
        SetStatus("正在检测显示器…");
        var result = await Task.Run(Ddc.Inspect);
        detected.Text = string.Join(Environment.NewLine, result.Select(m => $"{m.Name} · {m.Serial}：{(m.Input is int v ? Configuration.SourceName(v) : "DDC 读取失败")}"));
        SetStatus(string.Join("；", config.Monitors.Select(m => { var found = result.Where(r => r.Serial == m.Serial).ToList(); return m.Name + "：" + (found.Count != 1 ? "不可见 / 匹配不唯一" : found[0].Input is int v ? Configuration.SourceName(v) : "读取失败"); })));
        await LoadBrightness();
    }
    void ResetSoftwareDimming() {
        brightnessGeneration++; pendingBrightness = null;
        dimming.Reset();
        if (softwareDimming) {
            foreach (string serial in levels.Keys.Where(UsesSoftware).ToArray()) levels[serial] = 100;
            UpdateBrightnessControls();
        }
        SetStatus("已恢复原画面（取消本工具的软件调暗）");
    }
    void DetectHdr() {
        var desktops = Ddc.Desktops(); var states = Hdr.Detect(); hdrStates.Clear();
        foreach (var d in desktops) hdrStates[d.Serial] = states.GetValueOrDefault(d.Device);
    }
    async Task LoadBrightness() {
        DetectHdr();
        var desktops = Ddc.Desktops();
        var hard = config.Monitors.Where(m => !UsesSoftware(m.Serial)).ToList();
        foreach (var m in hard) if (dimming.Levels.ContainsKey(m.Serial)) dimming.Apply([m.Serial],100);
        var readings = hard.Count > 0 ? await Task.Run(Ddc.InspectBrightness) : [];
        levels.Clear(); levelErrors.Clear();
        foreach (var m in config.Monitors) {
            if (desktops.Count(d => d.Serial == m.Serial) != 1) { levelErrors[m.Serial] = "显示器当前不可见或匹配不唯一"; continue; }
            if (UsesSoftware(m.Serial)) { levels[m.Serial] = dimming.Levels.GetValueOrDefault(m.Serial,100); continue; }
            var matches = readings.Where(r => r.Serial == m.Serial).ToList();
            if (matches.Count != 1) { levelErrors[m.Serial] = "显示器当前不可见或序列号匹配不唯一"; continue; }
            try { levels[m.Serial] = Brightness.Percent(matches[0].Current,matches[0].Maximum); }
            catch (Exception e) { levelErrors[m.Serial] = e.Message; }
        }
        UpdateBrightnessControls();
    }
    async Task RefreshBrightness() {
        SetStatus("正在读取亮度…"); await LoadBrightness();
        SetStatus(string.Join("；", config.Monitors.Select(m => m.Name + "：" + (levels.TryGetValue(m.Serial, out int v) ? v + "%" : levelErrors.GetValueOrDefault(m.Serial, "不可用")))));
    }
    async Task SetBrightness(string[] serials, int percent) {
        int generation = brightnessGeneration;
        if (percent is < 0 or > 100 || serials.Length == 0 || serials.Any(s => !config.Monitors.Any(m => m.Serial == s))) throw new Exception("亮度或目标显示器无效。");
        DetectHdr();
        var desktops = Ddc.Desktops();
        if (serials.Any(s => desktops.Count(d => d.Serial == s) != 1)) throw new Exception("显示器不可见或匹配不唯一；本组未调节。");
        var soft = serials.Where(UsesSoftware).ToArray(); var hard = serials.Where(s => !UsesSoftware(s)).ToArray();
        if (soft.Length > 0) _ = Dimming.Opacity(percent);
        foreach (string serial in hard) dimming.Apply([serial],100);
        if (hard.Length > 0) await Execute(hard.Select(s => new Operation { Serial = s,Brightness = percent }).ToList(),$"硬件亮度 {percent}%");
        if (generation != brightnessGeneration) return;
        if (soft.Length > 0) { dimming.Apply(soft,percent); SetStatus((hard.Length == 0 ? "" : status.Text + "\n") + $"软件亮度 {percent}%（不更改 HDR）"); }
        await LoadBrightness();
    }

    async Task ApplyGroup(SwitchGroup g) {
        config.Validate(); SetStatus("正在切到 " + g.Name + "…");
        var ops = g.Displays.Select(a => new Operation { Serial = a.Serial, Input = a.Input }).ToList();
        await Execute(ops, g.Name);
    }
    async Task Execute(List<Operation> ops, string title) {
        var result = await Task.Run(() => Ddc.Apply(ops)); var lines = new List<string> { title };
        foreach (var r in result) {
            string name = config.Monitors.FirstOrDefault(m => m.Serial == r.Serial)?.Name ?? r.Serial;
            if (ops.First(o => o.Serial == r.Serial).Brightness != null) {
                if (r.Brightness is int current && r.MaxBrightness is int maximum) {
                    levels[r.Serial] = Brightness.Percent(current, maximum);
                    if (r.Error == null) lines.Add($"{name}：DDC 确认亮度 {levels[r.Serial]}%");
                } else levels.Remove(r.Serial);
                if (r.Error != null) levelErrors[r.Serial] = r.Error; else levelErrors.Remove(r.Serial);
            }
            if (r.Error != null) { lines.Add(name + "：" + r.Error); continue; }
            if (ops.First(o => o.Serial == r.Serial).Input is int target) lines.Add(name + "：" + (r.Input == target ? "DDC 确认 " + Configuration.SourceName(target) : r.Input is int actual ? "返回 " + Configuration.SourceName(actual) + "，目标 " + Configuration.SourceName(target) : "已发送 " + Configuration.SourceName(target) + "，回读不可用"));
        }
        SetStatus(string.Join(Environment.NewLine, lines));
        if (ops.Any(o => o.Input != null)) tray.ShowBalloonTip(3500, "显示器切换", status.Text, ToolTipIcon.Info);
    }
    void Import() {
        if (busy) return;
        using var p = new OpenFileDialog { Filter = "JSON 配置|*.json" };
        if (p.ShowDialog() != DialogResult.OK) return;
        try { var c = Configuration.Parse(File.ReadAllText(p.FileName)); Store(c); dimming.Reset(); config = c; menuLayout.SelectedIndex = c.MenuBrightnessLinked ? 1 : 0; brightnessStep.Value = c.BrightnessStep; BuildGrid(); BuildBrightnessControls(); RegisterKeys(); BuildMenu(); saved.Text = "已导入并保存配置"; _ = Run(RefreshDisplays); }
        catch (Exception e) { saved.Text = "导入失败：" + e.Message; }
    }
    void Export() {
        if (!SaveFromGridResult()) return;
        using var p = new SaveFileDialog { Filter = "JSON 配置|*.json", FileName = "display-groups.json" };
        if (p.ShowDialog() != DialogResult.OK) return;
        try { File.WriteAllText(p.FileName, JsonSerializer.Serialize(config, Configuration.Json)); saved.Text = "配置已导出"; } catch (Exception e) { saved.Text = e.Message; }
    }
    protected override void Dispose(bool disposing) {
        if (disposing) { Microsoft.Win32.SystemEvents.DisplaySettingsChanged -= DisplaySettingsChanged; dimming.Dispose(); foreach (int id in keyGroups.Keys) UnregisterHotKey(Handle,id); tray.Dispose(); menu.Dispose(); }
        base.Dispose(disposing);
    }
}
