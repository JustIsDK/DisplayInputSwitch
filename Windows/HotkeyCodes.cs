namespace DisplayInputSwitch;
public static class HotkeyCodes {
    public static readonly Dictionary<string,uint> Codes = Create();
    static Dictionary<string,uint> Create() {
        var result = new Dictionary<string,uint>();
        foreach (char key in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") result[key.ToString()] = key;
        for (uint n = 1; n <= 12; n++) result["F" + n] = 0x6f + n;
        foreach (var (key,code) in new[] { ("UP",0x26u),("DOWN",0x28u),("LEFT",0x25u),("RIGHT",0x27u),("SPACE",0x20u),("MINUS",0xbdu),("EQUAL",0xbbu),("COMMA",0xbcu),("PERIOD",0xbeu) }) result[key] = code;
        return result;
    }
    public static uint Modifiers(int bits) => (uint)(((bits & 1) != 0 ? 2 : 0) | ((bits & 2) != 0 ? 1 : 0) | ((bits & 4) != 0 ? 4 : 0) | ((bits & 8) != 0 ? 8 : 0));
    public static string Label(KeyBinding? b) {
        if (b == null || b.Key.Length == 0) return "未设置";
        var keys = new List<string>();
        if ((b.Modifiers & 1) != 0) keys.Add("Ctrl"); if ((b.Modifiers & 2) != 0) keys.Add("Alt");
        if ((b.Modifiers & 4) != 0) keys.Add("Shift"); if ((b.Modifiers & 8) != 0) keys.Add("Win");
        keys.Add(b.Key); return string.Join("+",keys);
    }
}
