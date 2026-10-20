using System.Runtime.InteropServices;
using Microsoft.Win32;
using System.Text;

namespace DisplayInputSwitch;
internal sealed class PhysicalMonitor : IDisposable {
    public IntPtr Handle;
    public string Serial = "";
    public string Name = "";
    public void Dispose() { if (Handle != IntPtr.Zero) { Ddc.DestroyPhysicalMonitor(Handle); Handle = IntPtr.Zero; } }
}
internal sealed record Outcome(string Serial, bool Ok, int? Input, bool UsbSent, string? Error);
internal static class Ddc {
    [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct MonitorInfo {
        public int Size; public Rect Monitor, Work; public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct DisplayDevice {
        public int Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Id;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Key;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct NativePhysical {
        public IntPtr Handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
    }
    internal delegate bool MonitorCallback(IntPtr monitor, IntPtr dc, ref Rect rect, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr rect, MonitorCallback callback, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, uint number, ref DisplayDevice info, uint flags);
    [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor, out uint count);
    [DllImport("dxva2.dll", CharSet = CharSet.Unicode)] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr monitor, uint count, [Out] NativePhysical[] physical);
    [DllImport("dxva2.dll")] internal static extern bool DestroyPhysicalMonitor(IntPtr monitor);
    [DllImport("dxva2.dll", SetLastError = true)] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr monitor, byte code, out uint type, out uint current, out uint max);
    [DllImport("dxva2.dll", SetLastError = true)] static extern bool SetVCPFeature(IntPtr monitor, byte code, uint value);
    static string Serial(string path) {
        var parts = path.Split('#');
        if (parts.Length < 3 || !parts[0].EndsWith("DISPLAY", StringComparison.OrdinalIgnoreCase)) return "";
        using var key = Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Enum\DISPLAY\{parts[1]}\{parts[2]}\Device Parameters");
        return key?.GetValue("EDID") is byte[] edid ? Edid.Serial(edid) : "";
    }
    public static List<PhysicalMonitor> Open() {
        var result = new List<PhysicalMonitor>();
        try {
            Exception? enumerationError = null;
            var success = EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr dc, ref Rect r, IntPtr data) => {
              try {
                var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>(), Device = "" };
                if (!GetMonitorInfo(h, ref info) || !GetNumberOfPhysicalMonitorsFromHMONITOR(h, out uint count) || count == 0 || count > 16) return true;
                var native = new NativePhysical[count];
                if (!GetPhysicalMonitorsFromHMONITOR(h, count, native)) return true;
                var opened = native.Select(p => new PhysicalMonitor { Handle = p.Handle, Name = p.Description }).ToList();
                result.AddRange(opened); // Ownership is established before registry access can throw.
                var devices = new List<DisplayDevice>();
                for (uint i = 0; i < 16; i++) {
                    var d = new DisplayDevice { Size = Marshal.SizeOf<DisplayDevice>(), Name = "", Description = "", Id = "", Key = "" };
                    if (!EnumDisplayDevices(info.Device, i, ref d, 1)) break;
                    if ((d.Flags & 1) != 0) devices.Add(d);
                }
                // shortcut: ambiguous multi-physical handles are refused until a verified mapping is available.
                if (count == 1 && devices.Count == 1) opened[0].Serial = Serial(devices[0].Id);
                return true;
              } catch (Exception e) { enumerationError = e; return false; }
            }, IntPtr.Zero);
            if (enumerationError != null) throw enumerationError;
            if (!success) throw new Exception("Windows 无法枚举显示器。");
            return result;
        } catch { result.ForEach(p => p.Dispose()); throw; }
    }
    static PhysicalMonitor Find(List<PhysicalMonitor> monitors, string serial) {
        var matches = monitors.Where(m => m.Serial == serial).ToList();
        if (matches.Count != 1 || string.IsNullOrEmpty(serial)) throw new Exception($"显示器 {serial} 不可见、缺少 EDID 序列号或匹配不唯一；未发送本组请求。");
        return matches[0];
    }
    static int Read(PhysicalMonitor m, byte code) {
        return GetVCPFeatureAndVCPFeatureReply(m.Handle, code, out _, out uint value, out _) && value <= 65535 ? (int)value : -1;
    }
    static bool Write(PhysicalMonitor m, byte code, int value) {
        bool first = SetVCPFeature(m.Handle, code, (uint)value);
        Thread.Sleep(50);
        bool second = SetVCPFeature(m.Handle, code, (uint)value);
        return first && second;
    }
    public static List<(string Serial, string Name, int? Input)> Inspect() {
        var monitors = Open();
        try { return monitors.Select(m => { int v = Read(m, 0x60); return (m.Serial, m.Name, v < 0 ? (int?)null : v & 255); }).ToList(); }
        finally { monitors.ForEach(m => m.Dispose()); }
    }
    public static (int Input, int Value) ReadUsb(string serial) {
        var monitors = Open();
        try {
            var m = Find(monitors, serial); int input = Read(m, 0x60), value = Read(m, 0xe7);
            if (input < 0) throw new Exception("无法读取 USB 显示器当前输入源。");
            return (input & 255, value);
        } finally { monitors.ForEach(m => m.Dispose()); }
    }
    public static List<Outcome> Apply(List<Operation> ops) {
        if (ops.Count is < 1 or > 8 || ops.Select(o => o.Serial).Distinct().Count() != ops.Count) throw new Exception("无效的切换计划。");
        var monitors = Open();
        try {
            var plan = ops.Select(o => (Op: o, Monitor: Find(monitors, o.Serial))).ToList();
            var usbValues = new Dictionary<string, int>();
            foreach (var (o, m) in plan) {
                if (o.Input is int target && !Configuration.IsSource(target)) throw new Exception("输入源无效。");
                if (o.UsbMask is int mask) {
                    int current = Read(m, 0xe7), input = Read(m, 0x60);
                    if (mask is <= 0 or > 65535 || o.UsbBits is not int bits || bits < 0 || (bits & ~mask) != 0 || current is < 0 or >= 0xff00 || input < 0 || (o.Input ?? (input & 255)) != o.UsbInput) throw new Exception("USB 校准与当前输入不匹配；本组未发送。");
                    int value = (current & ~mask) | bits;
                    if (value >= 0xff00) throw new Exception("USB 关联值不能是动作码；本组未发送。");
                    usbValues[o.Serial] = value;
                }
            }
            var errors = new Dictionary<string, string>();
            foreach (var (o,m) in plan) if (o.Input is int target && !Write(m, 0x60, target)) errors[o.Serial] = "DDC 发送失败，可能部分执行。";
            var usbSent = new HashSet<string>();
            foreach (var (o,m) in plan) if (usbValues.TryGetValue(o.Serial, out int value) && !errors.ContainsKey(o.Serial)) {
                if (Write(m, 0xe7, value)) usbSent.Add(o.Serial); else errors[o.Serial] = "USB 请求发送失败，视频可能已切换。";
            }
            Thread.Sleep(600);
            return plan.Select(p => { int input = Read(p.Monitor, 0x60); errors.TryGetValue(p.Op.Serial, out string? error); return new Outcome(p.Op.Serial, error == null, input < 0 ? null : input & 255, usbSent.Contains(p.Op.Serial), error); }).ToList();
        } finally { monitors.ForEach(m => m.Dispose()); }
    }
}
