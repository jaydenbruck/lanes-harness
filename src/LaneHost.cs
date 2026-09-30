// LaneHost — the per-lane ConPTY owner for Lanes Harness.
//
// One process per lane. It creates the pseudoconsole, spawns the real CLI (claude / codex / grok / anything)
// inside it, tees every byte to <laneDir>\console.log as it arrives, keeps <laneDir>\state.json
// current, serves a named pipe (\\.\pipe\lanes-<name>) so the head agent, the visible Windows
// Terminal tab and the web viewer can type into the same PTY and watch the same bytes, and appends
// a labelled event row to the owning head's queue when the lane needs input, finishes, stalls or dies.
//
// Why a process per lane and not one supervisor owning a hundred PTYs: a pseudoconsole cannot outlive
// the process that created it (closing it terminates the attached clients), so the only way to make
// "the supervisor was killed" survivable is to keep the PTY owner tiny, boring and separate. Everything
// stateful is on disk; the supervisor is a stateless coordinator that reattaches through the pipes.
//
// Compiled with the in-box .NET Framework 4.8 csc.exe (C# 5). No SDK, no admin, nothing to install.
//
// Verbs:
//   LaneHost run    --name N --dir D --cwd C [--cols 160 --rows 45 --head H --kind claude|codex|grok|cursor|other
//                   --stall-min 10 --model M --brief B --session S --meta-json J] -- <command line>
//   LaneHost attach <name> [--pipe P] [--tail-bytes 65536]        console client (runs in a WT tab)
//   LaneHost hook   <laneDir> [json]                                claude hook / codex notify target
//   LaneHost serve  [--root <LANES_HOME>\lanes] [--www <viewerDir>] [--port 7342] [--heads <LANES_HOME>\heads]
//
// LANES_HOME defaults to %LOCALAPPDATA%\lanes; LANES_ROOT and LANES_HEADS_ROOT override its two halves.
//   LaneHost probe                                                  prints idle-memory probe and exits

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace LanesHarness
{
    // Where lanes and head queues live. The PowerShell module resolves the same way.
    static class Paths
    {
        public static string Home()
        {
            string h = Environment.GetEnvironmentVariable("LANES_HOME");
            if (!string.IsNullOrEmpty(h)) return h;
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "lanes");
        }
        public static string LanesRoot()
        {
            string r = Environment.GetEnvironmentVariable("LANES_ROOT");
            return string.IsNullOrEmpty(r) ? Path.Combine(Home(), "lanes") : r;
        }
        public static string HeadsRoot()
        {
            string r = Environment.GetEnvironmentVariable("LANES_HEADS_ROOT");
            return string.IsNullOrEmpty(r) ? Path.Combine(Home(), "heads") : r;
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Win32
    // ------------------------------------------------------------------------------------------------
    static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct COORD { public short X; public short Y; public COORD(short x, short y) { X = x; Y = y; } }

        [StructLayout(LayoutKind.Sequential)]
        public struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public int bInheritHandle; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct STARTUPINFO
        {
            public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
            public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars; public int dwYCountChars;
            public int dwFillAttribute; public int dwFlags; public short wShowWindow; public short cbReserved2;
            public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }

        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct IO_COUNTERS { public ulong ReadOperationCount; public ulong WriteOperationCount; public ulong OtherOperationCount; public ulong ReadTransferCount; public ulong WriteTransferCount; public ulong OtherTransferCount; }
        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo; public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct CONSOLE_SCREEN_BUFFER_INFO { public COORD dwSize; public COORD dwCursorPosition; public short wAttributes; public SMALL_RECT srWindow; public COORD dwMaximumWindowSize; }
        [StructLayout(LayoutKind.Sequential)]
        public struct SMALL_RECT { public short Left; public short Top; public short Right; public short Bottom; }

        public const int PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;
        public const int EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        public const int CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
        public const int JobObjectExtendedLimitInformation = 9;
        public const int STD_INPUT_HANDLE = -10, STD_OUTPUT_HANDLE = -11;
        public const uint ENABLE_PROCESSED_INPUT = 0x1, ENABLE_LINE_INPUT = 0x2, ENABLE_ECHO_INPUT = 0x4, ENABLE_VIRTUAL_TERMINAL_INPUT = 0x200, ENABLE_WINDOW_INPUT = 0x8;
        public const uint ENABLE_PROCESSED_OUTPUT = 0x1, ENABLE_WRAP_AT_EOL_OUTPUT = 0x2, ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x4, DISABLE_NEWLINE_AUTO_RETURN = 0x8;

        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CreatePipe(out SafeFileHandle hReadPipe, out SafeFileHandle hWritePipe, ref SECURITY_ATTRIBUTES lpPipeAttributes, int nSize);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern int CreatePseudoConsole(COORD size, SafeFileHandle hInput, SafeFileHandle hOutput, uint dwFlags, out IntPtr phPC);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern int ResizePseudoConsole(IntPtr hPC, COORD size);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern void ClosePseudoConsole(IntPtr hPC);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcessW(string lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, int dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr hObject);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr CreateJobObjectW(IntPtr lpJobAttributes, string lpName);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInfoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpJobObjectInfo, int cbJobObjectInfoLength);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetExitCodeProcess(IntPtr hProcess, out int lpExitCode);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int nStdHandle);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetStdHandle(int nStdHandle, IntPtr hHandle);
        public const int STD_ERROR_HANDLE = -12;
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleScreenBufferInfo(IntPtr hConsoleOutput, out CONSOLE_SCREEN_BUFFER_INFO lpConsoleScreenBufferInfo);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleOutputCP(uint wCodePageID);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCP(uint wCodePageID);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetProcessTimes(IntPtr hProcess, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(ConsoleCtrlDelegate handler, bool add);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();
        public delegate bool ConsoleCtrlDelegate(int ctrlType);
    }

    // ------------------------------------------------------------------------------------------------
    // Tiny JSON (enough for state.json, events, hook payloads)
    // ------------------------------------------------------------------------------------------------
    static class Json
    {
        public static string Str(string s)
        {
            if (s == null) return "null";
            var sb = new StringBuilder(s.Length + 2); sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.AppendFormat("\\u{0:x4}", (int)c); else sb.Append(c); break;
                }
            }
            sb.Append('"'); return sb.ToString();
        }
        public static string Obj(params object[] kv)
        {
            var sb = new StringBuilder("{");
            for (int i = 0; i + 1 < kv.Length; i += 2)
            {
                if (i > 0) sb.Append(',');
                sb.Append(Str((string)kv[i])).Append(':').Append(Val(kv[i + 1]));
            }
            return sb.Append('}').ToString();
        }
        public static string Val(object v)
        {
            if (v == null) return "null";
            if (v is string) return Str((string)v);
            if (v is bool) return (bool)v ? "true" : "false";
            if (v is int || v is long || v is short) return Convert.ToString(v, CultureInfo.InvariantCulture);
            if (v is double) return ((double)v).ToString("R", CultureInfo.InvariantCulture);
            if (v is RawJson) return ((RawJson)v).Text;
            if (v is Dictionary<string, object>)
            {
                var d = (Dictionary<string, object>)v; var sb = new StringBuilder("{"); bool first = true;
                foreach (var kv in d) { if (!first) sb.Append(','); first = false; sb.Append(Str(kv.Key)).Append(':').Append(Val(kv.Value)); }
                return sb.Append('}').ToString();
            }
            if (v is List<object>)
            {
                var l = (List<object>)v; var sb = new StringBuilder("["); bool first = true;
                foreach (var x in l) { if (!first) sb.Append(','); first = false; sb.Append(Val(x)); }
                return sb.Append(']').ToString();
            }
            return Str(v.ToString());
        }
        public class RawJson { public string Text; public RawJson(string t) { Text = t; } }

        // Parser
        public static object Parse(string s) { int i = 0; var v = ParseValue(s, ref i); return v; }
        static void Ws(string s, ref int i) { while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++; }
        static object ParseValue(string s, ref int i)
        {
            Ws(s, ref i); if (i >= s.Length) throw new FormatException("eof");
            char c = s[i];
            if (c == '{')
            {
                i++; var d = new Dictionary<string, object>(); Ws(s, ref i);
                if (i < s.Length && s[i] == '}') { i++; return d; }
                while (true)
                {
                    Ws(s, ref i); string k = ParseString(s, ref i); Ws(s, ref i);
                    if (i >= s.Length || s[i] != ':') throw new FormatException("colon"); i++;
                    d[k] = ParseValue(s, ref i); Ws(s, ref i);
                    if (i >= s.Length) throw new FormatException("eof in object");
                    if (s[i] == ',') { i++; continue; }
                    if (s[i] == '}') { i++; return d; }
                    throw new FormatException("obj");
                }
            }
            if (c == '[')
            {
                i++; var l = new List<object>(); Ws(s, ref i);
                if (i < s.Length && s[i] == ']') { i++; return l; }
                while (true)
                {
                    l.Add(ParseValue(s, ref i)); Ws(s, ref i);
                    if (i >= s.Length) throw new FormatException("eof in array");
                    if (s[i] == ',') { i++; continue; }
                    if (s[i] == ']') { i++; return l; }
                    throw new FormatException("arr");
                }
            }
            if (c == '"') return ParseString(s, ref i);
            if (s.Length - i >= 4 && string.CompareOrdinal(s, i, "true", 0, 4) == 0) { i += 4; return true; }
            if (s.Length - i >= 5 && string.CompareOrdinal(s, i, "false", 0, 5) == 0) { i += 5; return false; }
            if (s.Length - i >= 4 && string.CompareOrdinal(s, i, "null", 0, 4) == 0) { i += 4; return null; }
            int start = i; while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
            string num = s.Substring(start, i - start);
            if (num.Length == 0) throw new FormatException("unexpected character at " + i);
            long lv; if (long.TryParse(num, NumberStyles.Integer, CultureInfo.InvariantCulture, out lv)) return lv;
            double dv; if (double.TryParse(num, NumberStyles.Float, CultureInfo.InvariantCulture, out dv)) return dv;
            throw new FormatException("bad number " + num);
        }
        static string ParseString(string s, ref int i)
        {
            if (s[i] != '"') throw new FormatException("str"); i++;
            var sb = new StringBuilder();
            while (i < s.Length)
            {
                char c = s[i++];
                if (c == '"') return sb.ToString();
                if (c == '\\')
                {
                    if (i >= s.Length) throw new FormatException("dangling escape");
                    char e = s[i++];
                    switch (e)
                    {
                        case 'n': sb.Append('\n'); break; case 'r': sb.Append('\r'); break; case 't': sb.Append('\t'); break;
                        case 'b': sb.Append('\b'); break; case 'f': sb.Append('\f'); break; case '/': sb.Append('/'); break;
                        case '\\': sb.Append('\\'); break; case '"': sb.Append('"'); break;
                        case 'u':
                            {
                                if (i + 4 > s.Length) throw new FormatException("short unicode escape");
                                int cp; if (!int.TryParse(s.Substring(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out cp)) throw new FormatException("bad unicode escape");
                                sb.Append((char)cp); i += 4; break;
                            }
                        default: sb.Append(e); break;
                    }
                }
                else sb.Append(c);
            }
            throw new FormatException("unterminated");
        }
        public static string GetStr(object o, params string[] path)
        {
            object cur = o;
            foreach (var p in path)
            {
                var d = cur as Dictionary<string, object>; if (d == null || !d.ContainsKey(p)) return null; cur = d[p];
            }
            if (cur == null) return null;
            if (cur is string) return (string)cur;
            return Val(cur);
        }
        public static object Get(object o, params string[] path)
        {
            object cur = o;
            foreach (var p in path) { var d = cur as Dictionary<string, object>; if (d == null || !d.ContainsKey(p)) return null; cur = d[p]; }
            return cur;
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Frames on the lane pipe: [type:1][len:4 LE][payload]
    // ------------------------------------------------------------------------------------------------
    static class Frame
    {
        public const byte Input = (byte)'I';      // client -> host: raw bytes to the PTY, written atomically
        public const byte Resize = (byte)'R';     // client -> host: cols(u16) rows(u16)
        public const byte Subscribe = (byte)'S';  // client -> host: int64 offset to start from (-N = last N bytes)
        public const byte Kill = (byte)'K';       // client -> host: utf8 mode: "soft" | "hard"
        public const byte Query = (byte)'Q';      // client -> host: reply J with state json
        public const byte Output = (byte)'O';     // host -> client: PTY output bytes
        public const byte Exit = (byte)'X';       // host -> client: utf8 exit code
        public const byte JsonT = (byte)'J';      // host -> client: state json
        public const byte Gap = (byte)'G';        // host -> client: subscriber fell behind; payload = bytes dropped (utf8)
        public const byte Wake = (byte)'H';       // client -> host: "look at hooks.jsonl now" (sent by the hook verb)
        public const byte Paste = (byte)'P';      // client -> host: utf8 text typed as one message; a trailing CR submits it.
                                                  //   Bracketed when the CLI asked for it; the whole thing is one locked write.

        public static void Write(Stream s, byte type, byte[] payload, int off, int len)
        {
            var hdr = new byte[5]; hdr[0] = type; hdr[1] = (byte)len; hdr[2] = (byte)(len >> 8); hdr[3] = (byte)(len >> 16); hdr[4] = (byte)(len >> 24);
            s.Write(hdr, 0, 5); if (len > 0) s.Write(payload, off, len); s.Flush();
        }
        public static void Write(Stream s, byte type, byte[] payload) { Write(s, type, payload, 0, payload == null ? 0 : payload.Length); }
        public static bool Read(Stream s, out byte type, out byte[] payload)
        {
            type = 0; payload = null; var hdr = new byte[5];
            if (!ReadFull(s, hdr, 5)) return false;
            type = hdr[0]; int len = hdr[1] | (hdr[2] << 8) | (hdr[3] << 16) | (hdr[4] << 24);
            if (len < 0 || len > 64 * 1024 * 1024) return false;
            payload = new byte[len]; if (len > 0 && !ReadFull(s, payload, len)) return false;
            return true;
        }
        static bool ReadFull(Stream s, byte[] buf, int len)
        {
            int got = 0; while (got < len) { int n; try { n = s.Read(buf, got, len - got); } catch { return false; } if (n <= 0) return false; got += n; }
            return true;
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Pseudoconsole + child process
    // ------------------------------------------------------------------------------------------------
    class Pty : IDisposable
    {
        public IntPtr HPC = IntPtr.Zero;
        public FileStream Output;   // we read the child's output here
        public FileStream Input;    // we write keystrokes here
        public Native.PROCESS_INFORMATION Pi;
        public IntPtr Job = IntPtr.Zero;
        IntPtr attrList = IntPtr.Zero;
        public int Cols, Rows;

        public void Start(string commandLine, string cwd, int cols, int rows)
        {
            Cols = cols; Rows = rows;
            var sa = new Native.SECURITY_ATTRIBUTES(); sa.nLength = Marshal.SizeOf(sa); sa.bInheritHandle = 0;
            SafeFileHandle inRead, inWrite, outRead, outWrite;
            if (!Native.CreatePipe(out inRead, out inWrite, ref sa, 0)) throw new Win32Exception("CreatePipe(in)");
            if (!Native.CreatePipe(out outRead, out outWrite, ref sa, 0)) throw new Win32Exception("CreatePipe(out)");
            int hr = Native.CreatePseudoConsole(new Native.COORD((short)cols, (short)rows), inRead, outWrite, 0, out HPC);
            if (hr != 0) throw new Win32Exception("CreatePseudoConsole hr=0x" + hr.ToString("x"));
            // conhost now holds its own copies of the child ends
            inRead.Dispose(); outWrite.Dispose();
            Output = new FileStream(outRead, FileAccess.Read, 65536, false);
            Input = new FileStream(inWrite, FileAccess.Write, 4096, false);

            IntPtr size = IntPtr.Zero;
            Native.InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            attrList = Marshal.AllocHGlobal(size);
            if (!Native.InitializeProcThreadAttributeList(attrList, 1, 0, ref size)) throw new Win32Exception("InitializeProcThreadAttributeList");
            if (!Native.UpdateProcThreadAttribute(attrList, 0, (IntPtr)Native.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, HPC, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception("UpdateProcThreadAttribute");

            var six = new Native.STARTUPINFOEX();
            six.StartupInfo.cb = Marshal.SizeOf(six);
            six.lpAttributeList = attrList;

            // Job object: kill the whole tree on host death or on `hard` kill.
            Job = Native.CreateJobObjectW(IntPtr.Zero, null);
            var jeli = new Native.JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            jeli.BasicLimitInformation.LimitFlags = Native.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            Native.SetInformationJobObject(Job, Native.JobObjectExtendedLimitInformation, ref jeli, Marshal.SizeOf(jeli));

            // Windows hands a child the parent's standard handles whenever they are not console handles, even with
            // bInheritHandles = FALSE. A host started under a redirected pipe would therefore leak that pipe into the
            // lane as its stdout, and the lane's bytes would never reach the pseudoconsole. Detach our own std handles
            // first; the child is then given fresh handles on its own (pseudo)console.
            Native.SetStdHandle(Native.STD_INPUT_HANDLE, IntPtr.Zero);
            Native.SetStdHandle(Native.STD_OUTPUT_HANDLE, IntPtr.Zero);
            Native.SetStdHandle(Native.STD_ERROR_HANDLE, IntPtr.Zero);
            var cl = new StringBuilder(commandLine);
            if (!Native.CreateProcessW(null, cl, IntPtr.Zero, IntPtr.Zero, false,
                Native.EXTENDED_STARTUPINFO_PRESENT | Native.CREATE_UNICODE_ENVIRONMENT, IntPtr.Zero, cwd, ref six, out Pi))
                throw new Win32Exception("CreateProcessW: " + commandLine);
            Native.AssignProcessToJobObject(Job, Pi.hProcess);
        }

        public void Resize(int cols, int rows)
        {
            if (cols < 10 || rows < 3 || cols > 1000 || rows > 500) return;
            if (cols == Cols && rows == Rows) return;
            Cols = cols; Rows = rows;
            Native.ResizePseudoConsole(HPC, new Native.COORD((short)cols, (short)rows));
        }

        public bool WaitExit(int ms) { return Native.WaitForSingleObject(Pi.hProcess, (uint)ms) == 0; }
        public int ExitCode() { int c; Native.GetExitCodeProcess(Pi.hProcess, out c); return c; }
        public void KillTree() { if (Job != IntPtr.Zero) Native.TerminateJobObject(Job, 137); }

        public void CloseConsole()
        {
            // Tell conhost the terminal is gone: it flushes pending output to the pipe and closes it (EOF for the reader).
            try { if (Input != null) Input.Dispose(); } catch { }
            if (HPC != IntPtr.Zero) { Native.ClosePseudoConsole(HPC); HPC = IntPtr.Zero; }
        }

        public void Dispose()
        {
            CloseConsole();
            try { if (Output != null) Output.Dispose(); } catch { }
            if (attrList != IntPtr.Zero) { Native.DeleteProcThreadAttributeList(attrList); Marshal.FreeHGlobal(attrList); attrList = IntPtr.Zero; }
            if (Pi.hProcess != IntPtr.Zero) { Native.CloseHandle(Pi.hProcess); Native.CloseHandle(Pi.hThread); }
            if (Job != IntPtr.Zero) { Native.CloseHandle(Job); Job = IntPtr.Zero; }
        }
    }

    class Win32Exception : Exception { public Win32Exception(string what) : base(what + " (win32 " + Marshal.GetLastWin32Error() + ")") { } }

    // ------------------------------------------------------------------------------------------------
    // VT stripping for labels and the screen tail
    // ------------------------------------------------------------------------------------------------
    static class Vt
    {
        // Strip escape sequences and return visible text with line structure kept.
        public static string Strip(string s)
        {
            var sb = new StringBuilder(s.Length);
            int i = 0;
            while (i < s.Length)
            {
                char c = s[i];
                if (c == '\x1b')
                {
                    i++; if (i >= s.Length) break;
                    char n = s[i];
                    if (n == '[')
                    {   // CSI: params then final byte 0x40..0x7E. Cursor-forward (CUF) is how ink draws spaces: keep them.
                        i++; int ps = i; while (i < s.Length && !(s[i] >= '@' && s[i] <= '~')) i++;
                        if (i < s.Length && s[i] == 'C')
                        {
                            int cnt = 1; string num = s.Substring(ps, i - ps); int tmp; if (num.Length > 0 && int.TryParse(num, out tmp) && tmp > 0 && tmp < 1000) cnt = tmp;
                            sb.Append(' ', cnt);
                        }
                        i++;
                    }
                    else if (n == ']')
                    {   // OSC: until BEL or ESC \
                        i++; while (i < s.Length && s[i] != '\x07' && !(s[i] == '\x1b' && i + 1 < s.Length && s[i + 1] == '\\')) i++;
                        if (i < s.Length && s[i] == '\x1b') i += 2; else i++;
                    }
                    else if (n == 'P' || n == '^' || n == '_')
                    {   // DCS/PM/APC: until ST
                        i++; while (i < s.Length && !(s[i] == '\x1b' && i + 1 < s.Length && s[i + 1] == '\\')) i++; i += 2;
                    }
                    else if (n == '(' || n == ')' || n == '*' || n == '+' || n == '#') { i += 2; }
                    else { i++; }
                    continue;
                }
                if (c == '\r' || c == '\n' || c == '\t' || c >= ' ') sb.Append(c);
                i++;
            }
            // resolve \r overwrites: keep text after the last \r in each line (approximation of a redraw)
            var lines = sb.ToString().Replace("\r\n", "\n").Split('\n');
            var outp = new StringBuilder();
            foreach (var ln in lines)
            {
                string l = ln; int r = l.LastIndexOf('\r'); if (r >= 0) l = l.Substring(r + 1);
                outp.Append(l.TrimEnd()).Append('\n');
            }
            return outp.ToString();
        }

        // Last `n` non-empty lines of stripped text, deduplicating immediate repeats.
        public static List<string> TailLines(string stripped, int n)
        {
            var all = stripped.Split('\n'); var res = new List<string>();
            string prev = null;
            for (int i = all.Length - 1; i >= 0 && res.Count < n; i--)
            {
                string l = all[i].Trim(); if (l.Length == 0) continue;
                if (l == prev) continue; prev = l;
                res.Insert(0, l);
            }
            return res;
        }

        public static string Truncate(string s, int max)
        {
            if (s == null) return "";
            s = s.Replace("\r", " ").Replace("\n", " ⏎ ");
            while (s.Contains("  ")) s = s.Replace("  ", " ");
            s = s.Trim();
            if (s.Length <= max) return s;
            return s.Substring(0, max - 1) + "…";
        }
    }

    // ------------------------------------------------------------------------------------------------
    // A subscriber of the output stream (attach client, web viewer). Bounded queue; slow readers are
    // told about the gap and keep going from the live edge; the log stays the truth.
    // ------------------------------------------------------------------------------------------------
    class Subscriber
    {
        public Stream Pipe; public Queue<byte[]> Q = new Queue<byte[]>(); public long Queued = 0; public long Dropped = 0;
        public const long MaxQueued = 8 * 1024 * 1024;
        public readonly object Lock = new object();
        public bool Dead = false;
        public AutoResetEvent Signal = new AutoResetEvent(false);
        public void Enqueue(byte type, byte[] data, int off, int len)
        {
            lock (Lock)
            {
                if (Dead) return;
                if (Queued + len > MaxQueued)
                {   // drop everything queued, note the gap
                    Dropped += Queued; Q.Clear(); Queued = 0;
                    Q.Enqueue(Tag(Frame.Gap, Encoding.UTF8.GetBytes(Dropped.ToString())));
                }
                Q.Enqueue(Tag(type, data, off, len)); Queued += len;
            }
            Signal.Set();
        }
        static byte[] Tag(byte type, byte[] d) { return Tag(type, d, 0, d.Length); }
        static byte[] Tag(byte type, byte[] d, int off, int len) { var b = new byte[len + 1]; b[0] = type; Buffer.BlockCopy(d, off, b, 1, len); return b; }
        public void Pump()
        {
            while (!Dead)
            {
                byte[] item = null;
                lock (Lock) { if (Q.Count > 0) { item = Q.Dequeue(); Queued -= item.Length - 1; } }
                if (item == null) { Signal.WaitOne(500); continue; }
                try { Frame.Write(Pipe, item[0], item, 1, item.Length - 1); }
                catch { lock (Lock) { Dead = true; } }
            }
        }
    }

    // ------------------------------------------------------------------------------------------------
    // The lane host
    // ------------------------------------------------------------------------------------------------
    class Host
    {
        // config
        string name, laneDir, cwd, head = "user", kind = "other", model = "", brief = "", sessionId = "", metaJson = null, cmdline;
        int cols = 160, rows = 45, stallMin = 10, stallSec = 600, quietSec = 4;
        // runtime
        Pty pty; FileStream log; long bytes = 0; readonly object logLock = new object(); Thread outThread;
        readonly object inputLock = new object();
        DateTime started, lastOutput; long lastOutputTicks;
        volatile string state = "starting"; string why = ""; string label = ""; int exitCode = 0; long episodeStart = 0;
        long lastInputAt = 0;
        bool stalledReported = false; bool exited = false;
        string pipeName; string eventsPath, hooksPath;
        readonly List<Subscriber> subs = new List<Subscriber>();
        // rolling tail of raw output for pattern detection (last 32 KB)
        readonly byte[] tail = new byte[32768]; int tailLen = 0; readonly object tailLock = new object();
        long hooksRead = 0; string lastAssistant = ""; string transcriptPath = ""; string sessionIdSeen = "";
        Regex promptRx, runningRx, errorRx;
        int restartCount = 0; string restartOf = "";
        bool pendingInput = false;  // input written while waiting: the next output proves the turn restarted
        long lastStateChange = 0;
        volatile bool hookTurnDone = false;  // claude/grok Stop or codex turn-ended seen since the last input
        volatile bool hookSeen = false;      // whether this lane speaks hooks at all (then patterns take a back seat)
        volatile bool idleAtPrompt = false;  // a hook said the turn ended and nothing has been submitted since
        readonly AutoResetEvent wake = new AutoResetEvent(false);   // hooks and exits wake the watcher early

        public static int Run(string[] a)
        {
            var h = new Host();
            int i = 0; var cmdParts = new List<string>();
            for (; i < a.Length; i++)
            {
                string k = a[i];
                if (k == "--") { i++; break; }
                string v = (i + 1 < a.Length) ? a[i + 1] : null;
                switch (k)
                {
                    case "--name": h.name = v; i++; break;
                    case "--dir": h.laneDir = v; i++; break;
                    case "--cwd": h.cwd = v; i++; break;
                    case "--cols": h.cols = int.Parse(v); i++; break;
                    case "--rows": h.rows = int.Parse(v); i++; break;
                    case "--head": h.head = v; i++; break;
                    case "--kind": h.kind = v; i++; break;
                    case "--model": h.model = v; i++; break;
                    case "--brief": h.brief = v; i++; break;
                    case "--session": h.sessionId = v; i++; break;
                    case "--stall-min": h.stallMin = int.Parse(v); h.stallSec = h.stallMin * 60; i++; break;
                    case "--stall-sec": h.stallSec = int.Parse(v); i++; break;
                    case "--quiet-sec": h.quietSec = int.Parse(v); i++; break;
                    case "--meta-json": h.metaJson = v; i++; break;
                    case "--restart-of": h.restartOf = v; i++; break;
                    case "--restart-count": h.restartCount = int.Parse(v); i++; break;
                    case "--events": h.eventsPath = v; i++; break;
                    case "--cmdline": h.cmdline = v; i++; break;
                    default: Console.Error.WriteLine("unknown option " + k); return 2;
                }
            }
            for (; i < a.Length; i++) cmdParts.Add(a[i]);
            if (h.name == null || h.laneDir == null || (cmdParts.Count == 0 && h.cmdline == null)) { Console.Error.WriteLine("usage: LaneHost run --name N --dir D --cwd C [...] (--cmdline \"...\" | -- <command line>)"); return 2; }
            if (h.cmdline == null) h.cmdline = Quote(cmdParts);
            if (h.cwd == null) h.cwd = Directory.GetCurrentDirectory();
            return h.Main();
        }

        public static string Quote(List<string> parts)
        {
            var sb = new StringBuilder();
            foreach (var p in parts)
            {
                if (sb.Length > 0) sb.Append(' ');
                if (p.Length > 0 && p.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) { sb.Append(p); continue; }
                sb.Append('"');
                int bs = 0;
                foreach (char c in p)
                {
                    if (c == '\\') { bs++; continue; }
                    if (c == '"') { sb.Append('\\', bs * 2 + 1).Append('"'); bs = 0; continue; }
                    if (bs > 0) { sb.Append('\\', bs); bs = 0; }
                    sb.Append(c);
                }
                if (bs > 0) sb.Append('\\', bs * 2);
                sb.Append('"');
            }
            return sb.ToString();
        }

        int Main()
        {
            // Drop whatever stdio we inherited. A head agent launches lanes from a tool whose stdout is a pipe;
            // an inherited write end held here would keep that tool call open until the lane dies.
            Program.DetachStdio();
            // The host needs no console of its own: one conhost per lane (the pseudoconsole's), not two.
            Native.FreeConsole();
            Directory.CreateDirectory(laneDir);
            pipeName = "lanes-" + name;
            hooksPath = Path.Combine(laneDir, "hooks.jsonl");
            if (eventsPath == null) eventsPath = Path.Combine(HeadsRoot(), head, "events.jsonl");
            Directory.CreateDirectory(Path.GetDirectoryName(eventsPath));
            LoadPatterns();

            // A pre-existing hooks file would replay an older generation's events; start fresh.
            try { if (File.Exists(hooksPath)) File.Delete(hooksPath); } catch { }
            // bufferSize 1 = write-through: every chunk is visible to `lane read` and the viewer the moment it arrives.
            log = new FileStream(Path.Combine(laneDir, "console.log"), FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete, 1);
            bytes = log.Length;  // append to a preserved log after restart
            episodeStart = bytes;

            // Environment for the child: it (and its hooks) can find its lane.
            Environment.SetEnvironmentVariable("LANES_LANE", name);
            Environment.SetEnvironmentVariable("LANES_LANE_DIR", laneDir);
            Environment.SetEnvironmentVariable("LANES_LANE_HEAD", head);
            if (Environment.GetEnvironmentVariable("LANES_HEAD") == null) Environment.SetEnvironmentVariable("LANES_HEAD", head);
            Environment.SetEnvironmentVariable("TERM", "xterm-256color");
            Environment.SetEnvironmentVariable("COLORTERM", "truecolor");

            started = DateTime.UtcNow; lastOutput = started; lastOutputTicks = Stopwatch.GetTimestamp();
            pty = new Pty();
            try { pty.Start(cmdline, cwd, cols, rows); }
            catch (Exception ex)
            {
                state = "died"; why = "spawn-failed"; label = ex.Message; WriteState(); Emit("died");
                Console.Error.WriteLine(ex.Message); return 3;
            }
            // Header line in the log so generations are visible in the transcript itself.
            LogMarker("LANE " + name + " START pid=" + pty.Pi.dwProcessId + " model=" + model + " cwd=" + cwd + " cmd=" + cmdline);
            state = "running"; why = "launched"; lastStateChange = Stopwatch.GetTimestamp();
            WriteState();

            outThread = new Thread(OutputLoop) { IsBackground = true, Name = "out" }; outThread.Start();
            new Thread(PipeAcceptLoop) { IsBackground = true, Name = "pipe" }.Start();
            new Thread(Watch) { IsBackground = true, Name = "watch" }.Start();

            // Wait for the child to exit.
            while (!pty.WaitExit(1000)) { }
            exited = true;
            exitCode = pty.ExitCode();
            // The child can finish writing into conhost's buffer long before conhost has rendered it all to the VT
            // pipe. Closing the pseudoconsole makes conhost flush the rest and close the pipe; the output thread
            // reads to EOF. Only then is the transcript complete. (A flood of 100 MB still had 115 lines in flight
            // at exit before this was done this way.)
            pty.CloseConsole();
            if (!outThread.Join(120000)) { /* conhost would not flush in two minutes; proceed with what we have */ }
            lock (logLock) { try { log.Flush(); } catch { } }
            string tailText = TailText();
            bool errorish = errorRx != null && errorRx.IsMatch(tailText);
            string fin = (exitCode == 0 && !errorish) ? "finished" : "died";
            // finished: the lane's own last message. died: what was on the screen when it went (the error is there).
            string screen = string.Join(" | ", Vt.TailLines(tailText, 4).ToArray());
            string lbl = (fin == "finished" && lastAssistant.Length > 0) ? lastAssistant : screen;
            SetState(fin, exitCode == 0 ? (errorish ? "exit-0-with-error" : "exit-0") : "exit-" + exitCode, Vt.Truncate(lbl, 400), true);
            LogMarker("LANE " + name + " EXIT code=" + exitCode + " state=" + fin);
            // tell subscribers
            var ex2 = Encoding.UTF8.GetBytes(exitCode.ToString());
            lock (subs) foreach (var s in subs) s.Enqueue(Frame.Exit, ex2, 0, ex2.Length);
            Thread.Sleep(300);
            pty.Dispose();
            lock (logLock) { log.Dispose(); }
            return 0;
        }

        static string HeadsRoot()
        {
            return Paths.HeadsRoot();
        }

        void LoadPatterns()
        {
            // Defaults are generic; kind-specific detection comes from hooks. Override with <exeDir>\patterns.json.
            string prompt = @"(\?\s*$)|(\(y/n\)|\[y/n\]|\[Y/n\]|\(y/N\)|yes/no)|(Do you want to|Would you like to|Press Enter|press enter|to continue)|(❯\s*\d\.)|(^\s*>\s*$)|(^PS [^>]*>\s*$)|(^\s*[›>$#%]\s*$)|(\? for shortcuts)|(⏎ send)|(Esc to cancel)|(esc to cancel)|(Enter to select)|(Enter to confirm)|(enter to confirm)|(\(Y\)es|\(N\)o)|(→ Add a follow-up)";
            string running = @"(esc to interrupt)|(Esc to interrupt)|(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏)|(✻|✽|✶|✳|✢|·) (Thinking|Working|Running|Baking|Brewing|Cooking|Computing|Crunching|Deliberating|Pondering|Processing|Reasoning|Musing|Cogitating|Noodling|Simmering|Percolating|Mulling|Churning|Finagling|Hatching|Forging|Schlepping|Wibbling|Wrangling|Frolicking|Smooshing|Herding|Synthesizing|Vibing|Sparkling|Moseying|Puttering|Shimmying|Honking|Jiving|Sprouting|Stewing|Ruminating|Contemplating)";
            string error = @"(API Error: 5\d\d)|(overloaded_error)|(Overloaded)|(rate_limit)|(ECONNRESET)|(fatal error)|(Unhandled exception)|(panicked at)|(out of memory)|(Segmentation fault)|(\berror\b.*\b(529|503|500)\b)";
            try
            {
                string pf = Path.Combine(Path.GetDirectoryName(typeof(Host).Assembly.Location), "patterns.json");
                if (File.Exists(pf))
                {
                    var d = Json.Parse(File.ReadAllText(pf)) as Dictionary<string, object>;
                    if (d != null)
                    {
                        if (d.ContainsKey("prompt")) prompt = (string)d["prompt"];
                        if (d.ContainsKey("running")) running = (string)d["running"];
                        if (d.ContainsKey("error")) error = (string)d["error"];
                    }
                }
            }
            catch { }
            promptRx = new Regex(prompt, RegexOptions.Multiline);
            runningRx = new Regex(running, RegexOptions.Multiline);
            errorRx = new Regex(error, RegexOptions.Multiline);
        }

        void LogMarker(string text)
        {
            var b = Encoding.UTF8.GetBytes("\r\n\x1b[2m[" + DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ") + " " + text + "]\x1b[0m\r\n");
            lock (logLock) { try { log.Write(b, 0, b.Length); log.Flush(); bytes += b.Length; } catch { } }
        }

        // ---- output ------------------------------------------------------------------------------
        void OutputLoop()
        {
            var buf = new byte[65536];
            while (true)
            {
                int n;
                try { n = pty.Output.Read(buf, 0, buf.Length); } catch { break; }
                if (n <= 0) break;
                lock (logLock) { try { log.Write(buf, 0, n); bytes += n; } catch { } }
                lock (tailLock)
                {
                    if (n >= tail.Length) { Buffer.BlockCopy(buf, n - tail.Length, tail, 0, tail.Length); tailLen = tail.Length; }
                    else
                    {
                        int keep = Math.Min(tailLen, tail.Length - n);
                        if (keep > 0) Buffer.BlockCopy(tail, tailLen - keep, tail, 0, keep);
                        Buffer.BlockCopy(buf, 0, tail, keep, n); tailLen = keep + n;
                    }
                }
                lastOutput = DateTime.UtcNow; lastOutputTicks = Stopwatch.GetTimestamp();
                ScanModes(buf, n);
                if (pendingInput) { pendingInput = false; hookTurnDone = false; if (state == "needs-input" || state == "stalled") SetState("running", "input", "", false); }
                else if (state == "stalled") { SetState("running", "output-resumed", "", false); }
                Subscriber[] arr; lock (subs) arr = subs.ToArray();
                foreach (var s in arr) s.Enqueue(Frame.Output, buf, 0, n);
            }
            lock (logLock) { try { log.Flush(); } catch { } }
        }

        volatile bool bracketedPaste = false;
        static readonly byte[] BpOn = Encoding.ASCII.GetBytes("\x1b[?2004h"), BpOff = Encoding.ASCII.GetBytes("\x1b[?2004l");
        void ScanModes(byte[] buf, int n)
        {
            // cheap scan for DECSET/DECRST 2004 (bracketed paste); the last one in the chunk wins
            int lastOn = LastIndexOf(buf, n, BpOn), lastOff = LastIndexOf(buf, n, BpOff);
            if (lastOn >= 0 || lastOff >= 0) bracketedPaste = lastOn > lastOff;
        }
        static int LastIndexOf(byte[] buf, int n, byte[] pat)
        {
            for (int i = n - pat.Length; i >= 0; i--)
            {
                if (buf[i] != pat[0]) continue;
                int j = 1; while (j < pat.Length && buf[i + j] == pat[j]) j++;
                if (j == pat.Length) return i;
            }
            return -1;
        }

        void WritePaste(byte[] text)
        {
            // One message, one lock: the text (bracketed if the CLI wants pastes bracketed), a short settle so the
            // CLI's input parser has consumed the paste, then the Enter, all before anyone else may type.
            bool submit = text.Length > 0 && text[text.Length - 1] == (byte)'\r';
            int bodyLen = submit ? text.Length - 1 : text.Length;
            lock (inputLock)
            {
                try
                {
                    if (bodyLen > 0)
                    {
                        if (bracketedPaste)
                        {
                            var open = Encoding.ASCII.GetBytes("\x1b[200~"); var close = Encoding.ASCII.GetBytes("\x1b[201~");
                            var all = new byte[open.Length + bodyLen + close.Length];
                            Buffer.BlockCopy(open, 0, all, 0, open.Length); Buffer.BlockCopy(text, 0, all, open.Length, bodyLen); Buffer.BlockCopy(close, 0, all, open.Length + bodyLen, close.Length);
                            pty.Input.Write(all, 0, all.Length);
                        }
                        else pty.Input.Write(text, 0, bodyLen);
                        pty.Input.Flush();
                    }
                    if (submit)
                    {
                        if (bodyLen > 0) Thread.Sleep(bracketedPaste ? 120 : 40);
                        pty.Input.Write(new byte[] { (byte)'\r' }, 0, 1); pty.Input.Flush();
                    }
                }
                catch { }
                lastInputAt = Stopwatch.GetTimestamp();
                pendingInput = true;
            }
        }

        string TailText()
        {
            byte[] copy; lock (tailLock) { copy = new byte[tailLen]; Buffer.BlockCopy(tail, 0, copy, 0, tailLen); }
            return Vt.Strip(Encoding.UTF8.GetString(copy));
        }

        // ---- input -------------------------------------------------------------------------------
        void WriteInput(byte[] data, int off, int len)
        {
            if (len <= 0) return;
            lock (inputLock)
            {
                try { pty.Input.Write(data, off, len); pty.Input.Flush(); } catch { }
                lastInputAt = Stopwatch.GetTimestamp();
                pendingInput = true;
            }
        }

        // ---- state -------------------------------------------------------------------------------
        double SecondsSince(long ticks) { return (Stopwatch.GetTimestamp() - ticks) / (double)Stopwatch.Frequency; }

        void SetState(string st, string w, string lbl, bool emit)
        {
            bool changed = st != state || w != why;
            state = st; why = w; label = lbl ?? "";
            lastStateChange = Stopwatch.GetTimestamp();
            WriteState();
            if (emit && changed) Emit(st);
            if (st == "running") { episodeStart = bytes; }
        }

        void WriteState()
        {
            try
            {
                var d = new Dictionary<string, object>();
                d["name"] = name; d["head"] = head; d["kind"] = kind; d["model"] = model; d["cwd"] = cwd; d["cmd"] = cmdline;
                d["brief"] = brief; d["pid"] = pty != null ? pty.Pi.dwProcessId : 0; d["hostPid"] = Process.GetCurrentProcess().Id;
                d["hostStart"] = Process.GetCurrentProcess().StartTime.ToUniversalTime().ToString("o");
                d["started"] = started.ToString("o"); d["lastOutputAt"] = lastOutput.ToString("o"); d["bytes"] = bytes;
                d["state"] = state; d["why"] = why; d["label"] = label; d["exitCode"] = exited ? (object)exitCode : null;
                d["sessionId"] = sessionIdSeen.Length > 0 ? sessionIdSeen : sessionId; d["transcript"] = transcriptPath;
                d["pipe"] = @"\\.\pipe\" + pipeName; d["cols"] = pty != null ? pty.Cols : cols; d["rows"] = pty != null ? pty.Rows : rows;
                d["restartOf"] = restartOf; d["restartCount"] = restartCount; d["episodeStart"] = episodeStart;
                lock (subs) d["viewers"] = subs.Count;
                d["updated"] = DateTime.UtcNow.ToString("o");
                if (metaJson != null) d["meta"] = new Json.RawJson(metaJson);
                string tmp = Path.Combine(laneDir, "state.json.tmp"); string fin = Path.Combine(laneDir, "state.json");
                File.WriteAllText(tmp, Json.Val(d), new UTF8Encoding(false));
                if (File.Exists(fin)) File.Replace(tmp, fin, null); else File.Move(tmp, fin);
            }
            catch { }
        }

        static int eventSeqCache = 0;
        void Emit(string st)
        {
            var row = Json.Obj("ts", DateTime.UtcNow.ToString("o"), "head", head, "lane", name, "state", st, "why", why, "label", label,
                "from", episodeStart, "to", bytes, "pid", pty != null ? pty.Pi.dwProcessId : 0, "exit", exited ? (object)exitCode : null,
                "kind", kind, "model", model, "cwd", cwd, "hostPid", Process.GetCurrentProcess().Id, "n", ++eventSeqCache);
            AppendEvent(eventsPath, row);
        }

        public static void AppendEvent(string path, string row)
        {
            bool created; string mname = "lanes-events-" + path.ToLowerInvariant().Replace('\\', '_').Replace(':', '_').Replace('/', '_');
            using (var m = new Mutex(false, mname, out created))
            {
                bool got = false;
                try { got = m.WaitOne(10000); } catch (AbandonedMutexException) { got = true; }
                try
                {
                    using (var fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
                    { var b = Encoding.UTF8.GetBytes(row + "\n"); fs.Write(b, 0, b.Length); fs.Flush(true); }
                }
                finally { if (got) m.ReleaseMutex(); }
            }
        }

        // ---- watcher: hooks file, quiescence, stall ------------------------------------------------
        void Watch()
        {
            int tick = 0;
            while (!exited)
            {
                // One-second tick (the brief: no polling tighter than a second); a hook or an exit wakes it early.
                bool woken = wake.WaitOne(1000);
                tick++;
                try { PollHooks(); } catch { }
                if (woken && hookTurnDone) { Thread.Sleep(1000); }   // let the CLI finish painting after its Stop hook
                if (exited) break;
                double quiet = SecondsSince(lastOutputTicks);
                if (state == "running")
                {
                    if (hookTurnDone && quiet >= 1.0)
                    {   // hook said the turn is over and the screen has settled: needs-input, label is the last message
                        hookTurnDone = false;
                        SetState("needs-input", "turn-complete", Vt.Truncate(lastAssistant.Length > 0 ? lastAssistant : QuestionFromTail(), 400), true);
                    }
                    else if (idleAtPrompt && !hookTurnDone && quiet >= quietSec && SecondsSince(lastStateChange) > quietSec)
                    {   // typed at the prompt but never submitted: still waiting, already reported
                        SetState("needs-input", "turn-complete", Vt.Truncate(lastAssistant.Length > 0 ? lastAssistant : QuestionFromTail(), 400), false);
                    }
                    else if (quiet >= quietSec && !hookSeen)
                    {   // generic CLI: quiet and the tail looks like a prompt
                        string t = TailText(); var lines = Vt.TailLines(t, 6); string last = lines.Count > 0 ? lines[lines.Count - 1] : "";
                        string joined = string.Join("\n", lines.ToArray());
                        // Cursor has no hooks and keeps "→ Add a follow-up" on screen while it works; while busy that
                        // same line also says "ctrl+c to stop". The tail is a stream of frames, so judge the newest one.
                        bool cursorBusy = false;
                        if (kind == "cursor")
                        {
                            for (int li = lines.Count - 1; li >= 0; li--)
                                if (lines[li].IndexOf("Add a follow-up", StringComparison.Ordinal) >= 0)
                                { cursorBusy = lines[li].IndexOf("ctrl+c to stop", StringComparison.OrdinalIgnoreCase) >= 0; break; }
                        }
                        if (promptRx.IsMatch(joined) && !runningRx.IsMatch(last) && !cursorBusy)
                            SetState("needs-input", "prompt", Vt.Truncate(kind == "cursor" ? CursorReplyFromTail(t) : joined, 400), true);
                    }
                    else if (quiet >= quietSec && hookSeen && SecondsSince(lastStateChange) > quietSec)
                    {   // hook-speaking CLI but the hook did not fire (permission dialog, trust prompt, AskUserQuestion
                        // rendered without its hook): fall back to the prompt pattern, but demand a question-looking tail
                        string t = TailText(); var lines = Vt.TailLines(t, 8); string joined = string.Join("\n", lines.ToArray());
                        if (QuestionRx.IsMatch(joined) && !runningRx.IsMatch(lines.Count > 0 ? lines[lines.Count - 1] : ""))
                            SetState("needs-input", "question", Vt.Truncate(QuestionFromTail(), 400), true);
                    }
                    if (state == "running" && quiet >= stallSec && !stalledReported)
                    {
                        stalledReported = true;
                        SetState("stalled", "no-output-" + (stallSec % 60 == 0 ? (stallSec / 60) + "m" : stallSec + "s"), Vt.Truncate(string.Join(" | ", Vt.TailLines(TailText(), 2).ToArray()), 200), true);
                    }
                }
                if (state != "stalled") stalledReported = false;
                if (tick % 3 == 0) WriteState();    // every ~3 s: lastOutputAt and bytes stay fresh for `lane list`
            }
        }

        // Cursor's idle screen ends in its own chrome (follow-up box, model line, cwd). The label should be
        // what the agent said, so skip the chrome and keep the last few lines above it.
        static readonly Regex CursorChromeRx = new Regex(@"Add a follow-up|Run Everything|ctrl\+c to stop|^\s*Tip:|^[\u2800-\u28FF\s]*Working\b|Working\s+\d+ tokens|^\s*~[\\/]|^\s*[A-Za-z]:\\", RegexOptions.IgnoreCase);
        static string CursorReplyFromTail(string tail)
        {
            var lines = Vt.TailLines(tail, 20); var keep = new List<string>();
            foreach (var l in lines) { string s = l.Trim(); if (s.Length > 0 && !CursorChromeRx.IsMatch(s)) keep.Add(s); }
            if (keep.Count == 0) return string.Join(" | ", Vt.TailLines(tail, 4).ToArray());
            return string.Join(" | ", keep.GetRange(Math.Max(0, keep.Count - 3), Math.Min(3, keep.Count)).ToArray());
        }

        static readonly Regex QuestionRx =new Regex(@"(\?\s*$)|(Do you want|Would you like|Yes, |No, |\(y/n\)|\[Y/n\]|\(Y\)es|❯ \d\.|Enter to (select|confirm|continue)|Press Enter|Esc to cancel|esc to cancel|Tab to|to proceed)", RegexOptions.Multiline);

        string QuestionFromTail()
        {
            var lines = Vt.TailLines(TailText(), 10);
            // prefer the lines around a question mark
            int qi = -1; for (int i = lines.Count - 1; i >= 0; i--) if (lines[i].Contains("?")) { qi = i; break; }
            if (qi >= 0) { int from = Math.Max(0, qi - 2); return string.Join(" | ", lines.GetRange(from, lines.Count - from).ToArray()); }
            return string.Join(" | ", lines.ToArray());
        }

        void PollHooks()
        {
            if (!File.Exists(hooksPath)) return;
            long len = new FileInfo(hooksPath).Length; if (len <= hooksRead) return;
            string chunk;
            using (var fs = new FileStream(hooksPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                fs.Seek(hooksRead, SeekOrigin.Begin); var b = new byte[len - hooksRead]; int got = 0;
                while (got < b.Length) { int n = fs.Read(b, got, b.Length - got); if (n <= 0) break; got += n; }
                chunk = Encoding.UTF8.GetString(b, 0, got);
            }
            int lastNl = chunk.LastIndexOf('\n'); if (lastNl < 0) return;  // wait for a complete line
            hooksRead += Encoding.UTF8.GetByteCount(chunk.Substring(0, lastNl + 1));
            foreach (var line in chunk.Substring(0, lastNl + 1).Split('\n'))
            {
                string l = line.Trim(); if (l.Length == 0) continue;
                object o; try { o = Json.Parse(l); } catch { continue; }
                OnHook(o, l);
            }
        }

        void OnHook(object o, string raw)
        {
            hookSeen = true;
            string ev = Json.GetStr(o, "hook_event_name");
            if (string.IsNullOrEmpty(ev)) ev = Json.GetStr(o, "hookEventName"); // Grok Build
            string evKey = string.IsNullOrEmpty(ev) ? "" : ev.Replace("_", "").Replace("-", "").ToLowerInvariant();
            string ty = Json.GetStr(o, "type");            // codex notify
            string sid = Json.GetStr(o, "session_id"); if (string.IsNullOrEmpty(sid)) sid = Json.GetStr(o, "sessionId"); if (!string.IsNullOrEmpty(sid)) sessionIdSeen = sid;
            string tp = Json.GetStr(o, "transcript_path"); if (string.IsNullOrEmpty(tp)) tp = Json.GetStr(o, "transcriptPath"); if (!string.IsNullOrEmpty(tp)) transcriptPath = tp;
            string tid = Json.GetStr(o, "thread-id"); if (string.IsNullOrEmpty(tid)) tid = Json.GetStr(o, "thread_id"); if (!string.IsNullOrEmpty(tid)) sessionIdSeen = tid;
            if (evKey == "stop")
            {
                string m = Json.GetStr(o, "last_assistant_message");
                if (string.IsNullOrEmpty(m)) m = Json.GetStr(o, "lastAssistantMessage");
                if (string.IsNullOrEmpty(m)) m = LastAssistantFromTranscript();
                lastAssistant = m ?? "";
                hookTurnDone = true; idleAtPrompt = true;
            }
            else if (ty == "agent-turn-complete")
            {
                string m = Json.GetStr(o, "last-assistant-message"); if (m == null) m = Json.GetStr(o, "last_assistant_message");
                lastAssistant = m ?? "";
                hookTurnDone = true; idleAtPrompt = true;
            }
            else if (evKey == "notification")
            {
                string nt = Json.GetStr(o, "notification_type"); if (string.IsNullOrEmpty(nt)) nt = Json.GetStr(o, "notificationType"); string msg = Json.GetStr(o, "message") ?? "";
                if (nt == "permission_prompt" || nt == "elicitation_dialog" || nt == "idle_prompt")
                {
                    if (state == "running" || (state == "needs-input" && why == "turn-complete"))
                        SetState("needs-input", nt == "idle_prompt" ? "idle" : "permission", Vt.Truncate(msg.Length > 0 ? msg : QuestionFromTail(), 400), true);
                }
            }
            else if (evKey == "permissionrequest")
            {
                string tool = Json.GetStr(o, "tool_name"); if (string.IsNullOrEmpty(tool)) tool = Json.GetStr(o, "toolName") ?? "";
                string ti = Json.GetStr(o, "tool_input"); if (string.IsNullOrEmpty(ti)) ti = Json.GetStr(o, "toolInput") ?? "";
                if (state == "running") SetState("needs-input", "permission", Vt.Truncate("Permission: " + tool + " " + ti, 400), true);
            }
            else if (evKey == "pretooluse" && (Json.GetStr(o, "tool_name") == "AskUserQuestion" || Json.GetStr(o, "toolName") == "AskUserQuestion"))
            {
                idleAtPrompt = false;
                var qs = Json.Get(o, "tool_input", "questions") as List<object>; var sb = new StringBuilder();
                if (qs == null) qs = Json.Get(o, "toolInput", "questions") as List<object>;
                if (qs != null) foreach (var q in qs)
                    {
                        sb.Append(Json.GetStr(q, "question") ?? "");
                        var opts = Json.Get(q, "options") as List<object>;
                        if (opts != null) { int k = 1; foreach (var op in opts) { sb.Append(" [" + (k++) + "] " + (Json.GetStr(op, "label") ?? "")); } }
                        sb.Append(" ‖ ");
                    }
                SetState("needs-input", "question", Vt.Truncate(sb.ToString(), 400), true);
            }
            else if (evKey == "posttooluse" && (Json.GetStr(o, "tool_name") == "AskUserQuestion" || Json.GetStr(o, "toolName") == "AskUserQuestion"))
            {
                if (state == "needs-input") SetState("running", "answered", "", false);
            }
            else if (evKey == "userpromptsubmit")
            {
                hookTurnDone = false; idleAtPrompt = false;
                if (state != "running") SetState("running", "prompt-submitted", "", false);
            }
            else if (evKey == "sessionend")
            {
                // process exit follows; nothing to do here, the exit path labels it
            }
            else if (evKey == "sessionstart")
            {
                // session id captured above
            }
        }

        string LastAssistantFromTranscript()
        {
            try
            {
                if (string.IsNullOrEmpty(transcriptPath) || !File.Exists(transcriptPath)) return null;
                string last = null;
                using (var fs = new FileStream(transcriptPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var sr = new StreamReader(fs))
                {
                    string line;
                    while ((line = sr.ReadLine()) != null)
                    {
                        if (line.IndexOf("\"type\":\"assistant\"", StringComparison.Ordinal) < 0) continue;
                        object o; try { o = Json.Parse(line); } catch { continue; }
                        var content = Json.Get(o, "message", "content") as List<object>; if (content == null) continue;
                        var sb = new StringBuilder();
                        foreach (var c in content) { if (Json.GetStr(c, "type") == "text") sb.Append(Json.GetStr(c, "text")).Append(' '); }
                        if (sb.Length > 0) last = sb.ToString();
                    }
                }
                return last;
            }
            catch { return null; }
        }

        // ---- pipe server ----------------------------------------------------------------------------
        void PipeAcceptLoop()
        {
            while (!exited)
            {
                NamedPipeServerStream srv;
                try
                {
                    srv = new NamedPipeServerStream(pipeName, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
                        PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 65536, 65536);
                    srv.WaitForConnection();
                }
                catch { Thread.Sleep(200); continue; }
                var t = new Thread(() => ServeClient(srv)) { IsBackground = true, Name = "client" };
                t.Start();
            }
        }

        void ServeClient(NamedPipeServerStream p)
        {
            Subscriber sub = null;
            try
            {
                byte type; byte[] payload;
                while (Frame.Read(p, out type, out payload))
                {
                    switch (type)
                    {
                        case Frame.Input:
                            WriteInput(payload, 0, payload.Length); break;
                        case Frame.Paste:
                            WritePaste(payload); break;
                        case Frame.Wake:
                            wake.Set(); break;
                        case Frame.Resize:
                            if (payload.Length >= 4) pty.Resize(payload[0] | (payload[1] << 8), payload[2] | (payload[3] << 8)); break;
                        case Frame.Subscribe:
                            {
                                long off = BitConverter.ToInt64(payload, 0);
                                sub = new Subscriber { Pipe = p };
                                // Replay: first the requested slice of the log, then live. We register first so nothing is
                                // lost between the replay and the live edge; the duplicate window is at most one chunk.
                                long liveFrom;
                                lock (logLock) { liveFrom = bytes; }
                                lock (subs) subs.Add(sub);
                                if (off < 0) off = Math.Max(0, liveFrom + off);
                                if (off < liveFrom) ReplayLog(sub, off, liveFrom);
                                new Thread(sub.Pump) { IsBackground = true, Name = "pump" }.Start();
                                break;
                            }
                        case Frame.Query:
                            {
                                string js = File.Exists(Path.Combine(laneDir, "state.json")) ? File.ReadAllText(Path.Combine(laneDir, "state.json")) : "{}";
                                var b = Encoding.UTF8.GetBytes(js); lock (p) Frame.Write(p, Frame.JsonT, b); break;
                            }
                        case Frame.Kill:
                            {
                                string mode = Encoding.UTF8.GetString(payload);
                                if (mode == "hard") { pty.KillTree(); }
                                else { new Thread(() => SoftKill()) { IsBackground = true }.Start(); }
                                break;
                            }
                    }
                }
            }
            catch { }
            finally
            {
                if (sub != null) { lock (subs) subs.Remove(sub); lock (sub.Lock) sub.Dead = true; sub.Signal.Set(); }
                try { p.Dispose(); } catch { }
            }
        }

        void ReplayLog(Subscriber sub, long from, long to)
        {
            try
            {
                using (var fs = new FileStream(Path.Combine(laneDir, "console.log"), FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536))
                {
                    fs.Seek(from, SeekOrigin.Begin); var buf = new byte[65536]; long left = to - from;
                    while (left > 0) { int n = fs.Read(buf, 0, (int)Math.Min(buf.Length, left)); if (n <= 0) break; sub.Enqueue(Frame.Output, buf, 0, n); left -= n; }
                }
            }
            catch { }
        }

        void SoftKill()
        {
            // Ask the CLI to leave on its own terms, then escalate. Interactive CLIs: Esc (cancel any dialog), then /exit.
            try
            {
                if (kind == "claude" || kind == "codex")
                {
                    WriteInput(new byte[] { 0x1b }, 0, 1); Thread.Sleep(200);
                    var b = Encoding.UTF8.GetBytes("/exit\r"); WriteInput(b, 0, b.Length);
                    if (pty.WaitExit(8000)) return;
                    WriteInput(new byte[] { 0x03 }, 0, 1); Thread.Sleep(300); WriteInput(new byte[] { 0x03 }, 0, 1);
                    if (pty.WaitExit(4000)) return;
                }
                else
                {
                    WriteInput(new byte[] { 0x03 }, 0, 1);
                    if (pty.WaitExit(3000)) return;
                    var b = Encoding.UTF8.GetBytes("exit\r"); WriteInput(b, 0, b.Length);
                    if (pty.WaitExit(3000)) return;
                }
            }
            catch { }
            pty.KillTree();
        }
    }

    // ------------------------------------------------------------------------------------------------
    // attach: a console client. Runs inside a Windows Terminal tab; mirrors the PTY and forwards keys.
    // ------------------------------------------------------------------------------------------------
    static class Attach
    {
        static Native.ConsoleCtrlDelegate ctrlHandler;
        public static int Run(string[] a)
        {
            if (a.Length < 1) { Console.Error.WriteLine("usage: LaneHost attach <name> [--tail-bytes N]"); return 2; }
            string name = a[0]; long tailBytes = 262144;
            for (int i = 1; i < a.Length; i++) if (a[i] == "--tail-bytes" && i + 1 < a.Length) tailBytes = long.Parse(a[++i]);
            string pipeName = "lanes-" + name;

            IntPtr hin = Native.GetStdHandle(Native.STD_INPUT_HANDLE), hout = Native.GetStdHandle(Native.STD_OUTPUT_HANDLE);
            uint inMode, outMode; Native.GetConsoleMode(hin, out inMode); Native.GetConsoleMode(hout, out outMode);
            Native.SetConsoleMode(hin, (inMode & ~(Native.ENABLE_LINE_INPUT | Native.ENABLE_ECHO_INPUT | Native.ENABLE_PROCESSED_INPUT)) | Native.ENABLE_VIRTUAL_TERMINAL_INPUT | Native.ENABLE_WINDOW_INPUT);
            Native.SetConsoleMode(hout, outMode | Native.ENABLE_VIRTUAL_TERMINAL_PROCESSING | Native.ENABLE_PROCESSED_OUTPUT | Native.DISABLE_NEWLINE_AUTO_RETURN);
            Native.SetConsoleOutputCP(65001); Native.SetConsoleCP(65001);
            ctrlHandler = delegate(int t) { return true; };
            Native.SetConsoleCtrlHandler(ctrlHandler, true);  // Ctrl-C goes to the lane, not to us
            Console.Title = "lane " + name;

            int rc = 0;
            while (true)
            {
                var cli = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
                try { cli.Connect(3000); }
                catch
                {
                    string sp = Path.Combine(Paths.LanesRoot(), name, "state.json");
                    string st = "unknown";
                    try { if (File.Exists(sp)) { var d = Json.Parse(File.ReadAllText(sp)) as Dictionary<string, object>; st = Json.GetStr(d, "state") + " (" + Json.GetStr(d, "why") + ")"; } } catch { }
                    Console.Out.Write("\r\n\x1b[33m[lane " + name + ": host not reachable, state " + st + ". Press q to close this tab, any other key to retry]\x1b[0m\r\n");
                    var k = Console.ReadKey(true); if (k.KeyChar == 'q' || k.KeyChar == 'Q') { rc = 1; break; }
                    continue;
                }
                Console.Out.Write("\x1b[2J\x1b[H");  // clear: the replay redraws the current screen
                // send our size, subscribe to the tail
                SendSize(cli);
                Frame.Write(cli, Frame.Subscribe, BitConverter.GetBytes(-tailBytes));
                var stdout = Console.OpenStandardOutput();
                bool exited = false; int exitCode = 0;
                var reader = new Thread(() =>
                {
                    byte type; byte[] payload;
                    while (Frame.Read(cli, out type, out payload))
                    {
                        if (type == Frame.Output) { stdout.Write(payload, 0, payload.Length); stdout.Flush(); }
                        else if (type == Frame.Exit) { exited = true; int.TryParse(Encoding.UTF8.GetString(payload), out exitCode); break; }
                        else if (type == Frame.Gap) { var g = Encoding.UTF8.GetBytes("\r\n\x1b[33m[viewer fell behind by " + Encoding.UTF8.GetString(payload) + " bytes; the log is complete]\x1b[0m\r\n"); stdout.Write(g, 0, g.Length); }
                    }
                    exited = true;
                }) { IsBackground = true };
                reader.Start();

                // forward keys: ReadConsoleInput is too slow to hand-roll here; Console.In in VT mode yields escape sequences as chars.
                var stdin = Console.OpenStandardInput();
                var buf = new byte[4096];
                int lastCols = Console.WindowWidth, lastRows = Console.WindowHeight;
                var sizeTimer = new Timer(_ =>
                {
                    try { if (Console.WindowWidth != lastCols || Console.WindowHeight != lastRows) { lastCols = Console.WindowWidth; lastRows = Console.WindowHeight; SendSize(cli); } } catch { }
                }, null, 500, 500);
                try
                {
                    while (!exited)
                    {
                        int n = stdin.Read(buf, 0, buf.Length);
                        if (n <= 0) break;
                        lock (cli) Frame.Write(cli, Frame.Input, buf, 0, n);
                    }
                }
                catch { }
                sizeTimer.Dispose();
                if (exited)
                {
                    Console.Out.Write("\r\n\x1b[36m[lane " + name + " exited with code " + exitCode + ". Press any key to close]\x1b[0m\r\n");
                    try { Console.ReadKey(true); } catch { }
                    break;
                }
                // pipe broke (host died?) -> loop and offer retry
                Thread.Sleep(300);
            }
            Native.SetConsoleMode(hin, inMode); Native.SetConsoleMode(hout, outMode);
            return rc;
        }

        static void SendSize(Stream cli)
        {
            int c = 120, r = 40; try { c = Console.WindowWidth; r = Console.WindowHeight; } catch { }
            var b = new byte[] { (byte)c, (byte)(c >> 8), (byte)r, (byte)(r >> 8) };
            lock (cli) Frame.Write(cli, Frame.Resize, b);
        }
    }

    // ------------------------------------------------------------------------------------------------
    // hook: claude hook / codex notify target. Appends the payload to <laneDir>\hooks.jsonl.
    // ------------------------------------------------------------------------------------------------
    static class HookCmd
    {
        public static int Run(string[] a)
        {
            if (a.Length < 1) return 2;
            string laneDir = a[0]; string payload = null;
            if (a.Length >= 2 && a[1].TrimStart().StartsWith("{")) payload = a[1];   // codex passes JSON as an argument
            if (payload == null)
            {
                try { if (Console.IsInputRedirected) payload = Console.In.ReadToEnd(); } catch { }
            }
            if (string.IsNullOrEmpty(payload)) payload = "{}";
            payload = payload.Replace("\r", " ").Replace("\n", " ");
            // stamp the wall clock so the host can order it against output
            string row = "{\"_t\":\"" + DateTime.UtcNow.ToString("o") + "\",\"_event\":" + payload.Trim() + "}";
            // flatten: the host reads top-level keys, so merge _t into the event object itself
            row = payload.Trim();
            if (row.StartsWith("{") && row.EndsWith("}")) row = "{\"_t\":\"" + DateTime.UtcNow.ToString("o") + "\"," + row.Substring(1);
            bool created; string path = Path.Combine(laneDir, "hooks.jsonl");
            using (var m = new Mutex(false, "lanes-hooks-" + Path.GetFileName(laneDir).ToLowerInvariant(), out created))
            {
                bool got = false; try { got = m.WaitOne(5000); } catch (AbandonedMutexException) { got = true; }
                try
                {
                    using (var fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                    { var b = Encoding.UTF8.GetBytes(row + "\n"); fs.Write(b, 0, b.Length); }
                }
                finally { if (got) m.ReleaseMutex(); }
            }
            // Wake the host so it reads the row now rather than on its next tick (best effort; the tick is the fallback).
            try
            {
                string lane = Environment.GetEnvironmentVariable("LANES_LANE");
                if (string.IsNullOrEmpty(lane)) lane = Path.GetFileName(laneDir.TrimEnd('\\', '/'));
                using (var cli = new NamedPipeClientStream(".", "lanes-" + lane, PipeDirection.InOut, PipeOptions.None))
                { cli.Connect(500); Frame.Write(cli, Frame.Wake, null); Thread.Sleep(20); }
            }
            catch { }
            return 0;
        }
    }

    // ------------------------------------------------------------------------------------------------
    // serve: the viewer's web server. Static files + /api/lanes + /api/events + WebSocket /ws/<lane>.
    // ------------------------------------------------------------------------------------------------
    static class Serve
    {
        static string root = Paths.LanesRoot(), heads = Paths.HeadsRoot(), www = null; static int port = 7342;

        public static int Run(string[] a)
        {
            for (int i = 0; i < a.Length; i++)
            {
                string v = i + 1 < a.Length ? a[i + 1] : null;
                switch (a[i]) { case "--root": root = v; i++; break; case "--www": www = v; i++; break; case "--port": port = int.Parse(v); i++; break; case "--heads": heads = v; i++; break; }
            }
            if (www == null) www = Path.Combine(Path.GetDirectoryName(typeof(Serve).Assembly.Location), "..", "viewer");
            var l = new HttpListener();
            l.Prefixes.Add("http://127.0.0.1:" + port + "/");
            l.Prefixes.Add("http://localhost:" + port + "/");
            l.Start();
            Console.WriteLine("lanes viewer on http://127.0.0.1:" + port + "/  (root " + root + ")");
            Console.Out.Flush();
            Program.DetachStdio();   // same reason as the host: do not hold a launcher's pipe open
            while (true)
            {
                HttpListenerContext ctx;
                try { ctx = l.GetContext(); } catch { break; }
                ThreadPool.QueueUserWorkItem(_ => { try { Handle(ctx); } catch (Exception ex) { try { ctx.Response.StatusCode = 500; var b = Encoding.UTF8.GetBytes(ex.ToString()); ctx.Response.OutputStream.Write(b, 0, b.Length); ctx.Response.Close(); } catch { } } });
            }
            return 0;
        }

        static void Handle(HttpListenerContext ctx)
        {
            string path = ctx.Request.Url.AbsolutePath;
            if (path.StartsWith("/ws/") && ctx.Request.IsWebSocketRequest) { WsBridge(ctx, path.Substring(4)); return; }
            if (path == "/api/lanes") { Text(ctx, LanesJson(), "application/json"); return; }
            if (path.StartsWith("/api/log/"))
            {   // /api/log/<name>?tail=N   raw bytes
                string name = Uri.UnescapeDataString(path.Substring(9)); long tail = 65536; long.TryParse(ctx.Request.QueryString["tail"] ?? "65536", out tail);
                string f = Path.Combine(root, name, "console.log"); var resp = ctx.Response; resp.ContentType = "application/octet-stream";
                if (!File.Exists(f)) { resp.StatusCode = 404; resp.Close(); return; }
                using (var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                { long from = Math.Max(0, fs.Length - tail); fs.Seek(from, SeekOrigin.Begin); fs.CopyTo(resp.OutputStream); }
                resp.Close(); return;
            }
            if (path == "/api/events")
            {
                string head = ctx.Request.QueryString["head"] ?? "user"; int n = 100; int.TryParse(ctx.Request.QueryString["n"] ?? "100", out n);
                string f = Path.Combine(heads, head, "events.jsonl"); var rows = new List<string>();
                if (File.Exists(f)) { var all = File.ReadAllLines(f); for (int i = Math.Max(0, all.Length - n); i < all.Length; i++) rows.Add(all[i]); }
                Text(ctx, "[" + string.Join(",", rows.ToArray()) + "]", "application/json"); return;
            }
            if (path.StartsWith("/api/send/") && ctx.Request.HttpMethod == "POST")
            {
                string name = Uri.UnescapeDataString(path.Substring(10)); byte[] body; using (var ms = new MemoryStream()) { ctx.Request.InputStream.CopyTo(ms); body = ms.ToArray(); }
                using (var cli = new NamedPipeClientStream(".", "lanes-" + name, PipeDirection.InOut, PipeOptions.Asynchronous)) { cli.Connect(2000); Frame.Write(cli, Frame.Paste, body); Thread.Sleep(30); }
                Text(ctx, "{\"ok\":true}", "application/json"); return;
            }
            // static
            if (path == "/") path = "/index.html";
            string file = Path.GetFullPath(Path.Combine(www, path.TrimStart('/').Replace('/', '\\')));
            if (!file.StartsWith(Path.GetFullPath(www), StringComparison.OrdinalIgnoreCase)) { ctx.Response.StatusCode = 404; ctx.Response.Close(); return; }
            if (Directory.Exists(file)) file = Path.Combine(file, "index.html");
            if (!File.Exists(file)) { ctx.Response.StatusCode = 404; ctx.Response.Close(); return; }
            string ct = file.EndsWith(".html") ? "text/html; charset=utf-8" : file.EndsWith(".js") ? "application/javascript" : file.EndsWith(".css") ? "text/css" : "application/octet-stream";
            var bytes = File.ReadAllBytes(file); ctx.Response.ContentType = ct; ctx.Response.ContentLength64 = bytes.Length; ctx.Response.OutputStream.Write(bytes, 0, bytes.Length); ctx.Response.Close();
        }

        static void Text(HttpListenerContext ctx, string s, string ct)
        {
            var b = Encoding.UTF8.GetBytes(s); ctx.Response.ContentType = ct; ctx.Response.ContentLength64 = b.Length; ctx.Response.OutputStream.Write(b, 0, b.Length); ctx.Response.Close();
        }

        static string LanesJson()
        {
            var rows = new List<string>();
            if (Directory.Exists(root))
                foreach (var d in Directory.GetDirectories(root))
                {
                    string sp = Path.Combine(d, "state.json"); if (!File.Exists(sp)) continue;
                    try
                    {
                        string js = File.ReadAllText(sp);
                        var o = Json.Parse(js) as Dictionary<string, object>;
                        // truth check: is the host alive?
                        bool alive = HostAlive(o);
                        string st = Json.GetStr(o, "state");
                        if (!alive && (st == "running" || st == "needs-input" || st == "stalled" || st == "starting")) { o["state"] = "died"; o["why"] = "host-lost"; }
                        o["alive"] = alive;
                        rows.Add(Json.Val(o));
                    }
                    catch { }
                }
            return "[" + string.Join(",", rows.ToArray()) + "]";
        }

        public static bool HostAlive(Dictionary<string, object> o)
        {
            try
            {
                int pid = (int)(long)o["hostPid"]; var p = Process.GetProcessById(pid);
                string hs = Json.GetStr(o, "hostStart"); if (hs == null) return true;
                var t = DateTime.Parse(hs, null, DateTimeStyles.RoundtripKind).ToUniversalTime();
                return Math.Abs((p.StartTime.ToUniversalTime() - t).TotalSeconds) < 2;
            }
            catch { return false; }
        }

        static void WsBridge(HttpListenerContext ctx, string name)
        {
            name = Uri.UnescapeDataString(name);
            var wsc = ctx.AcceptWebSocketAsync(null).Result; var ws = wsc.WebSocket;
            var cli = new NamedPipeClientStream(".", "lanes-" + name, PipeDirection.InOut, PipeOptions.Asynchronous);
            try { cli.Connect(3000); }
            catch { ws.CloseAsync(WebSocketCloseStatus.EndpointUnavailable, "host not reachable", CancellationToken.None).Wait(); return; }
            long tailBytes = 131072; long.TryParse(ctx.Request.QueryString["tail"] ?? "131072", out tailBytes);
            Frame.Write(cli, Frame.Subscribe, BitConverter.GetBytes(-tailBytes));
            var cts = new CancellationTokenSource();
            // pipe -> ws
            var t1 = Task.Run(() =>
            {
                byte type; byte[] payload;
                try
                {
                    while (Frame.Read(cli, out type, out payload))
                    {
                        if (type == Frame.Output) ws.SendAsync(new ArraySegment<byte>(payload), WebSocketMessageType.Binary, true, cts.Token).Wait();
                        else if (type == Frame.Exit) { ws.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes("{\"exit\":" + Encoding.UTF8.GetString(payload) + "}")), WebSocketMessageType.Text, true, cts.Token).Wait(); break; }
                        else if (type == Frame.Gap) ws.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes("{\"gap\":" + Encoding.UTF8.GetString(payload) + "}")), WebSocketMessageType.Text, true, cts.Token).Wait();
                    }
                }
                catch { }
                try { ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "lane closed", CancellationToken.None).Wait(2000); } catch { }
            });
            // ws -> pipe : binary = input bytes; text = json {"resize":[cols,rows]} | {"input":"..."}
            var buf = new byte[65536];
            try
            {
                while (ws.State == WebSocketState.Open)
                {
                    var r = ws.ReceiveAsync(new ArraySegment<byte>(buf), cts.Token).Result;
                    if (r.MessageType == WebSocketMessageType.Close) break;
                    if (r.MessageType == WebSocketMessageType.Binary) { lock (cli) Frame.Write(cli, Frame.Input, buf, 0, r.Count); }
                    else
                    {
                        string s = Encoding.UTF8.GetString(buf, 0, r.Count);
                        var o = Json.Parse(s);
                        var rs = Json.Get(o, "resize") as List<object>;
                        if (rs != null && rs.Count == 2) { int c = (int)(long)rs[0], rr = (int)(long)rs[1]; lock (cli) Frame.Write(cli, Frame.Resize, new byte[] { (byte)c, (byte)(c >> 8), (byte)rr, (byte)(rr >> 8) }); }
                        string inp = Json.GetStr(o, "input"); if (inp != null) { var b = Encoding.UTF8.GetBytes(inp); lock (cli) Frame.Write(cli, Frame.Input, b); }
                    }
                }
            }
            catch { }
            cts.Cancel();
            try { cli.Dispose(); } catch { }
        }
    }

    // echo: raw-mode byte echo. Reads its console input as bytes and writes them straight back; the gauntlet's
    // witness for "two writers, one PTY, nothing interleaves mid-line".
    static class Echo
    {
        public static int Run()
        {
            IntPtr hin = Native.GetStdHandle(Native.STD_INPUT_HANDLE), hout = Native.GetStdHandle(Native.STD_OUTPUT_HANDLE);
            uint inMode, outMode; Native.GetConsoleMode(hin, out inMode); Native.GetConsoleMode(hout, out outMode);
            Native.SetConsoleMode(hin, (inMode & ~(Native.ENABLE_LINE_INPUT | Native.ENABLE_ECHO_INPUT | Native.ENABLE_PROCESSED_INPUT)) | Native.ENABLE_VIRTUAL_TERMINAL_INPUT);
            Native.SetConsoleMode(hout, outMode | Native.ENABLE_VIRTUAL_TERMINAL_PROCESSING | Native.ENABLE_PROCESSED_OUTPUT);
            Native.SetConsoleOutputCP(65001); Native.SetConsoleCP(65001);
            var stdin = Console.OpenStandardInput(); var stdout = Console.OpenStandardOutput();
            var buf = new byte[4096];
            Console.Out.Write("echo ready\r\n"); Console.Out.Flush();
            while (true)
            {
                int n = stdin.Read(buf, 0, buf.Length); if (n <= 0) break;
                bool quit = false;
                for (int i = 0; i < n; i++) if (buf[i] == 4) { quit = true; n = i; break; }   // Ctrl-D ends it
                stdout.Write(buf, 0, n); stdout.Flush();
                if (quit) break;
            }
            return 0;
        }
    }

    static class Program
    {
        public static void DetachStdio()
        {
            foreach (int which in new[] { Native.STD_INPUT_HANDLE, Native.STD_OUTPUT_HANDLE, Native.STD_ERROR_HANDLE })
            {
                try
                {
                    IntPtr h = Native.GetStdHandle(which);
                    if (h != IntPtr.Zero && h != new IntPtr(-1)) Native.CloseHandle(h);
                    Native.SetStdHandle(which, IntPtr.Zero);
                }
                catch { }
            }
        }

        static int Main(string[] args)
        {
            if (args.Length == 0) { Console.Error.WriteLine("LaneHost run|attach|hook|serve|probe"); return 2; }
            var rest = new string[args.Length - 1]; Array.Copy(args, 1, rest, 0, rest.Length);
            switch (args[0])
            {
                case "run": return Host.Run(rest);
                case "attach": return Attach.Run(rest);
                case "hook": return HookCmd.Run(rest);
                case "serve": return Serve.Run(rest);
                case "echo": return Echo.Run();
                case "probe": Console.WriteLine(Json.Obj("pid", Process.GetCurrentProcess().Id, "privateBytes", Process.GetCurrentProcess().PrivateMemorySize64, "workingSet", Process.GetCurrentProcess().WorkingSet64)); Thread.Sleep(int.Parse(rest.Length > 0 ? rest[0] : "0")); return 0;
                default: Console.Error.WriteLine("unknown verb " + args[0]); return 2;
            }
        }
    }
}
