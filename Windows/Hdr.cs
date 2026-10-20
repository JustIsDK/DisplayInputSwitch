using System.Runtime.InteropServices;

namespace DisplayInputSwitch;
internal static class Hdr {
    [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct Source { public Luid Adapter; public uint Id, ModeIndex, Flags; }
    [StructLayout(LayoutKind.Sequential)] struct Target {
        public Luid Adapter;
        public uint Id, ModeIndex, Technology, Rotation, Scaling, RefreshNumerator, RefreshDenominator, ScanLine;
        public int Available; public uint Flags;
    }
    [StructLayout(LayoutKind.Sequential)] struct DisplayPath { public Source Source; public Target Target; public uint Flags; }
    [StructLayout(LayoutKind.Explicit, Size = 64)] struct Mode { [FieldOffset(0)] public uint Type; }
    [StructLayout(LayoutKind.Sequential)] struct Header { public uint Type, Size; public Luid Adapter; public uint Id; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct SourceName {
        public Header Header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name;
    }
    [StructLayout(LayoutKind.Sequential)] struct ColorInfo { public Header Header; public uint Flags, Encoding, Bits; }
    [StructLayout(LayoutKind.Sequential)] struct ColorInfo2 { public Header Header; public uint Flags, Encoding, Bits, ActiveMode; }
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint pathCount, [Out] DisplayPath[] paths, ref uint modeCount, [Out] Mode[] modes, IntPtr topology);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int GetSourceName(ref SourceName packet);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int GetColorInfo(ref ColorInfo packet);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int GetColorInfo2(ref ColorInfo2 packet);
    internal static bool ValidLayout() => Marshal.SizeOf<Luid>() == 8 && Marshal.SizeOf<Source>() == 20 && Marshal.SizeOf<Target>() == 48 && Marshal.SizeOf<DisplayPath>() == 72 && Marshal.SizeOf<Mode>() == 64 && Marshal.SizeOf<SourceName>() == 84 && Marshal.SizeOf<ColorInfo>() == 32 && Marshal.SizeOf<ColorInfo2>() == 36;
    internal static bool? ActiveHdr(uint mode) => mode <= 2 ? mode == 2 : null;
    public static Dictionary<string, bool?> Detect() {
        var result = new Dictionary<string, bool?>(StringComparer.OrdinalIgnoreCase);
        if (!ValidLayout()) return result;
        // Query the active topology. Hardware HDR capability alone does not indicate HDR is on.
        for (int attempt = 0; attempt < 3; attempt++) {
            if (GetDisplayConfigBufferSizes(2,out uint paths,out uint modes) != 0 || paths > 256 || modes > 1024) return result;
            var pathData = new DisplayPath[paths]; var modeData = new Mode[modes];
            int code = QueryDisplayConfig(2,ref paths,pathData,ref modes,modeData,IntPtr.Zero);
            if (code == 122) continue; // Topology changed between the size and data queries.
            if (code != 0) return result;
            foreach (var path in pathData.Take((int)paths)) {
                var source = new SourceName { Header = new Header { Type = 1,Size = (uint)Marshal.SizeOf<SourceName>(),Adapter = path.Source.Adapter,Id = path.Source.Id },Name = "" };
                if (GetSourceName(ref source) != 0) continue;
                var modern = new ColorInfo2 { Header = new Header { Type = 15,Size = (uint)Marshal.SizeOf<ColorInfo2>(),Adapter = path.Target.Adapter,Id = path.Target.Id } };
                bool? enabled;
                if (GetColorInfo2(ref modern) == 0) enabled = ActiveHdr(modern.ActiveMode);
                else {
                    var info = new ColorInfo { Header = new Header { Type = 9,Size = (uint)Marshal.SizeOf<ColorInfo>(),Adapter = path.Target.Adapter,Id = path.Target.Id } };
                    // Older API conflates advanced color and HDR; an enforced WCG mode is ambiguous.
                    enabled = GetColorInfo(ref info) == 0 && (info.Flags & 4) == 0 ? (info.Flags & 2) != 0 : null;
                }
                if (result.TryGetValue(source.Name,out var previous) && previous != enabled) enabled = null;
                result[source.Name] = enabled;
            }
            return result;
        }
        return result;
    }
}
