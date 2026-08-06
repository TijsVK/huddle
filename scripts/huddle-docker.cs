// Docker CLI shim for the Huddle engine host, as a real executable.
//
// Why not the .cmd: cmd.exe prints
//     'x' CMD.EXE was started with the above path as the current directory.
//     UNC paths are not supported.  Defaulting to Windows directory.
// on STDOUT, before the batch file runs, whenever its working directory is a UNC
// path (\\wsl.localhost\..., which is exactly what VS Code uses for WSL and
// attached-container windows). The VS Code Dev Containers extension parses
// `docker version --format {{json .}}` and `docker inspect` output as JSON, so
// those three lines break the attach with "docker returned an error / make sure
// the docker daemon is running". A batch file cannot suppress them - they are
// emitted by the interpreter itself. An .exe has no such preamble.
//
// Build (no project file needed):
//   %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /out:huddle-docker.exe huddle-docker.cs
using System;
using System.Diagnostics;
using System.Text;

static class HuddleDocker {
    static string Quote(string a) {
        // Windows command-line quoting: wrap when needed, escape embedded quotes
        // and the backslashes that precede them.
        if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return a;
        var sb = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in a) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { sb.Append('\\', slashes * 2 + 1).Append('"'); }
            else { sb.Append('\\', slashes).Append(c); }
            slashes = 0;
        }
        sb.Append('\\', slashes * 2).Append('"');
        return sb.ToString();
    }

    static int Main(string[] args) {
        string distro = Environment.GetEnvironmentVariable("HUDDLE_ENGINE_DISTRO");
        if (string.IsNullOrEmpty(distro)) distro = "huddle-engine";

        var sb = new StringBuilder();
        sb.Append("-d ").Append(Quote(distro));
        // --cd /: never translate the caller's Windows directory (fails as
        // "chdir(2) failed" for a non-root user, warns for UNC paths).
        // Absolute /usr/bin/docker: a Windows docker on the distro's PATH
        // (Rancher/Docker Desktop) must not be able to shadow the engine's CLI.
        sb.Append(" --cd / -- /usr/bin/docker");
        foreach (var a in args) sb.Append(' ').Append(Quote(a));

        var psi = new ProcessStartInfo {
            FileName = Environment.ExpandEnvironmentVariables(@"%WINDIR%\System32\wsl.exe"),
            Arguments = sb.ToString(),
            UseShellExecute = false,   // no shell, so no cmd.exe preamble
            CreateNoWindow = true,
            // Redirect and pump: when this .exe is started without a console (VS
            // Code spawns it that way) an un-redirected grandchild writes to a
            // console that does not exist and the output disappears.
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
        };
        try {
            using (var p = Process.Start(psi)) {
                var stdout = new System.Threading.Thread(() => Pump(p.StandardOutput.BaseStream, Console.OpenStandardOutput()));
                var stderr = new System.Threading.Thread(() => Pump(p.StandardError.BaseStream, Console.OpenStandardError()));
                stdout.IsBackground = stderr.IsBackground = true;
                stdout.Start(); stderr.Start();
                var stdin = new System.Threading.Thread(() => {
                    try { Pump(Console.OpenStandardInput(), p.StandardInput.BaseStream); } catch { }
                    try { p.StandardInput.Close(); } catch { }
                });
                stdin.IsBackground = true; stdin.Start();
                p.WaitForExit();
                stdout.Join(2000); stderr.Join(2000);
                return p.ExitCode;
            }
        } catch (Exception ex) {
            Console.Error.WriteLine("huddle-docker: " + ex.Message);
            return 127;
        }
    }

    static void Pump(System.IO.Stream from, System.IO.Stream to) {
        var buf = new byte[8192];
        int n;
        try {
            while ((n = from.Read(buf, 0, buf.Length)) > 0) { to.Write(buf, 0, n); to.Flush(); }
        } catch { }
    }
}
