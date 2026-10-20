namespace DisplayInputSwitch;

// Click-through shade approach adapted from MonitorControl (MIT, Copyright © 2017).
// Windows uses layered windows in place of AppKit; see vendor/MonitorControl/LICENSE.
internal sealed class SoftwareDimming : IDisposable {
    sealed class Shade : Form {
        public Shade() {
            FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false;
            BackColor = Color.Black; TopMost = true; StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
        }
        protected override bool ShowWithoutActivation => true;
        protected override CreateParams CreateParams {
            get {
                var p = base.CreateParams;
                p.ExStyle |= 0x80000 | 0x20 | 0x80 | 0x08000000; // Layered, click-through, tool window, no activation.
                return p;
            }
        }
        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x0084) { m.Result = new IntPtr(-1); return; }
            base.WndProc(ref m);
        }
    }
    readonly Dictionary<string, Shade> shades = [];
    public readonly Dictionary<string, int> Levels = [];
    public void Apply(string[] serials, int percent) {
        _ = Dimming.Opacity(percent);
        var screens = Ddc.Desktops();
        if (serials.Length == 0 || serials.Distinct().Count() != serials.Length || serials.Any(s => screens.Count(d => d.Serial == s) != 1))
            throw new Exception("显示器不可见或匹配不唯一；本组未调暗。");
        foreach (string serial in serials) {
            if (percent == 100) { Remove(serial); continue; }
            if (!shades.TryGetValue(serial, out var shade)) { shade = new Shade(); shades.Add(serial, shade); }
            shade.Bounds = screens.Single(d => d.Serial == serial).Bounds;
            shade.Opacity = Dimming.Opacity(percent);
            shade.Show();
            Levels[serial] = percent;
        }
    }
    void Remove(string serial) {
        if (shades.Remove(serial, out var shade)) { shade.Close(); shade.Dispose(); }
        Levels.Remove(serial);
    }
    public void Reconcile() {
        var screens = Ddc.Desktops();
        foreach (string serial in shades.Keys.ToArray()) {
            var matches = screens.Where(d => d.Serial == serial).ToList();
            if (matches.Count == 1) shades[serial].Bounds = matches[0].Bounds;
            else Remove(serial);
        }
    }
    public void Reset() { foreach (string serial in shades.Keys.ToArray()) Remove(serial); }
    public void Dispose() => Reset();
}
