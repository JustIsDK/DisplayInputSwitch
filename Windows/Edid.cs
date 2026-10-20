using System.Text;
namespace DisplayInputSwitch;
public static class Edid {
    public static string Serial(byte[] bytes) {
        if (bytes.Length < 128) return "";
        for (int i = 54; i <= 108; i += 18)
            if (bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 0xff)
                return Encoding.ASCII.GetString(bytes, i+5, 13).Trim('\0', ' ', '\r', '\n');
        uint number = BitConverter.ToUInt32(bytes, 12);
        return number == 0 ? "" : number.ToString();
    }
}
