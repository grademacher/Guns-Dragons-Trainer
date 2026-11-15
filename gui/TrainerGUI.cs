// Guns & Dragons Trainer window.
// Writes settings.ini (read live by the UE4SS mod) and shows status.ini (written by the mod).
// Build with build.ps1 (uses the C# 5 compiler that ships with .NET Framework 4, so no C# 6+ syntax here).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace GunsDragonsTrainer
{
    // key=value file that keeps unknown keys and their order.
    public class IniFile
    {
        public readonly string Path;
        private readonly List<string> order = new List<string>();
        private readonly Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public IniFile(string path) { Path = path; }

        public static Dictionary<string, string> Parse(string text)
        {
            var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (text == null) return d;
            foreach (var raw in text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line[0] == ';' || line[0] == '#') continue;
                int eq = line.IndexOf('=');
                if (eq <= 0) continue;
                d[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
            }
            return d;
        }

        public void Load()
        {
            order.Clear(); values.Clear();
            string text = null;
            for (int i = 0; i < 5 && text == null; i++)
            {
                // The mod replaces its files by delete + rename: a read can land on a file Windows is still
                // deleting, which throws UnauthorizedAccessException (not IOException).
                try { if (File.Exists(Path)) text = File.ReadAllText(Path); else return; }
                catch (IOException) { Thread.Sleep(20); }
                catch (UnauthorizedAccessException) { Thread.Sleep(20); }
            }
            foreach (var kv in Parse(text)) Set(kv.Key, kv.Value);
        }

        public string Get(string key, string def)
        {
            string v;
            return values.TryGetValue(key, out v) ? v : def;
        }

        public bool GetBool(string key, bool def)
        {
            var v = Get(key, null);
            if (v == null) return def;
            v = v.ToLowerInvariant();
            if (v == "1" || v == "true" || v == "on" || v == "yes") return true;
            if (v == "0" || v == "false" || v == "off" || v == "no") return false;
            return def;
        }

        public int GetInt(string key, int def, int min, int max)
        {
            double d;
            if (!double.TryParse(Get(key, ""), System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out d)) return def;
            return (int)Math.Max(min, Math.Min(max, Math.Round(d)));
        }

        public double GetDouble(string key, double def, double min, double max)
        {
            double d;
            if (!double.TryParse(Get(key, ""), System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out d)) return def;
            return Math.Max(min, Math.Min(max, d));
        }

        public void Set(string key, string value)
        {
            if (!values.ContainsKey(key)) order.Add(key);
            values[key] = value;
        }

        public void Save()
        {
            var sb = new StringBuilder();
            foreach (var k in order) sb.Append(k).Append('=').Append(values[k]).Append('\n');
            var tmp = Path + ".tmp";
            for (int i = 0; i < 10; i++)
            {
                try
                {
                    File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(false));
                    if (File.Exists(Path)) File.Replace(tmp, Path, null);
                    else File.Move(tmp, Path);
                    return;
                }
                catch (IOException) { Thread.Sleep(25); }
                catch (UnauthorizedAccessException) { Thread.Sleep(25); }
            }
        }
    }

    public class Theme
    {
        public static readonly Color Bg = Color.FromArgb(22, 24, 29);
        public static readonly Color Panel = Color.FromArgb(32, 35, 42);
        public static readonly Color Text = Color.FromArgb(230, 232, 236);
        public static readonly Color Muted = Color.FromArgb(140, 146, 158);
        public static readonly Color Accent = Color.FromArgb(232, 120, 48);
        public static readonly Color Good = Color.FromArgb(80, 200, 120);
        public static readonly Color Warn = Color.FromArgb(235, 190, 70);
        public static readonly Color Bad = Color.FromArgb(220, 80, 80);
    }

    // Flat on/off switch row.
    public class ToggleRow : Control
    {
        private bool on;
        public event EventHandler Changed;
        public string Label;

        public ToggleRow(string label)
        {
            Label = label;
            Height = 30;
            Cursor = Cursors.Hand;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
        }

        public bool Checked
        {
            get { return on; }
            set { if (on != value) { on = value; Invalidate(); } }
        }

        protected override void OnClick(EventArgs e)
        {
            Checked = !Checked;
            if (Changed != null) Changed(this, EventArgs.Empty);
            base.OnClick(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Parent != null ? Parent.BackColor : Theme.Bg);
            TextRenderer.DrawText(g, Label, Font, new Point(0, (Height - Font.Height) / 2), Theme.Text);
            int w = 40, h = 20, x = Width - w - 2, y = (Height - h) / 2;
            using (var b = new SolidBrush(on ? Theme.Accent : Color.FromArgb(70, 74, 84)))
            using (var path = Rounded(new Rectangle(x, y, w, h), h / 2))
                g.FillPath(b, path);
            int knob = h - 6;
            int kx = on ? x + w - knob - 3 : x + 3;
            using (var b = new SolidBrush(Color.White)) g.FillEllipse(b, kx, y + 3, knob, knob);
        }

        private static System.Drawing.Drawing2D.GraphicsPath Rounded(Rectangle r, int rad)
        {
            var p = new System.Drawing.Drawing2D.GraphicsPath();
            int d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
    }

    // Label + value + slider.
    public class SliderRow : Panel
    {
        public readonly TrackBar Bar;
        private readonly Label valueLabel;
        private readonly Func<int, string> format;
        public event EventHandler Changed;

        public SliderRow(string label, int min, int max, Func<int, string> format)
        {
            this.format = format;
            Height = 52;
            BackColor = Theme.Panel;
            var l = new Label { Text = label, ForeColor = Theme.Text, AutoSize = true, Location = new Point(0, 2), BackColor = Color.Transparent };
            valueLabel = new Label { ForeColor = Theme.Accent, AutoSize = false, TextAlign = ContentAlignment.TopRight, Height = 18, BackColor = Color.Transparent };
            Bar = new TrackBar { Minimum = min, Maximum = max, TickStyle = TickStyle.None, AutoSize = false, Height = 26, Location = new Point(-4, 22), BackColor = Theme.Panel };
            Bar.ValueChanged += delegate { valueLabel.Text = format(Bar.Value); if (Changed != null) Changed(this, EventArgs.Empty); };
            Controls.Add(l); Controls.Add(valueLabel); Controls.Add(Bar);
            Resize += delegate
            {
                valueLabel.Width = 120; valueLabel.Location = new Point(Width - 120, 2);
                Bar.Width = Width + 8;
            };
        }

        public int Value
        {
            get { return Bar.Value; }
            set { Bar.Value = Math.Max(Bar.Minimum, Math.Min(Bar.Maximum, value)); valueLabel.Text = format(Bar.Value); }
        }
    }

    public class TrainerForm : Form
    {
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);

        const string GameProcess = "EXGameSteam-Win64-Shipping";

        static readonly string[][] HoldKeys = {
            new[] { "RightMouseButton", "Right mouse" },
            new[] { "LeftMouseButton", "Left mouse" },
            new[] { "ThumbMouseButton", "Mouse back (thumb)" },
            new[] { "ThumbMouseButton2", "Mouse forward (thumb)" },
            new[] { "MiddleMouseButton", "Middle mouse" },
            new[] { "LeftShift", "Left Shift" },
            new[] { "LeftAlt", "Left Alt" },
            new[] { "CapsLock", "Caps Lock" },
            new[] { "Gamepad_LeftTrigger", "Gamepad left trigger" },
        };

        static readonly string[][] ToggleKeys = {
            new[] { "Insert", "45" }, new[] { "Home", "36" }, new[] { "End", "35" }, new[] { "Delete", "46" },
            new[] { "PageUp", "33" }, new[] { "PageDown", "34" }, new[] { "F1", "112" }, new[] { "F2", "113" },
            new[] { "F3", "114" }, new[] { "F4", "115" }, new[] { "F5", "116" }, new[] { "F6", "117" },
            new[] { "F7", "118" }, new[] { "F8", "119" }, new[] { "F9", "120" }, new[] { "F10", "121" },
            new[] { "F11", "122" }, new[] { "F12", "123" },
        };

        readonly IniFile settings;
        readonly string statusPath;
        readonly bool attach;
        bool loading;
        bool sawGame;
        int gameMissingTicks;
        bool keyWasDown;
        IntPtr gameWindow = IntPtr.Zero;

        // Unreal key names for the ping key (read by the mod in-game).
        static readonly string[][] MarkKeys = {
            new[] { "F8", "F8" }, new[] { "F5", "F5" }, new[] { "F6", "F6" }, new[] { "F7", "F7" }, new[] { "F9", "F9" },
            new[] { "F10", "F10" }, new[] { "F11", "F11" }, new[] { "F12", "F12" },
            new[] { "MiddleMouseButton", "Middle mouse" }, new[] { "ThumbMouseButton", "Mouse back (thumb)" },
            new[] { "ThumbMouseButton2", "Mouse forward (thumb)" },
        };

        const int ColW = 330;

        ToggleRow tHealth, tAmmo, tArmor, tAim, tLos, tWeak, tTop;
        ToggleRow tRevives, tLootDots, tMagnet, tSpread, tFire, tDash, tSupAim, tHighlight, tReload, tMove, tExplosive, tOverShield, tChests, tLead, tGuards, tWalls, tBurrow, tMinimap;
        SliderRow sFov, sSmooth, sDist, sOpacity, sMagnet, sFire, sReload, sMove;
        ComboBox cMode, cHoldKey, cToggleKey, cMarkKey;
        Label lConn, lRole, lTarget, lHint, lSupplies;
        Panel dot;
        System.Windows.Forms.Timer saveTimer, statusTimer, keyTimer;

        public TrainerForm(string dir, bool attach)
        {
            this.attach = attach;
            settings = new IniFile(Path.Combine(dir, "settings.ini"));
            statusPath = Path.Combine(dir, "status.ini");

            Text = "G&D Trainer";
            FormBorderStyle = FormBorderStyle.None;
            BackColor = Theme.Bg;
            ForeColor = Theme.Text;
            Font = new Font("Segoe UI", 9.5f);
            ClientSize = new Size(ColW * 2 + 15, 10);
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = true;
            KeyPreview = true;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            BuildUi();
            LoadSettings();

            saveTimer = new System.Windows.Forms.Timer { Interval = 150 };
            saveTimer.Tick += delegate { saveTimer.Stop(); SaveSettings(); };
            statusTimer = new System.Windows.Forms.Timer { Interval = 500 };
            statusTimer.Tick += delegate { PollStatus(); };
            statusTimer.Start();
            keyTimer = new System.Windows.Forms.Timer { Interval = 30 };
            keyTimer.Tick += delegate { PollToggleKey(); };
            keyTimer.Start();
            PollStatus();

            Move += delegate { if (!loading && WindowState == FormWindowState.Normal) ScheduleSave(); };
        }

        // ---------------- UI ----------------

        Panel Section(string title, Control[] rows, ref int y, int x)
        {
            var header = new Label
            {
                Text = title.ToUpperInvariant(), ForeColor = Theme.Muted, Font = new Font("Segoe UI", 8f, FontStyle.Bold),
                AutoSize = true, Location = new Point(x + 4, y), UseMnemonic = false
            };
            Controls.Add(header);
            y += 20;
            var p = new Panel { BackColor = Theme.Panel, Location = new Point(x, y), Width = ColW - 10 };
            int py = 8;
            foreach (var r in rows)
            {
                r.Location = new Point(12, py);
                r.Width = p.Width - 24;
                r.BackColor = Theme.Panel;
                p.Controls.Add(r);
                py += r.Height + 4;
            }
            p.Height = py + 4;
            Controls.Add(p);
            y += p.Height + 12;
            return p;
        }

        ComboBox Combo(IEnumerable<string> items)
        {
            var c = new ComboBox
            {
                DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat,
                BackColor = Theme.Bg, ForeColor = Theme.Text, Width = 170
            };
            foreach (var i in items) c.Items.Add(i);
            c.SelectedIndexChanged += delegate { ScheduleSave(); };
            return c;
        }

        Control LabeledCombo(string label, ComboBox c)
        {
            var p = new Panel { Height = 30 };
            var l = new Label { Text = label, ForeColor = Theme.Text, AutoSize = true, Location = new Point(0, 6) };
            p.Controls.Add(l); p.Controls.Add(c);
            p.Resize += delegate { c.Location = new Point(p.Width - c.Width, 3); };
            return p;
        }

        ToggleRow Toggle(string label)
        {
            var t = new ToggleRow(label) { Font = Font };
            t.Changed += delegate { ScheduleSave(); };
            return t;
        }

        static string Fmt(double v) { return v.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture); }
        static string Mult(int v) { return Fmt(v / 10.0) + "x"; }

        void BuildUi()
        {
            // Title bar (drag to move).
            var bar = new Panel { BackColor = Color.FromArgb(16, 17, 21), Location = new Point(0, 0), Size = new Size(ClientSize.Width, 38) };
            var title = new Label
            {
                Text = "GUNS & DRAGONS TRAINER", ForeColor = Theme.Accent, Font = new Font("Segoe UI", 10f, FontStyle.Bold),
                AutoSize = true, Location = new Point(12, 10), UseMnemonic = false
            };
            var close = new Label { Text = "\u2715", ForeColor = Theme.Muted, AutoSize = true, Location = new Point(ClientSize.Width - 28, 10), Cursor = Cursors.Hand };
            close.Click += delegate { Close(); };
            var hide = new Label { Text = "\u2013", ForeColor = Theme.Muted, AutoSize = true, Location = new Point(ClientSize.Width - 54, 9), Cursor = Cursors.Hand };
            hide.Click += delegate { HideWindow(); };
            MouseEventHandler drag = delegate(object s, MouseEventArgs e)
            {
                if (e.Button == MouseButtons.Left) { ReleaseCapture(); SendMessage(Handle, 0xA1, 0x2, 0); }
            };
            bar.MouseDown += drag; title.MouseDown += drag;
            bar.Controls.Add(title); bar.Controls.Add(close); bar.Controls.Add(hide);
            Controls.Add(bar);

            int y = 48;

            // Status block.
            dot = new Panel { Size = new Size(10, 10), Location = new Point(14, y + 5), BackColor = Theme.Bad };
            lConn = new Label { Text = "Waiting for game...", ForeColor = Theme.Text, AutoSize = true, Location = new Point(30, y) };
            Controls.Add(dot); Controls.Add(lConn);
            y += 22;
            lRole = new Label { ForeColor = Theme.Muted, AutoSize = false, Location = new Point(14, y), Size = new Size(ClientSize.Width - 28, 34) };
            Controls.Add(lRole);
            y += 38;

            int top = y, left = 10, right = ColW + 15;

            // ---- Left column
            tHealth = Toggle("Infinite health");
            tAmmo = Toggle("Infinite ammo");
            tArmor = Toggle("Infinite armor");
            tRevives = Toggle("Infinite self revives");
            tMagnet = Toggle("Loot magnet (also works when joined)");
            sMagnet = new SliderRow("Magnet radius", 5, 100, v => v + " m");
            sMagnet.Changed += delegate { ScheduleSave(); };
            tLootDots = Toggle("Show magnet items on minimap");
            Section("Cheats (host / solo)", new Control[] { tHealth, tAmmo, tArmor, tRevives, tMagnet, sMagnet, tLootDots }, ref y, left);

            tSpread = Toggle("No spread");
            tFire = Toggle("Fire rate multiplier");
            sFire = new SliderRow("Fire rate", 10, 100, v => (v / 10.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + "x");
            sFire.Changed += delegate { ScheduleSave(); };
            tReload = Toggle("Reload speed multiplier");
            sReload = new SliderRow("Reload speed", 10, 50, Mult);
            sReload.Changed += delegate { ScheduleSave(); };
            tMove = Toggle("Movement speed multiplier");
            sMove = new SliderRow("Movement speed", 10, 30, Mult);
            sMove.Changed += delegate { ScheduleSave(); };
            tDash = Toggle("No dash cooldown");
            Section("Weapon & movement (best as host)", new Control[] { tSpread, tFire, sFire, tReload, sReload, tMove, sMove, tDash }, ref y, left);

            cToggleKey = Combo(ToggleKeys.Select(k => k[0]));
            cToggleKey.Width = 110;
            tTop = Toggle("Always on top");
            tTop.Changed += delegate { TopMost = tTop.Checked; };
            sOpacity = new SliderRow("Opacity", 40, 100, v => v + "%");
            sOpacity.Changed += delegate { Opacity = sOpacity.Value / 100.0; ScheduleSave(); };
            Section("Window", new Control[] { LabeledCombo("Show / hide key", cToggleKey), tTop, sOpacity }, ref y, left);
            int leftBottom = y;

            // ---- Right column
            y = top;
            tAim = Toggle("Aim assist");
            sFov = new SliderRow("Radius around crosshair", 1, 90, v => v + "\u00B0");
            sFov.Changed += delegate { ScheduleSave(); };
            sSmooth = new SliderRow("Snap strength", 1, 100, v => v >= 100 ? "Instant snap" : v + "% per frame");
            sSmooth.Changed += delegate { ScheduleSave(); };
            sDist = new SliderRow("Max distance", 5, 500, v => v + " m");
            sDist.Changed += delegate { ScheduleSave(); };
            cMode = Combo(new[] { "While holding key", "Always" });
            cMode.Width = 150;
            cHoldKey = Combo(HoldKeys.Select(k => k[1]));
            cHoldKey.Width = 150;
            tWeak = Toggle("Prefer weak spot over head");
            tLos = Toggle("Only visible enemies");
            tExplosive = Toggle("Prefer explosive gear in clear view");
            tOverShield = Toggle("Aim over shields");
            tLead = Toggle("Lead moving targets / bullet drop");
            tGuards = Toggle("Shoot protectors first (imps, shamans, summoners)");
            tBurrow = Toggle("Ducking mushrooms: shoot their hat");
            lTarget = new Label { ForeColor = Theme.Muted, AutoSize = false, Height = 18, Text = "" };
            Section("Aim assist (works as host or client)", new Control[] {
                tAim, sFov, sSmooth, sDist, LabeledCombo("Mode", cMode), LabeledCombo("Hold key", cHoldKey), tWeak, tExplosive, tOverShield, tGuards, tBurrow, tLead, tLos, lTarget
            }, ref y, right);

            tSupAim = Toggle("Aim assist targets supplies");
            tHighlight = Toggle("Highlight supplies and pickups");
            tChests = Toggle("Highlight loot chests");
            tWalls = Toggle("Highlight secret walls");
            tMinimap = Toggle("Show highlights on minimap (experimental)");
            cMarkKey = Combo(MarkKeys.Select(k => k[1]));
            cMarkKey.Width = 150;
            lSupplies = new Label { ForeColor = Theme.Muted, AutoSize = false, Height = 52, Text = "" };
            Section("Supplies", new Control[] { tSupAim, tHighlight, tChests, tWalls, tMinimap, LabeledCombo("Ping key", cMarkKey), lSupplies }, ref y, right);
            y = Math.Max(y, leftBottom);

            lHint = new Label
            {
                Text = "Settings are saved automatically.",
                ForeColor = Theme.Muted, AutoSize = false, Location = new Point(14, y - 4), Size = new Size(ClientSize.Width - 28, 18),
                Font = new Font("Segoe UI", 8f)
            };
            Controls.Add(lHint);
            ClientSize = new Size(ClientSize.Width, y + 20);
        }

        // ---------------- Settings ----------------

        static int IndexOf(string[][] table, string id, int def)
        {
            for (int i = 0; i < table.Length; i++) if (string.Equals(table[i][0], id, StringComparison.OrdinalIgnoreCase)) return i;
            return def;
        }

        void LoadSettings()
        {
            loading = true;
            settings.Load();
            tHealth.Checked = settings.GetBool("infiniteHealth", false);
            tAmmo.Checked = settings.GetBool("infiniteAmmo", false);
            tArmor.Checked = settings.GetBool("infiniteArmor", false);
            tAim.Checked = settings.GetBool("aimAssist", false);
            sFov.Value = settings.GetInt("aimFov", 10, 1, 90);
            sSmooth.Value = settings.GetInt("aimSmoothing", 100, 1, 100);
            sDist.Value = settings.GetInt("aimMaxDistance", 100, 5, 500);
            cMode.SelectedIndex = settings.Get("aimMode", "hold").ToLowerInvariant() == "always" ? 1 : 0;
            cHoldKey.SelectedIndex = IndexOf(HoldKeys, settings.Get("aimHoldKey", "RightMouseButton"), 0);
            tLos.Checked = settings.GetBool("aimLineOfSight", true);
            tWeak.Checked = settings.GetBool("aimWeakSpot", true);
            tExplosive.Checked = settings.GetBool("aimExplosives", true);
            tOverShield.Checked = settings.GetBool("aimOverShields", true);
            tLead.Checked = settings.GetBool("aimLead", true);
            tGuards.Checked = settings.GetBool("aimGuardsFirst", true);
            tBurrow.Checked = settings.GetBool("aimSkipBurrowed", true);
            tWalls.Checked = settings.GetBool("highlightSecretWalls", false);
            tMinimap.Checked = settings.GetBool("minimapIcons", false);
            tReload.Checked = settings.GetBool("reloadSpeed", false);
            sReload.Value = (int)Math.Round(settings.GetDouble("reloadSpeedMultiplier", 2, 1, 5) * 10);
            tMove.Checked = settings.GetBool("moveSpeed", false);
            sMove.Value = (int)Math.Round(settings.GetDouble("moveSpeedMultiplier", 1.5, 1, 3) * 10);
            tChests.Checked = settings.GetBool("highlightChests", false);
            tMagnet.Checked = settings.GetBool("lootMagnet", false);
            tRevives.Checked = settings.GetBool("infiniteRevives", false);
            tLootDots.Checked = settings.GetBool("minimapLootDots", false);
            sMagnet.Value = settings.GetInt("lootMagnetRadius", 30, 5, 100);
            tSpread.Checked = settings.GetBool("noSpread", false);
            tFire.Checked = settings.GetBool("fireRate", false);
            sFire.Value = (int)Math.Round(settings.GetDouble("fireRateMultiplier", 2, 1, 10) * 10);
            tDash.Checked = settings.GetBool("noDashCooldown", false);
            tSupAim.Checked = settings.GetBool("aimSupplies", false);
            tHighlight.Checked = settings.GetBool("highlightSupplies", false);
            cMarkKey.SelectedIndex = IndexOf(MarkKeys, settings.Get("aimSupplyKey", "F8"), 0);
            cToggleKey.SelectedIndex = IndexOf(ToggleKeys, settings.Get("guiToggleKey", "Insert"), 0);
            tTop.Checked = settings.GetBool("guiTopMost", true);
            TopMost = tTop.Checked;
            sOpacity.Value = settings.GetInt("guiOpacity", 95, 40, 100);
            Opacity = sOpacity.Value / 100.0;

            var screen = Screen.PrimaryScreen.WorkingArea;
            int x = settings.GetInt("guiX", screen.Left + 40, -10000, 10000);
            int y = settings.GetInt("guiY", screen.Top + 80, -10000, 10000);
            var rect = new Rectangle(x, y, Width, Height);
            if (!Screen.AllScreens.Any(s => s.WorkingArea.IntersectsWith(new Rectangle(x, y, 60, 30))))
            {
                x = screen.Left + 40; y = screen.Top + 80;
            }
            Location = new Point(x, y);
            loading = false;
        }

        void ScheduleSave()
        {
            if (loading) return;
            saveTimer.Stop();
            saveTimer.Start();
        }

        void SaveSettings()
        {
            // Re-read first so keys the mod or a newer version added are preserved.
            settings.Load();
            Func<bool, string> b = v => v ? "1" : "0";
            settings.Set("infiniteHealth", b(tHealth.Checked));
            settings.Set("infiniteAmmo", b(tAmmo.Checked));
            settings.Set("infiniteArmor", b(tArmor.Checked));
            settings.Set("aimAssist", b(tAim.Checked));
            settings.Set("aimFov", sFov.Value.ToString());
            settings.Set("aimMode", cMode.SelectedIndex == 1 ? "always" : "hold");
            settings.Set("aimHoldKey", HoldKeys[Math.Max(0, cHoldKey.SelectedIndex)][0]);
            settings.Set("aimSmoothing", sSmooth.Value.ToString());
            settings.Set("aimMaxDistance", sDist.Value.ToString());
            settings.Set("aimLineOfSight", b(tLos.Checked));
            settings.Set("aimWeakSpot", b(tWeak.Checked));
            settings.Set("aimExplosives", b(tExplosive.Checked));
            settings.Set("aimOverShields", b(tOverShield.Checked));
            settings.Set("aimLead", b(tLead.Checked));
            settings.Set("aimGuardsFirst", b(tGuards.Checked));
            settings.Set("aimSkipBurrowed", b(tBurrow.Checked));
            settings.Set("highlightSecretWalls", b(tWalls.Checked));
            settings.Set("minimapIcons", b(tMinimap.Checked));
            settings.Set("reloadSpeed", b(tReload.Checked));
            settings.Set("reloadSpeedMultiplier", Fmt(sReload.Value / 10.0));
            settings.Set("moveSpeed", b(tMove.Checked));
            settings.Set("moveSpeedMultiplier", Fmt(sMove.Value / 10.0));
            settings.Set("highlightChests", b(tChests.Checked));
            settings.Set("lootMagnet", b(tMagnet.Checked));
            settings.Set("infiniteRevives", b(tRevives.Checked));
            settings.Set("minimapLootDots", b(tLootDots.Checked));
            settings.Set("lootMagnetRadius", sMagnet.Value.ToString());
            settings.Set("noSpread", b(tSpread.Checked));
            settings.Set("fireRate", b(tFire.Checked));
            settings.Set("fireRateMultiplier", (sFire.Value / 10.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture));
            settings.Set("noDashCooldown", b(tDash.Checked));
            settings.Set("aimSupplies", b(tSupAim.Checked));
            settings.Set("highlightSupplies", b(tHighlight.Checked));
            settings.Set("aimSupplyKey", MarkKeys[Math.Max(0, cMarkKey.SelectedIndex)][0]);
            settings.Set("guiToggleKey", ToggleKeys[Math.Max(0, cToggleKey.SelectedIndex)][0]);
            settings.Set("guiTopMost", b(tTop.Checked));
            settings.Set("guiOpacity", sOpacity.Value.ToString());
            settings.Set("guiX", Location.X.ToString());
            settings.Set("guiY", Location.Y.ToString());
            settings.Save();
        }

        // ---------------- Status from the mod ----------------

        void PollStatus()
        {
            Dictionary<string, string> st = null;
            // status.ini is rewritten 4x a second by delete + rename; a read that lands mid-swap throws
            // IOException or UnauthorizedAccessException ("access denied" on a file being deleted). Skip this tick.
            try { if (File.Exists(statusPath)) st = IniFile.Parse(File.ReadAllText(statusPath)); }
            catch (IOException) { return; }
            catch (UnauthorizedAccessException) { return; }

            long hb = 0;
            string hbs;
            bool live = st != null && st.TryGetValue("heartbeat", out hbs) && long.TryParse(hbs, out hb)
                && Math.Abs(DateTimeOffset.UtcNow.ToUnixTimeSeconds() - hb) <= 3;

            if (!live)
            {
                dot.BackColor = Theme.Bad;
                lConn.Text = Process.GetProcessesByName(GameProcess).Length > 0 ? "Game running, mod not responding" : "Waiting for game...";
                lRole.Text = "Toggles are saved and apply as soon as the game is running.";
                lTarget.Text = "";
            }
            else
            {
                string role = Val(st, "role"), notice = Val(st, "notice"), err = Val(st, "lastError");
                dot.BackColor = role == "client" ? Theme.Warn : (role == "menu" ? Theme.Muted : Theme.Good);
                string roleName = role == "solo" ? "Solo" : role == "host" ? "Hosting" : role == "client" ? "Joined (client)" : "Menu";
                lConn.Text = "Connected to game \u2014 " + roleName;
                lRole.Text = notice;
                lRole.ForeColor = role == "client" ? Theme.Warn : Theme.Muted;
                string target = Val(st, "aimTarget");
                lTarget.Text = target.Length > 0 ? "Target: " + target : (tAim.Checked ? "No target" : "");
                lHint.Text = err.Length > 0 ? "Last mod error: " + err : "Settings are saved automatically.";
                lHint.ForeColor = err.Length > 0 ? Theme.Warn : Theme.Muted;
            }

            // Ping: the mod logs what's under the crosshair to pings.txt; show the latest one.
            string key = MarkKeys[Math.Max(0, cMarkKey.SelectedIndex)][1];
            string last = live ? Val(st, "lastPing") : "";
            lSupplies.Text = last.Length > 0 ? "Last " + last
                : "Look at something in game and press " + key + " to log it to pings.txt for checking.";

            if (attach)
            {
                bool running = Process.GetProcessesByName(GameProcess).Length > 0;
                if (running) { sawGame = true; gameMissingTicks = 0; }
                else if (sawGame && ++gameMissingTicks >= 6) Close();
            }
        }

        static string Val(Dictionary<string, string> d, string k)
        {
            string v;
            return d.TryGetValue(k, out v) ? v : "";
        }

        // ---------------- Show / hide hotkey ----------------

        void PollToggleKey()
        {
            int vk = int.Parse(ToggleKeys[Math.Max(0, cToggleKey.SelectedIndex)][1]);
            bool down = (GetAsyncKeyState(vk) & 0x8000) != 0;
            if (down && !keyWasDown)
            {
                if (Visible && WindowState != FormWindowState.Minimized) HideWindow();
                else ShowWindow();
            }
            keyWasDown = down;
        }

        void HideWindow()
        {
            Hide();
            if (gameWindow != IntPtr.Zero) SetForegroundWindow(gameWindow);
        }

        void ShowWindow()
        {
            var fg = GetForegroundWindow();
            if (fg != Handle) gameWindow = fg;
            Show();
            WindowState = FormWindowState.Normal;
            TopMost = tTop.Checked;
            Activate();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            SaveSettings();
            base.OnFormClosing(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using (var p = new Pen(Color.FromArgb(60, 64, 74))) e.Graphics.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
        }
    }

    static class Program
    {
        static void LogError(Exception ex)
        {
            try
            {
                string path = Path.Combine(Path.GetDirectoryName(Application.ExecutablePath), "gui_errors.txt");
                File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + ex + Environment.NewLine + Environment.NewLine);
            }
            catch { }
        }

        [STAThread]
        static void Main(string[] args)
        {
            bool created;
            // --preview: separate instance for layout checks while the real window is open.
            string mutexName = args.Any(a => a == "--preview") ? "GunsDragonsTrainerGUI_Preview" : "GunsDragonsTrainerGUI_SingleInstance";
            using (var mutex = new Mutex(true, mutexName, out created))
            {
                if (!created) return;
                // Never show .NET's "unhandled exception" dialog over the game: log it next to the exe and carry on.
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                Application.ThreadException += (s, e) => LogError(e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (s, e) => LogError(e.ExceptionObject as Exception);
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                string dir = Path.GetDirectoryName(Application.ExecutablePath);
                bool attach = args.Any(a => a == "--attach");
                Application.Run(new TrainerForm(dir, attach));
            }
        }
    }
}
