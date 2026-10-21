namespace DisplayInputSwitch;

internal static class SwitchSequence {
    public static void Send(int count, int delayMs, Action<int> send, Action<int> wait) {
        if (delayMs is < 0 or > 10000) throw new ArgumentOutOfRangeException(nameof(delayMs));
        for (int i = 0; i < count; i++) {
            if (i > 0 && delayMs > 0) wait(delayMs);
            send(i);
        }
    }
}
