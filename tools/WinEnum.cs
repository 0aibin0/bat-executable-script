using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class WinEnum {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    public static List<string> List() {
        var res = new List<string>();
        EnumWindows((h, p) => {
            if (!IsWindowVisible(h)) return true;
            var t = new StringBuilder(512);
            GetWindowTextW(h, t, 512);
            string title = t.ToString();
            if (title.Length == 0) return true;
            var c = new StringBuilder(256);
            GetClassNameW(h, c, 256);
            uint pid; GetWindowThreadProcessId(h, out pid);
            string pname = "?";
            try { pname = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
            res.Add(string.Format("{0}\t{1}\t{2}\t{3}", pid, pname, c.ToString(), title));
            return true;
        }, IntPtr.Zero);
        return res;
    }
}
