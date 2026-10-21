namespace DisplayInputSwitch;

// Keep native controls, keyboard focus and accessibility; only their presentation changes.
internal static class Appearance {
    public static Color Surface => SystemInformation.HighContrast ? SystemColors.Window : Color.White;
    public static Color Canvas => SystemInformation.HighContrast ? SystemColors.Control : Color.FromArgb(245, 247, 251);
    public static Color Ink => SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(28, 39, 58);
    public static Color Muted => SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(83, 98, 119);
    public static Color Accent => SystemInformation.HighContrast ? SystemColors.Highlight : Color.FromArgb(24, 86, 195);
    public static Color Border => SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(211, 219, 230);

    public static FlowLayoutPanel Flow() {
        var panel = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoScroll = true, WrapContents = true,
            Padding = new Padding(20), BackColor = Surface };
        panel.SizeChanged += (_, _) => FitContent(panel);
        panel.ControlAdded += (_, _) => FitContent(panel);
        return panel;
    }
    static void FitContent(FlowLayoutPanel panel) {
        int available = Math.Max(0, panel.ClientSize.Width - panel.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth);
        foreach (Control control in panel.Controls) {
            int width = Math.Max(1, available - control.Margin.Horizontal);
            if (control is Label label) label.MaximumSize = new Size(width, 0);
            else if (control is TableLayoutPanel or DataGridView or TextBox) {
                control.MaximumSize = new Size(0, 0);
                if (control is TableLayoutPanel) control.MinimumSize = new Size(width, 0);
                if (control.Width != width) control.Width = width;
            }
        }
    }
    public static void Style(Control root) {
        root.ForeColor = Ink;
        switch (root) {
            case TabPage page:
                page.UseVisualStyleBackColor = false; page.BackColor = Surface;
                break;
            case Button button:
                button.AutoSize = true; button.AutoSizeMode = AutoSizeMode.GrowAndShrink;
                button.Padding = new Padding(12, 5, 12, 5); button.Margin = new Padding(0, 6, 10, 10);
                button.FlatStyle = FlatStyle.Flat; button.FlatAppearance.BorderColor = Border;
                bool primary = button.Text is "保存配置" or "应用" or "切换选中组别";
                button.BackColor = primary ? Accent : Surface;
                button.ForeColor = primary ? (SystemInformation.HighContrast ? SystemColors.HighlightText : Color.White) : Ink;
                button.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(16, 67, 158) : Canvas;
                button.FlatAppearance.MouseDownBackColor = primary ? Color.FromArgb(12, 51, 122) : Border;
                if (SystemInformation.HighContrast) {
                    button.FlatAppearance.MouseOverBackColor = SystemColors.Highlight;
                    button.FlatAppearance.MouseDownBackColor = SystemColors.Highlight;
                }
                break;
            case Label label:
                label.Margin = new Padding(0, 4, 8, 12);
                if (label.Tag as string != "heading") label.ForeColor = Muted;
                break;
            case CheckBox check:
                check.Margin = new Padding(0, 8, 12, 12);
                break;
            case TrackBar slider:
                slider.TickStyle = TickStyle.None; slider.BackColor = Surface;
                break;
            case DataGridView grid:
                grid.BackgroundColor = Surface; grid.BorderStyle = BorderStyle.None;
                grid.CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal;
                grid.GridColor = Border; grid.EnableHeadersVisualStyles = false;
                grid.ColumnHeadersBorderStyle = DataGridViewHeaderBorderStyle.None;
                grid.ColumnHeadersDefaultCellStyle.BackColor = Canvas;
                grid.ColumnHeadersDefaultCellStyle.ForeColor = Muted;
                grid.ColumnHeadersDefaultCellStyle.Padding = new Padding(10, 6, 10, 6);
                grid.ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.AutoSize;
                grid.DefaultCellStyle.BackColor = Surface;
                grid.DefaultCellStyle.ForeColor = Ink;
                grid.DefaultCellStyle.Padding = new Padding(10, 6, 10, 6);
                grid.DefaultCellStyle.SelectionBackColor = SystemInformation.HighContrast ? SystemColors.Highlight : Color.FromArgb(225, 237, 255);
                grid.DefaultCellStyle.SelectionForeColor = SystemInformation.HighContrast ? SystemColors.HighlightText : Accent;
                grid.AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.AllCells;
                break;
        }
        foreach (Control child in root.Controls) Style(child);
    }
    public static void Tabs(TabControl tabs, bool navigation) {
        tabs.DrawMode = TabDrawMode.OwnerDrawFixed;
        tabs.SizeMode = TabSizeMode.Fixed;
        tabs.ItemSize = new Size(navigation ? 140 : 170, navigation ? 48 : 40);
        tabs.DrawItem += (_, e) => {
            bool selected = e.Index == tabs.SelectedIndex;
            using var brush = new SolidBrush(selected ? Surface : Canvas);
            e.Graphics.FillRectangle(brush, e.Bounds);
            var color = selected ? Accent : Muted;
            var textRect = e.Bounds;
            int Dpi(int value) => (int)Math.Round(value * tabs.DeviceDpi / 96f);
            if (navigation) {
                string[] glyphs = ["\uE713", "\uE8A7", "\uE706", "\uE765", "\uE7F4", "\uE8A5"];
                using var font = new Font("Segoe MDL2 Assets", 12);
                var iconRect = new Rectangle(e.Bounds.X + Dpi(14), e.Bounds.Y, Dpi(22), e.Bounds.Height);
                TextRenderer.DrawText(e.Graphics, glyphs[e.Index], font, iconRect, color,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter);
                textRect.X += Dpi(38); textRect.Width -= Dpi(42);
            }
            TextRenderer.DrawText(e.Graphics, tabs.TabPages[e.Index].Text, tabs.Font, textRect, color,
                TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter | TextFormatFlags.EndEllipsis);
            if (selected) {
                using var pen = new Pen(Accent, 3 * tabs.DeviceDpi / 96f);
                e.Graphics.DrawLine(pen, e.Bounds.Left + Dpi(10), e.Bounds.Bottom - Dpi(2), e.Bounds.Right - Dpi(10), e.Bounds.Bottom - Dpi(2));
            }
            if (selected && tabs.Focused) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(e.Bounds, -5, -5));
        };
    }
    public static Panel Heading(string title, string description) {
        var panel = new Panel { Dock = DockStyle.Top, Height = 90, Padding = new Padding(20, 16, 20, 10), BackColor = Surface };
        var sub = new Label { Text = description, Dock = DockStyle.Fill, AutoEllipsis = true, ForeColor = Muted };
        var heading = new Label { Text = title, Tag = "heading", Dock = DockStyle.Top, Height = 34,
            Font = new Font("Microsoft YaHei UI", 15, FontStyle.Bold), ForeColor = Ink };
        panel.Controls.Add(sub); panel.Controls.Add(heading);
        return panel;
    }
}
