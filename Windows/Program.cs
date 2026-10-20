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
    readonly CheckBox enableKeys = new() { Text = "启用全局快捷键：Ctrl + Alt + Shift + 组别数字", AutoSize = true };
    readonly CheckBox launchAtLogin = new() { Text = "开机启动", AutoSize = true };
    readonly Label loginStatus = new() { AutoSize = true, MaximumSize = new Size(700, 0) };
    readonly TabControl tabs = new() { Dock = DockStyle.Fill };
    readonly Dictionary<int, string> keyGroups = [];
    Configuration config;
    bool busy;
    string ConfigPath => Path.Combine(folder, "config.json");
    string LogPath => Path.Combine(folder, "switch.log");
    public SwitchForm() {
        Text = "显示器切换"; Size = new Size(860, 720); MinimumSize = new Size(760, 620); AutoScaleMode = AutoScaleMode.Dpi;
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
        var groupsPage = new TabPage("组别") { Padding = new Padding(12) };
        var groupActions = Flow(); groupActions.Dock = DockStyle.Fill;
        groupActions.Controls.Add(Button("添加组别", () => {
            if (grid.Rows.Count >= 9) return;
            var values = new List<object> { "新组别" }; values.AddRange(config.Monitors.Select(_ => (object)27)); values.AddRange(new object[] { "keep", 0 });
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
        groupActions.Controls.Add(saved);
        groupsPage.Controls.Add(groupActions); groupsPage.Controls.Add(grid); tabs.TabPages.Add(groupsPage);
        var monitorPage = new TabPage("显示器") { Padding = new Padding(12) };
        var monitors = Flow(); monitors.Controls.Add(Button("检测 / 读取", () => _ = Run(RefreshDisplays)));
        monitors.SetFlowBreak(monitors.Controls[^1], true); monitors.Controls.Add(detected);
        monitors.SetFlowBreak(detected, true); monitors.Controls.Add(new Label { Text = "按 EDID 序列号识别显示器。更换显示器：导出 JSON，修改 monitors、groups 的 serial 和 usbSerial 后导入。", AutoSize = true, MaximumSize = new Size(700, 0) });
        monitorPage.Controls.Add(monitors); tabs.TabPages.Add(monitorPage);
        var usbPage = new TabPage("USB") { Padding = new Padding(12) };
        var usb = Flow(); usb.Controls.Add(new Label { Text = "QX USB 外设：Mac 走 90W USB-C；Windows 走独立 USB-C 数据上行。", AutoSize = true }); usb.SetFlowBreak(usb.Controls[^1], true);
        foreach (var owner in new[] { "mac", "windows" }) usb.Controls.Add(Button("USB → " + (owner == "mac" ? "Mac" : "Windows"), () => _ = Run(() => SwitchUsb(owner))));
        usb.SetFlowBreak(usb.Controls[^1], true);
        usb.Controls.Add(new Label { Text = "USB 控制需要校准。对同一视频输入，用显示器菜单分别将 USB 分配给 Mac 和 Windows，再读取对应状态。只有两次映射读数有效且不同才可启用。USB 不支持时，组别仍切换视频并报告 USB 未执行。", AutoSize = true, MaximumSize = new Size(700, 0) });
        usb.SetFlowBreak(usb.Controls[^1], true);
        foreach (var owner in new[] { "mac", "windows" }) usb.Controls.Add(Button("读取 USB 属于 " + (owner == "mac" ? "Mac" : "Windows") + " 的状态", () => _ = Run(() => CaptureUsb(owner))));
        usb.SetFlowBreak(usb.Controls[^1], true);
        usb.Controls.Add(Button("保存校准", () => { try { Store(config); saved.Text = "配置已保存"; } catch (Exception e) { SetStatus(e.Message); } }));
        usbPage.Controls.Add(usb); tabs.TabPages.Add(usbPage);
        var logPage = new TabPage("日志"); logPage.Controls.Add(log); tabs.TabPages.Add(logPage);
        grid.DataError += (_, e) => { e.ThrowException = false; SetStatus("组别字段值无效，请重新选择。"); };
        tray.Text = "显示器切换"; tray.Icon = SystemIcons.Application; tray.ContextMenuStrip = menu; tray.Visible = true;
        tray.DoubleClick += (_, _) => ShowSettings();
        FormClosing += (_, e) => { e.Cancel = true; Hide(); };
        BuildGrid(); RegisterKeys(); BuildMenu();
        if (loadError != null) SetStatus(loadError); else SetStatus("已在托盘运行。DDC 回读仅确认输入源；画面和 USB 归属需实际观察。");
        _ = Run(RefreshDisplays);
    }
    static FlowLayoutPanel Flow() => new() { Dock = DockStyle.Fill, AutoScroll = true, WrapContents = true, Padding = new Padding(8) };
    void RefreshLoginStatus() {
        try {
            launchAtLogin.Checked = Startup.IsRegistered();
            launchAtLogin.Enabled = true;
            loginStatus.Text = launchAtLogin.Checked ? "已注册当前路径的启动项；若被系统禁用，请在“启动应用”中启用。" : "当前路径未注册开机启动。";
        } catch (Exception e) { launchAtLogin.Enabled = false; loginStatus.Text = "无法读取启动项：" + e.Message; }
    }
    static Button Button(string text, Action action) { var b = new Button { Text = text, AutoSize = true, Margin = new Padding(4,8,4,8) }; b.Click += (_, _) => action(); return b; }
    void ShowSettings() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    void BuildGrid() {
        grid.Columns.Clear(); grid.Rows.Clear();
        grid.Columns.Add("name", "组名");
        foreach (var m in config.Monitors) grid.Columns.Add(new DataGridViewComboBoxColumn { Name = m.Serial, HeaderText = m.Name, DataSource = new[] { new Choice(27,"USB-C 90W"), new Choice(15,"DP"), new Choice(17,"HDMI") }, DisplayMember = "Name", ValueMember = "Value" });
        grid.Columns.Add(new DataGridViewComboBoxColumn { Name = "usb", HeaderText = "QX USB 归属", DataSource = new[] { new UsbChoice("keep","保持现状"), new UsbChoice("mac","Mac"), new UsbChoice("windows","Windows") }, DisplayMember = "Name", ValueMember = "Value" });
        grid.Columns.Add("shortcut", "快捷键数字 (0–9)");
        foreach (var g in config.Groups) {
            var values = new List<object> { g.Name };
            values.AddRange(config.Monitors.Select(m => (object)(g.Displays.FirstOrDefault(a => a.Serial == m.Serial)?.Input ?? 27)));
            values.Add(g.Usb); values.Add(g.Shortcut);
            int i = grid.Rows.Add(values.ToArray()); grid.Rows[i].Tag = g.Id;
        }
        enableKeys.Checked = config.ShortcutsEnabled;
    }
    sealed record Choice(int Value, string Name);
    sealed record UsbChoice(string Value, string Name);
    bool SaveFromGridResult() {
        try {
            grid.EndEdit();
            var next = Configuration.Parse(JsonSerializer.Serialize(config, Configuration.Json));
            next.Groups = grid.Rows.Cast<DataGridViewRow>().Select(r => new SwitchGroup {
                Id = (string)r.Tag!, Name = Convert.ToString(r.Cells[0].Value) ?? "",
                Displays = config.Monitors.Select((m,i) => new Assignment { Serial = m.Serial, Input = Convert.ToInt32(r.Cells[i+1].Value) }).ToList(),
                Usb = Convert.ToString(r.Cells[config.Monitors.Count+1].Value) ?? "keep", Shortcut = Convert.ToInt32(r.Cells[config.Monitors.Count+2].Value)
            }).ToList();
            next.ShortcutsEnabled = enableKeys.Checked; next.Validate(); Store(next); config = next;
            RegisterKeys(); BuildMenu(); saved.Text = "配置已保存"; return true;
        } catch (Exception e) { saved.Text = "保存失败：" + e.Message; return false; }
    }
    void SaveFromGrid() => SaveFromGridResult();
    void Store(Configuration value) {
        value.Validate(); string temp = ConfigPath + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(value, Configuration.Json)); File.Move(temp, ConfigPath, true);
    }
    void RegisterKeys() {
        foreach (int id in keyGroups.Keys) UnregisterHotKey(Handle, id); keyGroups.Clear();
        var failed = new List<string>();
        if (config.ShortcutsEnabled) foreach (var g in config.Groups.Where(g => g.Shortcut != 0)) {
            if (RegisterHotKey(Handle, g.Shortcut, 0x4000 | 1 | 2 | 4, (uint)(0x30 + g.Shortcut))) keyGroups[g.Shortcut] = g.Id;
            else failed.Add(g.Name);
        }
        shortcuts.Text = !config.ShortcutsEnabled ? "全局快捷键已关闭" : failed.Count == 0 ? "快捷键已注册" : "快捷键注册失败：" + string.Join("、",failed);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && keyGroups.TryGetValue(m.WParam.ToInt32(), out string? id)) {
            var g = config.Groups.FirstOrDefault(g => g.Id == id); if (g != null) _ = Run(() => ApplyGroup(g));
        }
        base.WndProc(ref m);
    }
    void BuildMenu() {
        foreach (ToolStripItem item in menu.Items.Cast<ToolStripItem>().ToList()) item.Dispose(); menu.Items.Clear();
        foreach (var g in config.Groups) menu.Items.Add(g.Name + (config.ShortcutsEnabled && g.Shortcut != 0 ? $"   Ctrl+Alt+Shift+{g.Shortcut}" : ""), null, (_, _) => _ = Run(() => ApplyGroup(g)));
        menu.Items.Add(new ToolStripSeparator());
        foreach (string owner in new[] { "mac", "windows" }) menu.Items.Add("USB → " + (owner == "mac" ? "Mac" : "Windows"), null, (_, _) => _ = Run(() => SwitchUsb(owner)));
        menu.Items.Add(new ToolStripSeparator()); menu.Items.Add("检测 / 读取", null, (_, _) => _ = Run(RefreshDisplays));
        menu.Items.Add("设置与日志…", null, (_, _) => ShowSettings());
        menu.Items.Add("退出", null, (_, _) => { tray.Visible = false; Application.ExitThread(); });
    }
    async Task Run(Func<Task> action) {
        if (busy) return; busy = true; tabs.Enabled = false; menu.Enabled = false;
        try { await action(); } catch (Exception e) { SetStatus(e.Message); }
        finally { busy = false; tabs.Enabled = true; menu.Enabled = true; }
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
    }
    async Task ApplyGroup(SwitchGroup g) {
        config.Validate(); SetStatus("正在切到 " + g.Name + "…");
        var ops = g.Displays.Select(a => new Operation { Serial = a.Serial, Input = a.Input }).ToList(); string warning = "";
        if (g.Usb != "keep") {
            int input = g.Displays.FirstOrDefault(a => a.Serial == config.UsbSerial)?.Input ?? (await Task.Run(() => Ddc.ReadUsb(config.UsbSerial))).Input;
            try {
                var usb = config.UsbOperation(input, g.Usb);
                var op = ops.FirstOrDefault(o => o.Serial == config.UsbSerial);
                if (op == null) ops.Add(usb); else { op.UsbMask = usb.UsbMask; op.UsbBits = usb.UsbBits; op.UsbInput = usb.UsbInput; }
            } catch (Exception e) { warning = "USB 未执行：" + e.Message + " 目标：" + Configuration.UsbName(g.Usb); }
        }
        await Execute(ops, g.Name, warning);
    }
    async Task SwitchUsb(string owner) {
        config.Validate(); SetStatus("正在切换 USB…");
        int input = (await Task.Run(() => Ddc.ReadUsb(config.UsbSerial))).Input;
        await Execute([config.UsbOperation(input, owner)], "USB → " + Configuration.UsbName(owner));
    }
    async Task Execute(List<Operation> ops, string title, string warning = "") {
        var result = await Task.Run(() => Ddc.Apply(ops)); var lines = new List<string> { title };
        foreach (var r in result) {
            string name = config.Monitors.FirstOrDefault(m => m.Serial == r.Serial)?.Name ?? r.Serial;
            if (r.Error != null) { lines.Add(name + "：" + r.Error); continue; }
            if (ops.First(o => o.Serial == r.Serial).Input is int target) lines.Add(name + "：" + (r.Input == target ? "DDC 确认 " + Configuration.SourceName(target) : r.Input is int actual ? "返回 " + Configuration.SourceName(actual) + "，目标 " + Configuration.SourceName(target) : "已发送 " + Configuration.SourceName(target) + "，回读不可用"));
            if (r.UsbSent) lines.Add("USB 关联请求已发送，外设归属尚需实际确认");
        }
        if (warning != "") lines.Add(warning); SetStatus(string.Join(Environment.NewLine, lines));
        tray.ShowBalloonTip(3500, "显示器切换", status.Text, ToolTipIcon.Info);
    }
    async Task CaptureUsb(string owner) {
        var (input,value) = await Task.Run(() => Ddc.ReadUsb(config.UsbSerial));
        if (value is < 0 or >= 0xff00) throw new Exception($"此固件未返回可用 USB 关联映射（E7={value}）；没有写入显示器，暂不能启用独立 USB 控制。");
        var p = config.UsbProfiles.FirstOrDefault(p => p.Input == input);
        if (p == null) { p = new UsbProfile { Input = input }; config.UsbProfiles.Add(p); }
        if (owner == "mac") p.Mac = value; else p.Windows = value;
        SetStatus($"已读取 {Configuration.SourceName(input)} 下 USB 属于 {Configuration.UsbName(owner)} 的关联值：{value}。请保存校准。");
    }
    void Import() {
        using var p = new OpenFileDialog { Filter = "JSON 配置|*.json" };
        if (p.ShowDialog() != DialogResult.OK) return;
        try { var c = Configuration.Parse(File.ReadAllText(p.FileName)); Store(c); config = c; BuildGrid(); RegisterKeys(); BuildMenu(); saved.Text = "已导入并保存配置"; }
        catch (Exception e) { saved.Text = "导入失败：" + e.Message; }
    }
    void Export() {
        if (!SaveFromGridResult()) return;
        using var p = new SaveFileDialog { Filter = "JSON 配置|*.json", FileName = "display-groups.json" };
        if (p.ShowDialog() != DialogResult.OK) return;
        try { File.WriteAllText(p.FileName, JsonSerializer.Serialize(config, Configuration.Json)); saved.Text = "配置已导出"; } catch (Exception e) { saved.Text = e.Message; }
    }
    protected override void Dispose(bool disposing) {
        if (disposing) { foreach (int id in keyGroups.Keys) UnregisterHotKey(Handle,id); tray.Dispose(); menu.Dispose(); }
        base.Dispose(disposing);
    }
}
