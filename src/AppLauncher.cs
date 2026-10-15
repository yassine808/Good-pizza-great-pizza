// Good Pizza, Great Pizza - launcher (v2)
//
// Check-first provisioning. Every dependency is verified before anything is
// installed, every action is written to launcher.log with a timestamp, and the
// failure window only appears if a check fails - naming the check, the cause
// and a suggested fix. The only other UI is (a) a Yes/No question before WSA is
// downloaded and (b) a small non-blocking notice when the USER must act
// (Google sign-in, consent dialog).
//
// Hard constraints this file encodes (do not break):
//   1. Boot goes through protocol activation (wsa://). WsaClient.exe is never
//      launched directly: without package identity its DLL graph fails.
//   2. The game is installed by the Play Store only. PairIP kills any install
//      whose installerPackageName is not com.android.vending, so no APK push.
//   3. Google sign-in is the user's step. We poll for it, never enter credentials.
//   4. adb / developer mode is never required (a fresh WSA image has it OFF, so
//      port 58526 never opens). adb is used opportunistically only.
//
// WSA acquisition: if C:\WSA is missing we DOWNLOAD a community WSA build (Microsoft
// discontinued WSA, so there is no official source), but only after asking the user.
// Source is configurable: launcher.config, env vars, or CLI (see Cfg.Load).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Security.Cryptography;
using System.ServiceProcess;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Automation;
using System.Windows.Forms;
using Microsoft.Win32;

namespace GoodPizza
{
    // ------------------------------------------------------------- config
    // Precedence (later wins): defaults < launcher.config < environment < CLI.
    // launcher.config is "key=value" lines beside the exe; '#' starts a comment.
    // Keys: WsaRoot, WsaUrl, Repo, AssetRequire, AssetExclude, Sha256,
    //       BootTimeoutMin, InstallTimeoutMin, Yes, DownloadAdb, GameWindowTitle
    // Env : GP_WSA_ROOT, GP_WSA_URL, GP_WSA_REPO, GP_WSA_SHA256, GITHUB_TOKEN (API rate limit)
    // CLI : --WsaUrl=... --Repo=owner/name --yes (skip the download question)
    internal static class Cfg
    {
        public static string WsaRoot = @"C:\WSA";
        public static string WsaUrl = "";                       // direct URL; skips release discovery
        public static string Repo = "MustardChef/WSABuilds";    // UNVERIFIED default source - see report
        public static string AssetRequire = "x64";              // regex the asset name must match
        public static string AssetExclude = "arm64|Windows_10|NoGApps|WithoutGApps|Without-GApps";
        public static string Sha256 = "";                       // expected hash for WsaUrl downloads
        public static int BootTimeoutMin = 10;
        public static int InstallTimeoutMin = 30;
        public static bool Yes = false;                         // assume "yes" to the download question
        public static bool DownloadAdb = false;                 // optional platform-tools download
        public static string GameWindowTitle = "Pizza";

        public static string AppDir;
        public static string CacheDir;

        public static void Load(string appDir, string[] args)
        {
            AppDir = appDir;
            CacheDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "GoodPizza", "cache");

            try
            {
                var f = Path.Combine(appDir, "launcher.config");
                if (File.Exists(f))
                    foreach (var raw in File.ReadAllLines(f))
                    {
                        var line = raw.Trim();
                        if (line.Length == 0 || line[0] == '#') continue;
                        var i = line.IndexOf('=');
                        if (i > 0) Set(line.Substring(0, i).Trim(), line.Substring(i + 1).Trim());
                    }
            }
            catch { /* the log is not open yet; defaults are fine */ }

            Env("GP_WSA_ROOT", "WsaRoot"); Env("GP_WSA_URL", "WsaUrl");
            Env("GP_WSA_REPO", "Repo"); Env("GP_WSA_SHA256", "Sha256");

            foreach (var a in args)
            {
                if (!a.StartsWith("--")) continue;
                var s = a.Substring(2); var i = s.IndexOf('=');
                if (i < 0) Set(s, "true"); else Set(s.Substring(0, i), s.Substring(i + 1));
            }
        }

        static void Env(string env, string key)
        {
            var v = Environment.GetEnvironmentVariable(env);
            if (!string.IsNullOrEmpty(v)) Set(key, v);
        }

        static void Set(string k, string v)
        {
            int n;
            switch (k.ToLowerInvariant())
            {
                case "wsaroot": WsaRoot = v.TrimEnd('\\'); break;
                case "wsaurl": WsaUrl = v; break;
                case "repo": Repo = v; break;
                case "assetrequire": AssetRequire = v; break;
                case "assetexclude": AssetExclude = v; break;
                case "sha256": Sha256 = v; break;
                case "boottimeoutmin": if (int.TryParse(v, out n) && n > 0) BootTimeoutMin = n; break;
                case "installtimeoutmin": if (int.TryParse(v, out n) && n > 0) InstallTimeoutMin = n; break;
                case "yes": Yes = !v.Equals("false", StringComparison.OrdinalIgnoreCase); break;
                case "downloadadb": DownloadAdb = !v.Equals("false", StringComparison.OrdinalIgnoreCase); break;
                case "gamewindowtitle": GameWindowTitle = v; break;
            }
        }
    }

    // ------------------------------------------------------------- logger
    internal static class Log
    {
        static readonly object Sync = new object();
        static readonly List<string> Lines = new List<string>();
        static StreamWriter _w;
        static string _path;

        public static void Init(string preferredDir)
        {
            // The exe folder may be read-only (Program Files), so fall back to LocalAppData.
            var fallback = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GoodPizza");
            foreach (var dir in new[] { preferredDir, fallback })
            {
                try
                {
                    Directory.CreateDirectory(dir);
                    var p = Path.Combine(dir, "launcher.log");
                    if (File.Exists(p) && new FileInfo(p).Length > 5 * 1048576)
                    {
                        File.Delete(p + ".old");
                        File.Move(p, p + ".old");           // simple one-generation rotation
                    }
                    // FileShare.ReadWrite so the user can open the log while we run.
                    var fs = new FileStream(p, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
                    _w = new StreamWriter(fs, new UTF8Encoding(false)) { AutoFlush = true };
                    _path = p;
                    break;
                }
                catch { /* try the next location */ }
            }
            if (_w == null) Warn("file logging unavailable; log kept in memory only");

            Info("======================================================");
            Info("Good Pizza Great Pizza launcher");
            Info("exe      : " + Assembly.GetExecutingAssembly().Location);
            Info("version  : " + Assembly.GetExecutingAssembly().GetName().Version);
            Info("started  : " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture));
            Info("os       : " + Environment.OSVersion.VersionString);
            Info("64bit    : os=" + Environment.Is64BitOperatingSystem + " process=" + Environment.Is64BitProcess);
            Info("user     : " + Environment.UserDomainName + "\\" + Environment.UserName);
            Info("elevated : " + Program.IsElevated());
            Info("WsaRoot  : " + Cfg.WsaRoot);
            Info("log file : " + (_path ?? "(none)"));
            Info("------------------------------------------------------");
        }

        public static void Close()
        {
            lock (Sync)
            {
                if (_w != null) { try { _w.Flush(); _w.Dispose(); } catch { } _w = null; }
            }
        }

        public static void Step(string m) { Write("STEP", m); }
        public static void Info(string m) { Write("INFO", m); }
        public static void Ok(string m) { Write("OK  ", m); }
        public static void Warn(string m) { Write("WARN", m); }
        public static void Err(string m) { Write("ERR ", m); }

        static void Write(string lvl, string msg)
        {
            var line = DateTime.Now.ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture) + "  " + lvl + "  " + msg;
            lock (Sync)
            {
                Lines.Add(line);
                if (_w != null) { try { _w.WriteLine(line); } catch { } }
            }
        }

        public static string[] Snapshot() { lock (Sync) { return Lines.ToArray(); } }
        public static string FilePath { get { return _path; } }
    }

    // ------------------------------------------------ non-blocking user notice
    // The ONLY UI besides the download question and the failure window. Shown on its
    // own STA thread, never takes focus (it must not steal it from the Play Store).
    internal static class Notice
    {
        static readonly object L = new object();
        static Form _form;

        sealed class NoticeForm : Form
        {
            protected override bool ShowWithoutActivation { get { return true; } }
        }

        public static void Show(string title, string text)
        {
            Close();
            var ready = new ManualResetEvent(false);
            var t = new Thread(() =>
            {
                try
                {
                    var f = new NoticeForm
                    {
                        Text = title,
                        FormBorderStyle = FormBorderStyle.FixedToolWindow,
                        TopMost = true,
                        ShowInTaskbar = false,
                        StartPosition = FormStartPosition.Manual,
                        Size = new System.Drawing.Size(420, 140)
                    };
                    var wa = Screen.PrimaryScreen.WorkingArea;
                    f.Location = new System.Drawing.Point(wa.Right - f.Width - 12, wa.Bottom - f.Height - 12);
                    f.Controls.Add(new Label
                    {
                        Dock = DockStyle.Fill,
                        Text = text,
                        Padding = new Padding(10),
                        Font = new System.Drawing.Font("Segoe UI", 10)
                    });
                    f.Shown += (s, e) => ready.Set();
                    lock (L) { _form = f; }
                    Application.Run(f);
                }
                catch (Exception ex) { Log.Warn("notice window: " + ex.Message); }
                finally { ready.Set(); }
            });
            t.SetApartmentState(ApartmentState.STA);
            t.IsBackground = true;
            t.Start();
            ready.WaitOne(3000);
        }

        public static void Close()
        {
            Form f;
            lock (L) { f = _form; _form = null; }
            if (f == null) return;
            try { f.BeginInvoke(new Action(() => f.Close())); } catch { }
        }
    }

    // ------------------------------------------------------- logcat watcher
    // Reads WSA's own logcat straight off LocalState - no adb, no developer mode.
    // Incremental and line-based: it remembers a byte offset per file, so a 14 MB
    // boot log is read once, "Boot is finished" can never scroll out of a tail window,
    // and every regex runs on ONE line (a negated class in .NET matches newlines, which
    // once produced false positives across 517 unrelated lines).
    // Only files written since `floorUtc` count, so a previous session's log cannot
    // produce a false "boot finished".
    internal sealed class LogWatcher
    {
        readonly DateTime _floorUtc;
        readonly Dictionary<string, long> _offsets = new Dictionary<string, long>();
        readonly Dictionary<string, string> _carry = new Dictionary<string, string>();

        public bool BootFinished;
        public bool GameInstalled;

        static readonly TimeSpan Rx = TimeSpan.FromSeconds(2);
        static readonly string Pkg = Regex.Escape(Program.GamePackage);   // dots are metacharacters

        // Only lines that tie the package to an on-device path or a running process count;
        // a bare mention is NOT proof (opening the store listing logs market://...id=<pkg>).
        static readonly Regex InstalledRx = new Regex(
            "(/data/app/\\S*" + Pkg + "|Start proc \\S+.*" + Pkg + "|dexopt.*" + Pkg + "|Package \\[" + Pkg + "\\])",
            RegexOptions.Compiled, Rx);
        static readonly Regex RemovedRx = new Regex(
            "(removing package|package removed|deleting package|uninstall)",
            RegexOptions.Compiled | RegexOptions.IgnoreCase, Rx);

        public LogWatcher(DateTime floorUtc) { _floorUtc = floorUtc; }

        public static string LogcatDir
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "Packages", Program.PackageName, "LocalState", "diagnostics", "logcat");
            }
        }

        public void Poll()
        {
            try
            {
                if (!Directory.Exists(LogcatDir)) return;
                var files = new DirectoryInfo(LogcatDir).GetFiles("*.log")
                    .Where(f => f.LastWriteTimeUtc >= _floorUtc)
                    .OrderBy(f => f.LastWriteTimeUtc).ToArray();
                foreach (var f in files) ReadNew(f);
            }
            catch (Exception ex) { Log.Warn("  logcat watcher: " + ex.Message); }
        }

        void ReadNew(FileInfo f)
        {
            long off; _offsets.TryGetValue(f.FullName, out off);
            string carry; _carry.TryGetValue(f.FullName, out carry);
            if (f.Length < off) { off = 0; carry = null; }      // rotated/truncated
            if (f.Length == off) return;

            using (var fs = new FileStream(f.FullName, FileMode.Open, FileAccess.Read,
                                           FileShare.ReadWrite | FileShare.Delete))
            {
                fs.Position = off;
                var buf = new byte[1 << 20];
                int n;
                while ((n = fs.Read(buf, 0, buf.Length)) > 0)
                {
                    off += n;
                    var text = (carry ?? "") + Encoding.UTF8.GetString(buf, 0, n);
                    var cut = text.LastIndexOf('\n');
                    if (cut < 0) { carry = text.Length > 65536 ? "" : text; continue; }
                    carry = text.Substring(cut + 1);
                    foreach (var line in text.Substring(0, cut).Split('\n')) Process(line);
                }
            }
            _offsets[f.FullName] = off;
            _carry[f.FullName] = carry ?? "";
        }

        void Process(string line)
        {
            if (!BootFinished && line.IndexOf("Boot is finished", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                BootFinished = true;
                Log.Info("  logcat: \"Boot is finished\"");
            }
            if (line.IndexOf(Program.GamePackage, StringComparison.Ordinal) < 0) return;
            try
            {
                if (RemovedRx.IsMatch(line))
                {
                    if (GameInstalled) Log.Info("  logcat: removal evidence for " + Program.GamePackage);
                    GameInstalled = false;
                }
                else if (InstalledRx.IsMatch(line))
                {
                    if (!GameInstalled)
                    {
                        var t = line.Trim();
                        Log.Info("  logcat: install evidence: " + t.Substring(0, Math.Min(110, t.Length)));
                    }
                    GameInstalled = true;
                }
            }
            catch (RegexMatchTimeoutException) { }
        }
    }

    // -------------------------------------------------------------- program
    internal static class Program
    {
        // Tunables ------------------------------------------------------
        const int AdbPort = 58526;
        const int PollMs = 2000;
        const int StoreRefireMs = 45 * 1000;    // the store process dies on an unsigned image
        const int LaunchConfirmMs = 90 * 1000;

        internal const string PackageName = "MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe";
        internal const string PackageFamily = "MicrosoftCorporationII.WindowsSubsystemForAndroid";
        internal const string GamePackage = "com.tapblaze.pizzabusiness";
        internal const string PlayStore = "com.android.vending";
        const string UserAgent = "GoodPizzaLauncher/2.0 (+WSA provisioning)";

        static volatile bool Cancelled;
        static string _cause;               // human-readable reason for the last failure
        static string _tmpDir;              // extraction temp dir, cleaned on exit if unfinished
        static LogWatcher _watcher;
        static DateTime _bootStartUtc = DateTime.MinValue;
        static bool _adbConnected;

        internal static string MarkerPath { get { return Path.Combine(Cfg.WsaRoot, ".gp-complete"); } }

        sealed class StepDef
        {
            public string Name; public Func<bool> Body; public string Hint;
            public StepDef(string n, Func<bool> b, string h) { Name = n; Body = b; Hint = h; }
        }

        [STAThread]
        static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            try { ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072; } catch { }   // TLS 1.2
            try { ServicePointManager.SecurityProtocol |= (SecurityProtocolType)12288; } catch { }  // TLS 1.3 if supported

            var dir = AppDomain.CurrentDomain.BaseDirectory;
            Cfg.Load(dir, args);
            Log.Init(dir);

            bool created;
            Mutex mtx = null;
            try { mtx = new Mutex(true, "Global\\GoodPizzaGreatPizzaLauncher", out created); }
            catch (Exception ex) { Log.Warn("single-instance mutex: " + ex.Message); created = true; }
            if (!created)
            {
                Log.Warn("another launcher instance is already running; exiting");
                MessageBox.Show("The launcher is already running.", "Good Pizza, Great Pizza",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                Log.Close();
                return 2;
            }

            Console.CancelKeyPress += (s, e) => { e.Cancel = true; Cancelled = true; };
            AppDomain.CurrentDomain.ProcessExit += (s, e) => { Cancelled = true; Notice.Close(); CleanupTemp(); Log.Close(); };

            int exit;
            try { exit = Run(); }
            catch (OperationCanceledException) { Log.Warn("cancelled"); exit = 130; }
            catch (Exception ex) { Log.Err("unhandled exception: " + ex); exit = 1; ShowFailureWindow("unexpected error", ex.Message, ""); }

            try { mtx.ReleaseMutex(); } catch { }
            Log.Close();
            return exit;
        }

        static int Run()
        {
            var steps = new[]
            {
                new StepDef("Administrator rights", CheckAdmin, "Right-click the launcher and choose 'Run as administrator'."),
                new StepDef("Windows 11", CheckWindows11, "WSA needs Windows 11 (build 22000 or newer). Update Windows."),
                new StepDef("virtualization", CheckVirtualization, "Enable virtualization (VT-x/AMD-V/SVM) in BIOS, enable 'Virtual Machine Platform', then reboot."),
                new StepDef("WSA payload", EnsurePayload, "Check your internet connection and free disk space, or set WsaUrl in launcher.config."),
                new StepDef("WSA dependencies", EnsureDependencies, "Re-run; if it persists, delete C:\\WSA so it is downloaded again."),
                new StepDef("WSA registration", EnsureRegistered, "Make sure no other WSA copy is registered; run 'Get-AppxPackage *WindowsSubsystemForAndroid* | Remove-AppxPackage' and retry."),
                new StepDef("userdata template", EnsureUserdataTemplate, "Enable the Hyper-V PowerShell module, or ensure diskpart works and C: has 1 GB free."),
                new StepDef("WsaService", EnsureService, "Reboot, then re-run. WSA may not be registered correctly."),
                new StepDef("WSA boot", BootWsa, "Check virtualization, free RAM (4 GB+), and the log for a WsaClient crash."),
                new StepDef("Play Store + game install", EnsureStoreAndGame, "Sign in to a Google account in the Play Store window and install the game, then re-run."),
                new StepDef("launch", LaunchGame, "Start the game manually from the Start menu; see the log for details.")
            };

            if (Cfg.DownloadAdb) { /* optional; handled inside EnsurePayload's tail */ }

            for (int i = 0; i < steps.Length; i++)
            {
                var s = steps[i];
                var label = "check " + (i + 1) + "/" + steps.Length + " - " + s.Name;
                _cause = null;
                Log.Step(label + " ...");
                var sw = Stopwatch.StartNew();
                bool ok;
                try { ok = s.Body(); }
                catch (OperationCanceledException) { throw; }
                catch (Exception ex) { ok = Fail(Describe(ex)); }
                sw.Stop();
                var secs = N(sw.Elapsed.TotalSeconds);
                if (!ok)
                {
                    Log.Err(label + " FAILED (" + secs + "s): " + (_cause ?? "see log"));
                    Log.Err("full log: " + Log.FilePath);
                    ShowFailureWindow(label, _cause ?? "(no detail)", s.Hint);
                    return 10 + i;      // distinct exit code per failed step
                }
                Log.Ok(label + " passed (" + secs + "s)");
            }
            Log.Ok("all checks passed; game launched");
            return 0;
        }

        // -------------------------------------------------------- helpers
        static string N(double v) { return v.ToString("0.0", CultureInfo.InvariantCulture); }
        static string MB(long bytes) { return (bytes / 1048576.0).ToString("0", CultureInfo.InvariantCulture); }
        static string Size(long b)
        {
            return b >= 1073741824L ? (b / 1073741824.0).ToString("0.0", CultureInfo.InvariantCulture) + " GB"
                                    : MB(b) + " MB";
        }

        static bool Fail(string cause) { _cause = cause; Log.Err(cause); return false; }

        static void Wait(int ms)
        {
            var sw = Stopwatch.StartNew();
            do
            {
                if (Cancelled) throw new OperationCanceledException();
                if (ms <= 0) return;
                Thread.Sleep((int)Math.Min(200, Math.Max(1, ms - sw.ElapsedMilliseconds)));
            } while (sw.ElapsedMilliseconds < ms);
        }

        internal static bool IsElevated()
        {
            try
            {
                using (var id = System.Security.Principal.WindowsIdentity.GetCurrent())
                    return new System.Security.Principal.WindowsPrincipal(id)
                        .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
            }
            catch { return false; }
        }

        static string Describe(Exception ex)
        {
            var wex = ex as WebException;
            if (wex != null)
            {
                var hr = wex.Response as HttpWebResponse;
                if (hr != null) return "HTTP " + (int)hr.StatusCode + " " + hr.StatusDescription;
                switch (wex.Status)
                {
                    case WebExceptionStatus.NameResolutionFailure: return "DNS lookup failed (offline?)";
                    case WebExceptionStatus.ConnectFailure: return "could not connect (offline or blocked)";
                    case WebExceptionStatus.Timeout: return "request timed out";
                    default: return "network error: " + wex.Status + " - " + wex.Message;
                }
            }
            return ex.Message;
        }

        static bool IsDiskFull(Exception ex)
        {
            var io = ex as IOException;
            if (io == null) return false;
            var code = io.HResult & 0xFFFF;
            return code == 112 || code == 39;       // ERROR_DISK_FULL / ERROR_HANDLE_DISK_FULL
        }

        static string PsQuote(string s) { return "'" + s.Replace("'", "''") + "'"; }

        static int CountProcs(string name)
        {
            var p = Process.GetProcessesByName(name);
            try { return p.Length; } finally { foreach (var x in p) x.Dispose(); }
        }

        static bool Open(string uri)
        {
            try { using (Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true })) { } return true; }
            catch (Exception ex) { Log.Warn("  could not open " + uri + ": " + ex.Message); return false; }
        }

        // PowerShell must be 64-bit: under WOW64 the Hyper-V module, optional-feature and
        // package cmdlets misbehave. Sysnative reaches the 64-bit one from a 32-bit exe.
        static string PsExe()
        {
            var win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            var sys = (!Environment.Is64BitProcess && Environment.Is64BitOperatingSystem) ? "Sysnative" : "System32";
            return Path.Combine(win, sys, "WindowsPowerShell", "v1.0", "powershell.exe");
        }

        // -EncodedCommand removes every quoting problem (apostrophes in paths, etc.), and the
        // try/catch + 'Stop' turns cmdlet failures into a non-zero exit code we can trust.
        static bool RunPs(string script, string tag, int timeoutMs, out string output)
        {
            var wrapped = "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';" +
                          "try{" + script + "}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}";
            var enc = Convert.ToBase64String(Encoding.Unicode.GetBytes(wrapped));
            return Run(PsExe(), "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + enc,
                       tag, timeoutMs, out output);
        }

        static bool Run(string exe, string args, string tag, int timeoutMs, out string output)
        {
            try
            {
                var psi = new ProcessStartInfo(exe, args)
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };
                var sb = new StringBuilder();
                using (var p = new Process { StartInfo = psi })
                {
                    p.OutputDataReceived += (s, e) => { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
                    p.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
                    p.Start();
                    p.BeginOutputReadLine();
                    p.BeginErrorReadLine();
                    if (!p.WaitForExit(timeoutMs))
                    {
                        try { p.Kill(); } catch { }
                        Log.Warn("timeout on [" + tag + "] after " + timeoutMs + " ms");
                        lock (sb) output = sb.ToString();
                        return false;
                    }
                    p.WaitForExit();    // drain async readers
                    lock (sb) output = sb.ToString();
                    if (p.ExitCode != 0) Log.Info("[" + tag + "] exit=" + p.ExitCode);
                    return p.ExitCode == 0;
                }
            }
            catch (Exception ex)
            {
                Log.Warn("[" + tag + "] could not run " + exe + ": " + ex.Message);
                output = ex.Message;
                return false;
            }
        }

        static bool PortOpen(int port)
        {
            try
            {
                using (var c = new TcpClient())
                {
                    var r = c.BeginConnect("127.0.0.1", port, null, null);
                    if (!r.AsyncWaitHandle.WaitOne(700, false)) return false;   // Dispose cancels the connect
                    try { c.EndConnect(r); return true; } catch { return false; }
                }
            }
            catch { return false; }
        }

        static void CleanupTemp()
        {
            try { if (_tmpDir != null && Directory.Exists(_tmpDir)) Directory.Delete(_tmpDir, true); } catch { }
        }

        // ------------------------------------------------------ 1. admin
        static bool CheckAdmin()
        {
            Log.Info("process 64-bit: " + Environment.Is64BitProcess);
            if (!IsElevated()) return Fail("not running as administrator (needed for WSA registration, services and C:\\WSA)");
            return true;
        }

        // --------------------------------------------------- 2. windows 11
        static bool CheckWindows11()
        {
            Log.Info("reported version: " + Environment.OSVersion.Version);
            using (var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
            {
                if (key != null)
                {
                    var id = key.GetValue("CurrentBuildNumber") ?? key.GetValue("CurrentBuild");
                    Log.Info("CurrentBuild=" + id + "  DisplayVersion=" + key.GetValue("DisplayVersion"));
                    int build;
                    if (id != null && int.TryParse(id.ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out build))
                    {
                        Log.Info("build " + build + "; WSA needs 22000+");
                        return build >= 22000 || Fail("Windows build " + build + " is older than 22000 (Windows 11)");
                    }
                }
            }
            Log.Warn("could not read build number; trusting OSVersion");
            var v = Environment.OSVersion.Version;
            return (v.Major >= 10 && v.Build >= 22000) || Fail("Windows build " + v.Build + " is older than 22000");
        }

        // ------------------------------------------------ 3. virtualization
        // HypervisorPresent=True is authoritative: it means the hypervisor is actually
        // running (feature enabled, rebooted, and enabled in firmware). Only when it is
        // False do we ask the slower feature query, purely to give an accurate message.
        static bool CheckVirtualization()
        {
            string o;
            bool hv = false;
            if (RunPs("(Get-CimInstance Win32_ComputerSystem).HypervisorPresent", "hypervisor", 30000, out o))
            {
                Log.Info("HypervisorPresent: " + o.Trim());
                hv = o.Trim().Equals("True", StringComparison.OrdinalIgnoreCase);
            }
            if (hv) return true;

            var vmp = "unknown";
            if (RunPs("(Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform).State.ToString()",
                      "vmp", 120000, out o)) vmp = o.Trim();
            Log.Warn("VirtualMachinePlatform: " + vmp);

            if (vmp.IndexOf("Enabled", StringComparison.OrdinalIgnoreCase) >= 0)
                return Fail("Virtual Machine Platform is enabled but no hypervisor is running: reboot, or turn on virtualization (VT-x / AMD-V / SVM) in the BIOS");
            if (vmp.IndexOf("Pending", StringComparison.OrdinalIgnoreCase) >= 0)
                return Fail("Virtual Machine Platform was just enabled; reboot Windows and re-run");
            return Fail("Virtual Machine Platform is not enabled (state: " + vmp + "). Enable it in 'Windows Features' and reboot");
        }

        // -------------------------------------------------------- 4. payload
        static bool PayloadComplete()
        {
            var manifest = Path.Combine(Cfg.WsaRoot, "AppxManifest.xml");
            if (!File.Exists(manifest)) return false;
            if (File.Exists(MarkerPath)) return true;                 // our own completed install
            if (File.Exists(Path.Combine(Cfg.WsaRoot, "WsaClient.exe")))
            {
                Log.Warn("no completion marker, but manifest + WsaClient.exe exist; accepting a manual install");
                return true;
            }
            Log.Warn("AppxManifest.xml present but WsaClient.exe missing - install looks incomplete");
            return false;
        }

        sealed class Asset
        {
            public string Name, Url, Sha256, Source;
            public long Size = -1;
        }

        static bool EnsurePayload()
        {
            if (PayloadComplete())
            {
                var di = new DirectoryInfo(Cfg.WsaRoot);
                var files = di.EnumerateFiles("*", SearchOption.AllDirectories).ToArray();
                Log.Info("WSA present: " + MB(files.Sum(f => f.Length)) + " MB, " + files.Length + " files");
                OptionalAdb();
                return true;
            }

            Log.Info("WSA is not installed at " + Cfg.WsaRoot + "; it must be downloaded");
            Directory.CreateDirectory(Cfg.CacheDir);

            string archive;
            if (!ObtainArchive(out archive)) return false;
            if (!ExtractAndInstall(archive)) return false;
            OptionalAdb();
            return true;
        }

        static bool ObtainArchive(out string archive)
        {
            archive = null;
            Asset a = null; string discoverErr = null;
            try { a = Cfg.WsaUrl.Length > 0 ? FromUrl(Cfg.WsaUrl) : Discover(); }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex) { discoverErr = Describe(ex); Log.Warn("download source lookup failed: " + discoverErr); }

            if (a == null)
            {
                // Offline? A previously downloaded archive can still be used.
                var cached = FindCachedArchive();
                if (cached != null)
                {
                    Log.Warn("using cached archive without verification: " + cached);
                    archive = cached; return true;
                }
                return Fail("could not find a WSA download (" + discoverErr + "). Check your connection or set WsaUrl in launcher.config");
            }

            var target = Path.Combine(Cfg.CacheDir, a.Name);
            if (File.Exists(target) && CacheValid(target, a))
            {
                Log.Ok("verified cached archive: " + target);
                archive = target; return true;
            }

            if (!Confirm(a)) return Fail("WSA download declined by the user");
            if (!NeedSpace(a.Size > 0 ? a.Size : 3L * 1073741824)) return false;
            if (!DownloadFile(a.Url, target, a.Size, a.Sha256, a.Name)) return false;
            archive = target;
            return true;
        }

        static Asset FromUrl(string url)
        {
            var name = Path.GetFileName(new Uri(url).LocalPath);
            if (string.IsNullOrEmpty(name)) name = "wsa-download.zip";
            return new Asset { Name = name, Url = url, Sha256 = Cfg.Sha256, Source = "configured URL" };
        }

        static string FindCachedArchive()
        {
            try
            {
                return new DirectoryInfo(Cfg.CacheDir).GetFiles()
                    .Where(f => f.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) ||
                                f.Name.EndsWith(".7z", StringComparison.OrdinalIgnoreCase))
                    .OrderByDescending(f => f.LastWriteTimeUtc).Select(f => f.FullName).FirstOrDefault();
            }
            catch { return null; }
        }

        static bool CacheValid(string path, Asset a)
        {
            if (!string.IsNullOrEmpty(a.Sha256))
                return Sha256Of(path).Equals(a.Sha256, StringComparison.OrdinalIgnoreCase);
            if (a.Size > 0) return new FileInfo(path).Length == a.Size;
            Log.Warn("cached archive cannot be verified (no hash or size)");
            return true;
        }

        // Ask before downloading several GB (and, for .7z, a small extractor).
        static bool Confirm(Asset a)
        {
            if (Cfg.Yes) { Log.Info("download pre-approved (--yes)"); return true; }
            var sb = new StringBuilder();
            sb.AppendLine("Windows Subsystem for Android (WSA) was not found on this PC.");
            sb.AppendLine("Microsoft no longer distributes it, so the launcher can download a community build:");
            sb.AppendLine();
            sb.AppendLine("  File:    " + a.Name);
            sb.AppendLine("  Size:    " + (a.Size > 0 ? Size(a.Size) : "unknown (several GB)"));
            sb.AppendLine("  Source:  " + a.Source);
            sb.AppendLine("  Install: " + Cfg.WsaRoot);
            if (a.Name.EndsWith(".7z", StringComparison.OrdinalIgnoreCase) && Find7z() == null)
                sb.AppendLine("  Also:    7-Zip's small extractor (7zr.exe) from 7-zip.org");
            if (string.IsNullOrEmpty(a.Sha256))
                sb.AppendLine("  Note:    no checksum is published for this file, so integrity is checked by size only.");
            sb.AppendLine();
            sb.Append("Download and install it now?");
            Log.Info("asking user to approve download of " + a.Name);
            var r = MessageBox.Show(sb.ToString(), "Good Pizza, Great Pizza - download WSA?",
                MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button1);
            Log.Info("user answered: " + r);
            return r == DialogResult.Yes;
        }

        // ---- release discovery (GitHub Releases API) ------------------------------
        // Nothing here hardcodes a file URL: the asset is found by name pattern, newest
        // release first. The SOURCE REPO is an assumption (configurable) - see the report.
        static string HttpGetString(string url)
        {
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.UserAgent = UserAgent;
            req.Accept = "application/vnd.github+json";
            req.Timeout = 30000;
            req.ReadWriteTimeout = 30000;
            var tok = Environment.GetEnvironmentVariable("GITHUB_TOKEN");
            if (!string.IsNullOrEmpty(tok)) req.Headers["Authorization"] = "Bearer " + tok;
            using (var resp = (HttpWebResponse)req.GetResponse())
            using (var sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                return sr.ReadToEnd();
        }

        static string Str(Dictionary<string, object> d, string k)
        {
            object v; return d.TryGetValue(k, out v) && v != null ? v.ToString() : "";
        }

        static Asset Discover()
        {
            var url = "https://api.github.com/repos/" + Cfg.Repo + "/releases?per_page=20";
            Log.Info("looking for a WSA build: " + url);
            string json = null;
            for (int i = 1; i <= 3 && json == null; i++)
            {
                try { json = HttpGetString(url); }
                catch (OperationCanceledException) { throw; }
                catch (Exception ex)
                {
                    var hr = (ex as WebException) != null ? ((WebException)ex).Response as HttpWebResponse : null;
                    if (hr != null && (int)hr.StatusCode == 404) throw new InvalidOperationException("repository " + Cfg.Repo + " not found (HTTP 404)");
                    Log.Warn("  attempt " + i + ": " + Describe(ex));
                    if (i == 3) throw;
                    Wait(2000 * i);
                }
            }

            var ser = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
            var rels = ser.DeserializeObject(json) as object[];
            if (rels == null) throw new InvalidOperationException("unexpected response from the GitHub API");

            var require = new Regex(Cfg.AssetRequire, RegexOptions.IgnoreCase);
            var exclude = Cfg.AssetExclude.Length > 0 ? new Regex(Cfg.AssetExclude, RegexOptions.IgnoreCase) : null;
            var seen = new List<string>();

            foreach (var r in rels)
            {
                var rd = r as Dictionary<string, object>;
                if (rd == null) continue;
                object draft; if (rd.TryGetValue("draft", out draft) && draft is bool && (bool)draft) continue;
                object av; if (!rd.TryGetValue("assets", out av)) continue;
                var assets = av as object[]; if (assets == null) continue;

                Asset best = null; int bestScore = -1;
                foreach (var x in assets)
                {
                    var ad = x as Dictionary<string, object>; if (ad == null) continue;
                    var name = Str(ad, "name"); seen.Add(name);
                    var isZip = name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase);
                    if (!isZip && !name.EndsWith(".7z", StringComparison.OrdinalIgnoreCase)) continue;
                    if (!require.IsMatch(name)) continue;
                    if (exclude != null && exclude.IsMatch(name)) continue;
                    // The Play Store is mandatory (constraint 2), so only GApps builds qualify.
                    if (!Regex.IsMatch(name, "MindTheGapps|OpenGApps|GApps", RegexOptions.IgnoreCase)) continue;

                    var score = 50;
                    if (Regex.IsMatch(name, "Windows_?11|Win_?11", RegexOptions.IgnoreCase)) score += 30;
                    if (isZip) score += 20;                        // zip needs no extra tool
                    if (score <= bestScore) continue;

                    var digest = Str(ad, "digest");               // "sha256:<hex>" when GitHub provides it
                    if (digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)) digest = digest.Substring(7); else digest = "";
                    long size = -1; long.TryParse(Str(ad, "size"), NumberStyles.Integer, CultureInfo.InvariantCulture, out size);
                    bestScore = score;
                    best = new Asset
                    {
                        Name = name, Url = Str(ad, "browser_download_url"), Sha256 = digest, Size = size,
                        Source = "github.com/" + Cfg.Repo + " release " + Str(rd, "tag_name")
                    };
                }
                if (best != null && best.Url.Length > 0)
                {
                    Log.Info("selected " + best.Name + " (" + Size(best.Size) + ") from " + best.Source +
                             (best.Sha256.Length > 0 ? ", sha256 published" : ", no sha256 published"));
                    return best;
                }
            }
            throw new InvalidOperationException("no matching .zip/.7z GApps x64 asset in the latest releases of " + Cfg.Repo +
                " (assets seen: " + string.Join(", ", seen.Take(8).ToArray()) + ")");
        }

        // ---- disk space -------------------------------------------------------------
        static long Free(string path)
        {
            try { return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(path))).AvailableFreeSpace; }
            catch { return long.MaxValue; }
        }

        // archive on the cache drive; extraction (~3x, refined exactly for .zip later) on the WSA drive
        static bool NeedSpace(long archiveSize)
        {
            var cacheRoot = Path.GetPathRoot(Path.GetFullPath(Cfg.CacheDir));
            var wsaRoot = Path.GetPathRoot(Path.GetFullPath(Cfg.WsaRoot));
            long needCache = archiveSize + 256L * 1048576;
            long needWsa = archiveSize * 3 + 512L * 1048576;
            bool same = string.Equals(cacheRoot, wsaRoot, StringComparison.OrdinalIgnoreCase);
            var needA = same ? needCache + needWsa : needCache;
            Log.Info("free space: cache drive " + Size(Free(Cfg.CacheDir)) + " (need " + Size(needA) + "), WSA drive " +
                     Size(Free(Cfg.WsaRoot)) + " (need " + Size(needWsa) + ")");
            if (Free(Cfg.CacheDir) < needA) return Fail("not enough free disk space on " + cacheRoot + " (need about " + Size(needA) + ")");
            if (!same && Free(Cfg.WsaRoot) < needWsa) return Fail("not enough free disk space on " + wsaRoot + " (need about " + Size(needWsa) + ")");
            return true;
        }

        // ---- download with resume, retries, progress, hash --------------------------
        static bool DownloadFile(string url, string dest, long expectedSize, string expectedSha, string label)
        {
            var part = dest + ".part";
            const int maxAttempts = 5;
            for (int attempt = 1; attempt <= maxAttempts; attempt++)
            {
                Wait(0);
                try
                {
                    Log.Info("downloading " + label + " (attempt " + attempt + "/" + maxAttempts + ")");
                    DownloadOnce(url, part, expectedSize);

                    var len = new FileInfo(part).Length;
                    if (expectedSize > 0 && len != expectedSize)
                    {
                        if (len > expectedSize) File.Delete(part);
                        throw new IOException("size mismatch: have " + len + ", expected " + expectedSize);
                    }
                    if (!string.IsNullOrEmpty(expectedSha))
                    {
                        Log.Info("verifying SHA-256 ...");
                        var got = Sha256Of(part);
                        if (!got.Equals(expectedSha, StringComparison.OrdinalIgnoreCase))
                        {
                            File.Delete(part);
                            return Fail("SHA-256 mismatch for " + label + " (got " + got + ", expected " + expectedSha + "); the file was discarded");
                        }
                        Log.Ok("SHA-256 verified");
                    }
                    else Log.Warn("no SHA-256 available for " + label + "; integrity not verified beyond size");

                    if (File.Exists(dest)) File.Delete(dest);
                    File.Move(part, dest);
                    Log.Ok("downloaded " + label + " -> " + dest);
                    return true;
                }
                catch (OperationCanceledException) { throw; }
                catch (Exception ex)
                {
                    if (IsDiskFull(ex)) return Fail("disk full while downloading " + label);
                    var hr = (ex as WebException) != null ? ((WebException)ex).Response as HttpWebResponse : null;
                    if (hr != null && ((int)hr.StatusCode == 404 || (int)hr.StatusCode == 410))
                        return Fail("download URL is gone (HTTP " + (int)hr.StatusCode + "): " + url);
                    Log.Warn("  download problem: " + Describe(ex));
                    if (attempt == maxAttempts) return Fail("download failed after " + maxAttempts + " attempts: " + Describe(ex));
                    Wait(Math.Min(60000, 2000 << attempt));     // 4s, 8s, 16s, 32s
                }
            }
            return false;
        }

        static void DownloadOnce(string url, string part, long expectedSize)
        {
            long have = File.Exists(part) ? new FileInfo(part).Length : 0;
            if (expectedSize > 0 && have > expectedSize) { File.Delete(part); have = 0; }
            if (expectedSize > 0 && have == expectedSize) { Log.Info("  .part file is already complete"); return; }

            var req = (HttpWebRequest)WebRequest.Create(url);
            req.UserAgent = UserAgent;
            req.Timeout = 30000;
            req.ReadWriteTimeout = 60000;
            req.AllowAutoRedirect = true;
            if (have > 0) req.AddRange(have);

            HttpWebResponse resp;
            try { resp = (HttpWebResponse)req.GetResponse(); }
            catch (WebException wex)
            {
                // 416 = "range not satisfiable": the .part file no longer
                // matches what the server has (re-uploaded or truncated
                // remotely), so resume is impossible and we restart cleanly.
                // Written as a runtime branch rather than `catch ... when`
                // because that is a C# 6 exception filter and this file
                // compiles with the .NET Framework csc (C# 5).
                var bad = wex.Response as HttpWebResponse;
                if (bad == null || (int)bad.StatusCode != 416) throw;
                try { bad.Close(); } catch { }
                File.Delete(part);
                throw new IOException("server rejected the resume range; restarting from zero");
            }

            using (resp)
            {
                var resumed = have > 0 && resp.StatusCode == HttpStatusCode.PartialContent;
                if (!resumed) have = 0;
                long total = resp.ContentLength >= 0 ? have + resp.ContentLength : expectedSize;
                Log.Info(resumed ? "  resuming at " + Size(have) : "  starting; size " + (total > 0 ? Size(total) : "unknown"));

                using (var src = resp.GetResponseStream())
                using (var dst = new FileStream(part, resumed ? FileMode.Append : FileMode.Create,
                                                FileAccess.Write, FileShare.Read))
                {
                    var buf = new byte[81920];
                    long done = have, startBytes = have, lastLog = 0;
                    var sw = Stopwatch.StartNew();
                    int n;
                    while ((n = src.Read(buf, 0, buf.Length)) > 0)
                    {
                        if (Cancelled) throw new OperationCanceledException();
                        dst.Write(buf, 0, n);
                        done += n;
                        if (sw.ElapsedMilliseconds - lastLog >= 5000)      // throttled progress
                        {
                            lastLog = sw.ElapsedMilliseconds;
                            var rate = (done - startBytes) / 1048576.0 / Math.Max(0.001, sw.Elapsed.TotalSeconds);
                            Log.Info("  " + (total > 0 ? N(done * 100.0 / total) + "%  " : "") +
                                     MB(done) + " MB  " + N(rate) + " MB/s");
                        }
                    }
                    if (total > 0 && done != total) throw new IOException("connection closed early at " + MB(done) + " of " + MB(total) + " MB");
                }
            }
        }

        static string Sha256Of(string path)
        {
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
            using (var h = SHA256.Create())
                return BitConverter.ToString(h.ComputeHash(fs)).Replace("-", "").ToLowerInvariant();
        }

        // ---- extraction (temp dir -> atomic move, zip-slip guarded) ----------------
        static bool ExtractAndInstall(string archive)
        {
            var root = Cfg.WsaRoot;
            var tmp = root + ".extracting";
            _tmpDir = tmp;
            try
            {
                if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
                Directory.CreateDirectory(tmp);

                bool ok;
                try
                {
                    ok = archive.EndsWith(".7z", StringComparison.OrdinalIgnoreCase)
                        ? Extract7z(archive, tmp) : ExtractZip(archive, tmp);
                }
                catch (InvalidDataException ex)
                {
                    try { File.Delete(archive); } catch { }
                    return Fail("downloaded archive is corrupt (" + ex.Message + "); it was deleted - re-run to download again");
                }
                if (!ok) return false;

                var payload = FindManifestRoot(tmp);
                if (payload == null) return Fail("archive extracted but contains no AppxManifest.xml - it is not a WSA build");

                // A half-installed or foreign C:\WSA is moved aside, never deleted.
                if (Directory.Exists(root))
                {
                    if (Directory.EnumerateFileSystemEntries(root).Any())
                    {
                        var aside = root + ".old-" + DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
                        Log.Warn("existing " + root + " is not a complete install; moving it to " + aside);
                        Directory.Move(root, aside);
                    }
                    else Directory.Delete(root);
                }
                Directory.Move(payload, root);          // same volume: atomic rename
                File.WriteAllText(MarkerPath,
                    "archive=" + Path.GetFileName(archive) + "\r\ncompleted=" +
                    DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + "\r\n");
                Log.Ok("WSA installed to " + root);
                return true;
            }
            catch (IOException ex)
            {
                // One catch with a branch, not two catch clauses: without C# 6
                // exception filters two `catch (IOException ...)` handlers would
                // be an unreachable-block error. IsDiskFull decides which of
                // the two distinct causes we report.
                if (!IsDiskFull(ex))
                    return Fail("could not place WSA files in " + root + ": " + ex.Message +
                                " (is WSA running or a file locked?)");
                return Fail("disk full while extracting: " + ex.Message);
            }
            finally { CleanupTemp(); _tmpDir = null; }
        }

        static string FindManifestRoot(string dir)
        {
            if (File.Exists(Path.Combine(dir, "AppxManifest.xml"))) return dir;
            var hit = Directory.GetFiles(dir, "AppxManifest.xml", SearchOption.AllDirectories)
                .OrderBy(p => p.Length).FirstOrDefault();
            return hit == null ? null : Path.GetDirectoryName(hit);
        }

        static bool ExtractZip(string zip, string dest)
        {
            Log.Info("extracting " + zip + " -> " + dest);
            using (var za = ZipFile.OpenRead(zip))
            {
                long total = za.Entries.Sum(e => e.Length);
                var need = total + 512L * 1048576;
                if (Free(dest) < need) return Fail("not enough free space to extract: need " + Size(need) + ", have " + Size(Free(dest)));

                var destFull = Path.GetFullPath(dest).TrimEnd('\\') + "\\";
                long done = 0; var sw = Stopwatch.StartNew(); long lastLog = 0;
                foreach (var e in za.Entries)
                {
                    if (Cancelled) throw new OperationCanceledException();
                    var full = Path.GetFullPath(Path.Combine(dest, e.FullName.Replace('/', '\\')));
                    // zip-slip: an entry like ..\..\Windows\x must never leave the destination.
                    if (!full.StartsWith(destFull, StringComparison.OrdinalIgnoreCase))
                        return Fail("unsafe path in archive (zip-slip), refusing to extract: " + e.FullName);
                    if (e.FullName.EndsWith("/") || e.Name.Length == 0) { Directory.CreateDirectory(full); continue; }
                    Directory.CreateDirectory(Path.GetDirectoryName(full));
                    e.ExtractToFile(full, true);
                    done += e.Length;
                    if (sw.ElapsedMilliseconds - lastLog >= 5000)
                    {
                        lastLog = sw.ElapsedMilliseconds;
                        Log.Info("  extracted " + MB(done) + " / " + MB(total) + " MB");
                    }
                }
            }
            Log.Ok("extraction finished");
            return true;
        }

        static string Find7z()
        {
            var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            var pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
            foreach (var c in new[]
            {
                Path.Combine(pf, "7-Zip", "7z.exe"), Path.Combine(pf86, "7-Zip", "7z.exe"),
                Path.Combine(Cfg.CacheDir, "7zr.exe"), Path.Combine(Cfg.AppDir, "7zr.exe")
            }) if (File.Exists(c)) return c;
            return null;
        }

        static bool Extract7z(string archive, string dest)
        {
            var exe = Find7z();
            if (exe == null)
            {
                // The user already approved this in the download question.
                var target = Path.Combine(Cfg.CacheDir, "7zr.exe");
                Log.Warn("no 7-Zip found; downloading 7zr.exe (no published checksum to verify against)");
                if (!DownloadFile("https://www.7-zip.org/a/7zr.exe", target, -1, "", "7zr.exe")) return false;
                exe = target;
            }
            Log.Info("extracting with " + exe);
            string o;
            if (!Run(exe, "x \"" + archive + "\" -o\"" + dest + "\" -y", "7z extract", 60 * 60 * 1000, out o))
                return Fail("7-Zip extraction failed: " + Tail(o));
            return true;
        }

        static string Tail(string s) { s = (s ?? "").Trim(); return s.Length > 300 ? s.Substring(s.Length - 300) : s; }

        // Optional, off by default (it is a second download the user did not approve).
        static void OptionalAdb()
        {
            if (!Cfg.DownloadAdb || AdbPath != null) return;
            try
            {
                var zip = Path.Combine(Cfg.CacheDir, "platform-tools.zip");
                if (DownloadFile("https://dl.google.com/android/repository/platform-tools-latest-windows.zip",
                                 zip, -1, "", "platform-tools"))
                    ZipFile.ExtractToDirectory(zip, Cfg.CacheDir);
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex) { Log.Warn("optional adb download skipped: " + ex.Message); }
        }

        // --------------------------------------------------- 5. dependencies
        sealed class Dep
        {
            public string Name, Min, FileRegex;
            public Dep(string n, string m, string r) { Name = n; Min = m; FileRegex = r; }
        }

        // Explicit file patterns: the plain VCLibs pattern must NOT match the UWPDesktop package.
        static readonly Dep[] Deps =
        {
            new Dep("Microsoft.UI.Xaml.2.8", "8.2208.12001.0", @"^Microsoft\.UI\.Xaml\.2\.8.*x64.*\.appx$"),
            new Dep("Microsoft.VCLibs.140.00.UWPDesktop", "14.0.33728.0", @"^Microsoft\.VCLibs\.140\.00\.UWPDesktop.*x64.*\.appx$"),
            new Dep("Microsoft.VCLibs.140.00", "14.0.33519.0", @"^Microsoft\.VCLibs\.140\.00(?!\.UWPDesktop).*x64.*\.appx$")
        };

        static bool EnsureDependencies()
        {
            foreach (var d in Deps)
            {
                var have = InstalledVersion(d.Name);
                Log.Info(d.Name + ": installed=" + (have ?? "none") + "  minimum=" + d.Min);
                if (have != null && CompareVersions(have, d.Min) >= 0) { Log.Info("  satisfied"); continue; }

                var rx = new Regex(d.FileRegex, RegexOptions.IgnoreCase);
                var appx = Directory.GetFiles(Cfg.WsaRoot, "*.appx").FirstOrDefault(f => rx.IsMatch(Path.GetFileName(f)));
                if (appx == null) return Fail("the WSA payload has no .appx for " + d.Name);

                Log.Info("  installing " + appx);
                string o;
                if (!RunPs("Add-AppxPackage -Path " + PsQuote(appx), "add " + d.Name, 10 * 60 * 1000, out o))
                    return Fail("installing " + d.Name + " failed: " + Tail(o));

                var after = InstalledVersion(d.Name);
                Log.Info("  now installed: " + (after ?? "none"));
                if (after == null || CompareVersions(after, d.Min) < 0)
                    return Fail(d.Name + " is still below the required " + d.Min + " after install (found " + (after ?? "none") + ")");
            }
            return true;
        }

        static string InstalledVersion(string name)
        {
            string o;
            if (!RunPs("(Get-AppxPackage -AllUsers -Name " + PsQuote(name) +
                       " | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1).Version",
                       "query " + name, 90000, out o)) return null;
            var v = o.Trim();
            return v.Length == 0 ? null : v;
        }

        static int CompareVersions(string a, string b)
        {
            Version va, vb;
            if (Version.TryParse(a, out va) && Version.TryParse(b, out vb)) return va.CompareTo(vb);
            return string.Compare(a, b, StringComparison.OrdinalIgnoreCase);
        }

        // --------------------------------------------------- 6. registration
        sealed class PkgInfo { public string Status, Version, Location; }

        static PkgInfo GetWsaPackage()
        {
            string o;
            if (!RunPs("$p = Get-AppxPackage -Name " + PsQuote(PackageFamily) + " | Select-Object -First 1; " +
                       "if ($p) { $p.Status.ToString() + '|' + $p.Version + '|' + $p.InstallLocation }",
                       "get package", 90000, out o)) return null;
            var s = o.Trim();
            if (s.Length == 0) return null;
            var parts = s.Split('|');
            return new PkgInfo
            {
                Status = parts[0],
                Version = parts.Length > 1 ? parts[1] : "?",
                Location = parts.Length > 2 ? parts[2] : ""
            };
        }

        static bool SamePath(string a, string b)
        {
            try
            {
                return string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(b).TrimEnd('\\'),
                                     StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        static bool EnsureRegistered()
        {
            var pkg = GetWsaPackage();
            if (pkg != null)
            {
                Log.Info("registered: status=" + pkg.Status + " version=" + pkg.Version + " at " + pkg.Location);
                if (pkg.Status == "Ok" && SamePath(pkg.Location, Cfg.WsaRoot)) return true;
                Log.Warn("status is not Ok or it points at a different folder; re-registering from " + Cfg.WsaRoot);
            }
            else Log.Info("not registered yet");

            var manifest = Path.Combine(Cfg.WsaRoot, "AppxManifest.xml");
            string o;
            if (!RunPs("Add-AppxPackage -ForceApplicationShutdown -ForceUpdateFromAnyVersion -Register " + PsQuote(manifest),
                       "register", 10 * 60 * 1000, out o))
                return Fail("registering WSA failed: " + Tail(o));

            pkg = GetWsaPackage();
            if (pkg == null) return Fail("WSA is still not registered after Add-AppxPackage");
            Log.Info("registered: status=" + pkg.Status + " version=" + pkg.Version);
            return pkg.Status == "Ok" || Fail("WSA package status is '" + pkg.Status + "', expected 'Ok'");
        }

        // ----------------------------------------------- 7. userdata template
        // WSA copies <package root>\userdata.vhdx on first boot. Without it WsaClient aborts
        // with 0xc0000409 in ucrtbase.dll. A blank 8 GB dynamic VHDX is accepted; WSA
        // formats it and grows it itself. New-VHD needs the Hyper-V module (absent on
        // Windows Home), so diskpart is the fallback.
        static bool EnsureUserdataTemplate()
        {
            var tpl = Path.Combine(Cfg.WsaRoot, "userdata.vhdx");
            if (File.Exists(tpl))
            {
                Log.Info("template present: " + tpl + "  size=" + MB(new FileInfo(tpl).Length) + " MB (kept; WSA formats blank ones)");
                return true;
            }

            Log.Info("no template; creating a blank 8 GB dynamic VHDX");
            string o;
            bool made = RunPs("New-VHD -Path " + PsQuote(tpl) + " -SizeBytes 8GB -Dynamic | Out-Null",
                              "New-VHD", 5 * 60 * 1000, out o) && File.Exists(tpl);
            if (!made)
            {
                Log.Warn("New-VHD unavailable or failed (" + Tail(o) + "); trying diskpart");
                made = DiskpartCreate(tpl);
            }
            if (!made) return Fail("could not create " + tpl + " with New-VHD or diskpart");
            Log.Info("created " + tpl + " (" + MB(new FileInfo(tpl).Length) + " MB on disk)");
            return true;
        }

        static bool DiskpartCreate(string vhdx)
        {
            var script = Path.Combine(Path.GetTempPath(), "gp-diskpart-" + Guid.NewGuid().ToString("N") + ".txt");
            try
            {
                File.WriteAllText(script, "create vdisk file=\"" + vhdx + "\" maximum=8192 type=expandable\r\n");
                string o;
                Run("diskpart.exe", "/s \"" + script + "\"", "diskpart", 3 * 60 * 1000, out o);
                return File.Exists(vhdx);
            }
            finally { try { File.Delete(script); } catch { } }
        }

        // ------------------------------------------------------- 8. service
        static bool EnsureService()
        {
            using (var sc = new ServiceController("WsaService"))
            {
                try { var st = sc.Status; }
                catch (InvalidOperationException) { return Fail("WsaService does not exist - WSA registration did not complete"); }

                Log.Info("WsaService: " + sc.Status);
                if (sc.Status == ServiceControllerStatus.Running) return true;
                try
                {
                    if (sc.Status == ServiceControllerStatus.Stopped) sc.Start();
                    sc.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(90));
                }
                catch (System.ServiceProcess.TimeoutException) { return Fail("WsaService did not reach Running within 90 s"); }
                catch (InvalidOperationException ex) { return Fail("could not start WsaService: " + ex.Message); }
                sc.Refresh();
                Log.Info("WsaService: " + sc.Status);
                return sc.Status == ServiceControllerStatus.Running || Fail("WsaService is " + sc.Status);
            }
        }

        // ------------------------------------------------------- UIA helpers
        // Top-level windows owned by WsaClient: [name, class]. Every property read is guarded
        // because UIA elements vanish between enumeration and read.
        static List<string[]> WsaWindows()
        {
            var res = new List<string[]>();
            var procs = Process.GetProcessesByName("WsaClient");
            try
            {
                if (procs.Length == 0) return res;
                var root = AutomationElement.RootElement;
                foreach (var p in procs)
                {
                    AutomationElementCollection wins;
                    try { wins = root.FindAll(TreeScope.Children, new PropertyCondition(AutomationElement.ProcessIdProperty, p.Id)); }
                    catch { continue; }
                    foreach (AutomationElement w in wins)
                    {
                        try { res.Add(new[] { w.Current.Name ?? "", w.Current.ClassName ?? "" }); }
                        catch (ElementNotAvailableException) { }
                        catch (Exception) { }
                    }
                }
            }
            catch (Exception ex) { Log.Warn("  window probe: " + ex.Message); }
            finally { foreach (var p in procs) p.Dispose(); }
            return res;
        }

        // An Android app surface = a WsaClient window that is NOT the #32770 consent dialog.
        // (The WSA Settings app is a different process, so it can no longer false-positive.)
        static bool AndroidWindowPresent() { return WsaWindows().Any(w => w[1] != "#32770"); }

        static bool GameWindowPresent()
        {
            return WsaWindows().Any(w => w[1] != "#32770" &&
                w[0].IndexOf(Cfg.GameWindowTitle, StringComparison.OrdinalIgnoreCase) >= 0);
        }

        enum Click { NoDialog, Clicked, Failed }

        // First-run consent dialog: class #32770, button "Continue". Nothing boots until answered.
        static Click TryClickContinue()
        {
            var procs = Process.GetProcessesByName("WsaClient");
            try
            {
                if (procs.Length == 0) return Click.NoDialog;
                var root = AutomationElement.RootElement;
                var seen = false;
                foreach (var p in procs)
                {
                    AutomationElementCollection wins;
                    try { wins = root.FindAll(TreeScope.Children, new PropertyCondition(AutomationElement.ProcessIdProperty, p.Id)); }
                    catch { continue; }
                    foreach (AutomationElement w in wins)
                    {
                        try
                        {
                            if (w.Current.ClassName != "#32770") continue;
                            seen = true;
                            Log.Info("  found dialog '" + w.Current.Name + "' (pid " + p.Id + ")");
                            var btn = w.FindFirst(TreeScope.Descendants,
                                new PropertyCondition(AutomationElement.NameProperty, "Continue"));
                            object inv;
                            if (btn != null && btn.TryGetCurrentPattern(InvokePattern.Pattern, out inv))
                            {
                                ((InvokePattern)inv).Invoke();
                                Log.Ok("  clicked 'Continue' on the first-run consent dialog");
                                Wait(1500);
                                return Click.Clicked;
                            }
                        }
                        catch (ElementNotAvailableException) { }
                        catch (OperationCanceledException) { throw; }
                        catch (Exception ex) { Log.Warn("  consent click: " + ex.Message); }
                    }
                }
                return seen ? Click.Failed : Click.NoDialog;
            }
            finally { foreach (var p in procs) p.Dispose(); }
        }

        // ---------------------------------------------------------- 9. boot
        static LogWatcher Watcher()
        {
            if (_watcher == null)
                _watcher = new LogWatcher(_bootStartUtc == DateTime.MinValue
                    ? DateTime.UtcNow.AddMinutes(-30) : _bootStartUtc.AddSeconds(-5));
            return _watcher;
        }

        static bool BootWsa()
        {
            if (PortOpen(AdbPort)) { Log.Info("port " + AdbPort + " already open - WSA is running"); return true; }

            // If the VM is already alive its current log belongs to this session, so older log
            // data is legitimate; otherwise only data written after we start counts.
            var vmWasUp = CountProcs("vmmemWSA") > 0;
            _bootStartUtc = vmWasUp ? DateTime.UtcNow.AddMinutes(-30) : DateTime.UtcNow;
            _watcher = null;
            var watcher = Watcher();

            var lc = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                  "Packages", PackageName, "LocalCache");
            var ud = Path.Combine(lc, "userdata.2.vhdx");
            Log.Info("VM already running: " + vmWasUp + "; userdata.2.vhdx: " +
                     (File.Exists(ud) ? MB(new FileInfo(ud).Length) + " MB" : "absent (first boot)"));

            Log.Info("launching wsa://" + PlayStore + " (protocol activation is mandatory)");
            if (!Open("wsa://" + PlayStore)) return Fail("protocol activation of wsa:// failed (WSA not registered?)");

            var sw = Stopwatch.StartNew();
            long lastClick = -10000, lastCrash = 0, lastLog = 0;
            var noticed = false;
            var timeoutMs = Cfg.BootTimeoutMin * 60 * 1000;

            while (sw.ElapsedMilliseconds < timeoutMs)
            {
                Wait(PollMs);

                if (sw.ElapsedMilliseconds - lastClick > 10000)
                {
                    lastClick = sw.ElapsedMilliseconds;
                    var c = TryClickContinue();
                    if (c == Click.Failed && !noticed)
                    {
                        noticed = true;
                        Notice.Show("Good Pizza launcher - action needed",
                            "A Windows Subsystem for Android dialog is waiting.\r\nPlease click 'Continue'.");
                    }
                    else if (c == Click.Clicked) { Notice.Close(); }
                }

                watcher.Poll();
                var vm = CountProcs("vmmemWSA") > 0;

                if (sw.ElapsedMilliseconds - lastLog >= 30000)
                {
                    lastLog = sw.ElapsedMilliseconds;
                    Log.Info("  t+" + (sw.ElapsedMilliseconds / 1000) + "s  VM " + (vm ? "up" : "not yet") +
                             "  userdata=" + (File.Exists(ud) ? MB(new FileInfo(ud).Length) + " MB" : "absent"));
                }

                // Crash probe: throttled - each query spawns PowerShell.
                if (!vm && sw.ElapsedMilliseconds > 60000 && sw.ElapsedMilliseconds - lastCrash > 30000)
                {
                    lastCrash = sw.ElapsedMilliseconds;
                    var crash = LastWsaCrash();
                    if (crash != null) { Notice.Close(); return Fail("WsaClient crashed: " + crash); }
                }

                if (watcher.BootFinished) { Notice.Close(); Log.Ok("Android boot complete after " + (sw.ElapsedMilliseconds / 1000) + "s (logcat)"); return true; }
                if (PortOpen(AdbPort)) { Notice.Close(); Log.Ok("adb bridge open after " + (sw.ElapsedMilliseconds / 1000) + "s"); return true; }
                if (AndroidWindowPresent()) { Notice.Close(); Log.Ok("Android window visible after " + (sw.ElapsedMilliseconds / 1000) + "s"); return true; }
            }
            Notice.Close();
            return Fail("Android did not finish booting within " + Cfg.BootTimeoutMin + " minutes");
        }

        static string LastWsaCrash()
        {
            string o;
            if (!RunPs("Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000;StartTime=(Get-Date).AddMinutes(-5)} -ErrorAction SilentlyContinue | " +
                       "Where-Object { $_.Message -match 'WsaClient' } | Select-Object -First 1 | ForEach-Object { $_.Message }",
                       "crash query", 60000, out o)) return null;
            if (o.IndexOf("WsaClient", StringComparison.OrdinalIgnoreCase) < 0) return null;
            var m = Regex.Match(o, @"Faulting application path:\s*(.+)");
            var code = Regex.Match(o, @"Exception code:\s*(0x[0-9a-fA-F]+)");
            return (m.Success ? m.Groups[1].Value.Trim() : "WsaClient") + (code.Success ? "  " + code.Groups[1].Value : "");
        }

        // ------------------------------------------------------------ adb
        // Optional only. A virgin image has developer mode OFF, so nothing depends on this.
        static string AdbPath
        {
            get
            {
                var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                foreach (var c in new[]
                {
                    Path.Combine(Cfg.AppDir, "platform-tools", "adb.exe"),
                    Path.Combine(Cfg.AppDir, "payload", "platform-tools", "adb.exe"),
                    Path.Combine(Cfg.CacheDir, "platform-tools", "adb.exe"),
                    Path.Combine(home, "platform-tools", "adb.exe")
                }) if (File.Exists(c)) return c;
                return null;
            }
        }

        static string Serial { get { return "127.0.0.1:" + AdbPort; } }

        static bool AdbReady()
        {
            var adb = AdbPath;
            if (adb == null || !PortOpen(AdbPort)) { _adbConnected = false; return false; }
            if (_adbConnected) return true;
            string o;
            Run(adb, "connect " + Serial, "adb connect", 15000, out o);
            Log.Info("  adb connect: " + o.Trim());
            _adbConnected = o.IndexOf("connected", StringComparison.OrdinalIgnoreCase) >= 0;
            return _adbConnected;
        }

        static string Adb(string args, int timeoutMs)
        {
            if (!AdbReady()) return "";
            string o;
            Run(AdbPath, "-s " + Serial + " " + args, "adb " + args, timeoutMs, out o);
            return o.Trim();
        }

        // ----------------------------------------- 10. Play Store + game install
        // On an image that was never signed into Google the store process starts and then
        // dies ("Process com.android.vending has died"), so this is a wait-on-user step.
        // One shared timeout and one strategy: re-submit market:// only while no Android
        // window is visible; once the store is on screen, leave the user alone.
        static bool GameInstalled()
        {
            var outp = Adb("shell pm list packages " + GamePackage, 20000);
            if (outp.IndexOf(GamePackage, StringComparison.OrdinalIgnoreCase) >= 0) return true;
            var w = Watcher();
            w.Poll();
            return w.GameInstalled;
        }

        static bool EnsureStoreAndGame()
        {
            if (GameInstalled()) { Log.Ok("game already installed"); return true; }

            Log.Info("opening Play Store listing: market://details?id=" + GamePackage);
            Log.Info("Google sign-in is the user's step - we wait, we never enter credentials");
            Notice.Show("Good Pizza launcher - action needed",
                "Sign in to Google in the Play Store window, then tap Install.\r\n" +
                "The launcher is waiting and will start the game when it is installed.");
            try
            {
                var sw = Stopwatch.StartNew();
                long lastFire = -StoreRefireMs, lastLog = 0;
                int fired = 0;
                bool sawWindow = false;
                var timeoutMs = Cfg.InstallTimeoutMin * 60 * 1000;

                while (sw.ElapsedMilliseconds < timeoutMs)
                {
                    var win = AndroidWindowPresent();
                    if (win && !sawWindow) { sawWindow = true; Log.Ok("Play Store surface visible after " + (sw.ElapsedMilliseconds / 1000) + "s"); }

                    if (!win && sw.ElapsedMilliseconds - lastFire >= StoreRefireMs)
                    {
                        if (!Open("market://details?id=" + GamePackage))
                            return Fail("market:// activation failed; no protocol handler for the Play Store");
                        fired++;
                        lastFire = sw.ElapsedMilliseconds;
                        if (fired > 1) Log.Info("  re-submitted store listing (attempt " + fired + ") - sign-in not finished yet?");
                    }

                    Wait(3000);

                    if (GameInstalled())
                    {
                        Log.Ok("game installed after " + N(sw.Elapsed.TotalMinutes) + " minutes");
                        return true;
                    }
                    if (sw.ElapsedMilliseconds - lastLog >= 60000)
                    {
                        lastLog = sw.ElapsedMilliseconds;
                        Log.Info("  still waiting for sign-in / install (" + (sw.ElapsedMilliseconds / 60000) + " min)");
                    }
                }
                return Fail("the game was not installed within " + Cfg.InstallTimeoutMin +
                            " minutes (is a Google account signed in?)");
            }
            finally { Notice.Close(); }
        }

        // ------------------------------------------------------- 11. launch
        static bool LaunchGame()
        {
            // ASTC texture split: without it the app renders with broken graphics. Needs the
            // developer bridge, which a virgin image does not expose, so best-effort only.
            if (AdbReady())
            {
                var cur = Adb("shell getprop debug.require_split", 15000);
                if (cur.Length > 0) Log.Info("  debug.require_split already = " + cur);
                else Log.Info("  setprop -> " + Adb("shell setprop debug.require_split split_config.etc1_rgb8_group_hd.apk", 15000));
            }
            else Log.Info("ASTC texture split skipped (adb bridge not available)");

            Log.Info("launching wsa://" + GamePackage);
            if (!Open("wsa://" + GamePackage)) return Fail("launch failed: wsa:// activation error");
            Log.Info("launch submitted; waiting for the game window");

            var sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < LaunchConfirmMs)
            {
                Wait(2000);
                if (GameWindowPresent()) { Log.Ok("game window visible after " + (sw.ElapsedMilliseconds / 1000) + "s"); return true; }
            }
            // The launch was submitted; a title mismatch must not strand a working install.
            Log.Warn("could not confirm a window titled '*" + Cfg.GameWindowTitle + "*' within " +
                     (LaunchConfirmMs / 1000) + "s (set GameWindowTitle if the title differs)");
            return true;
        }

        // ------------------------------------------------------ fail window
        static void ShowFailureWindow(string check, string cause, string hint)
        {
            try
            {
                var form = new Form
                {
                    Text = "Good Pizza, Great Pizza - setup problem",
                    Size = new System.Drawing.Size(900, 600),
                    StartPosition = FormStartPosition.CenterScreen
                };
                var grid = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3 };
                grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
                grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));

                grid.Controls.Add(new Label
                {
                    AutoSize = true,
                    MaximumSize = new System.Drawing.Size(860, 0),
                    Padding = new Padding(10),
                    Font = new System.Drawing.Font("Segoe UI", 10),
                    Text = "A check failed: " + check + "\r\nCause: " + cause +
                           (string.IsNullOrEmpty(hint) ? "" : "\r\nSuggested fix: " + hint) +
                           "\r\nFull log: " + (Log.FilePath ?? "(not written)")
                }, 0, 0);

                var tb = new TextBox
                {
                    Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, WordWrap = false,
                    ScrollBars = ScrollBars.Both, Font = new System.Drawing.Font("Consolas", 9),
                    Text = string.Join(Environment.NewLine, Log.Snapshot())
                };
                grid.Controls.Add(tb, 0, 1);

                var bar = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft };
                var close = new Button { Text = "Close", AutoSize = true };
                close.Click += (s, e) => form.Close();
                var copy = new Button { Text = "Copy log", AutoSize = true };
                copy.Click += (s, e) => { try { Clipboard.SetText(tb.Text); } catch { } };
                var open = new Button { Text = "Open log", AutoSize = true, Enabled = Log.FilePath != null };
                open.Click += (s, e) => Open(Log.FilePath);
                bar.Controls.Add(close); bar.Controls.Add(copy); bar.Controls.Add(open);
                grid.Controls.Add(bar, 0, 2);

                form.Controls.Add(grid);
                form.Shown += (s, e) => { tb.SelectionStart = tb.TextLength; tb.ScrollToCaret(); };
                Application.Run(form);
            }
            catch { /* windowless is still better than crashing */ }
        }
    }
}