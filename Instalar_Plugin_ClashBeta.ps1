# ============================================================
# Instala plugin "ClashAI Beta" en Navisworks
# Agrupacion de conflictos por parametro compartido
# Ejecutar UNA VEZ para instalar/actualizar el plugin
# Compatible con Navisworks Manage 2020-2026
# ============================================================

# Detectar version de Navisworks instalada (la mas reciente)
$NW_DIR = $null
$candidatos = @(2026,2025,2024,2023,2022,2021,2020) | ForEach-Object {
    "C:\Program Files\Autodesk\Navisworks Manage $_"
} | Where-Object { Test-Path "$_\Autodesk.Navisworks.Api.dll" }
if ($candidatos) { $NW_DIR = $candidatos | Select-Object -First 1 }

if (-not $NW_DIR) {
    Write-Host "ERROR: No se encontro Navisworks Manage instalado." -ForegroundColor Red
    Write-Host "Rutas buscadas en C:\Program Files\Autodesk\Navisworks Manage 20XX"
    Read-Host "Pulse Enter para salir"; exit 1
}
$NW_VERSION = Split-Path $NW_DIR -Leaf | Select-String "\d{4}" | ForEach-Object { $_.Matches[0].Value }
Write-Host "Navisworks detectado: $NW_DIR"

$PLUGIN_DIR = "$env:APPDATA\Autodesk\$( Split-Path $NW_DIR -Leaf )\Plugins\ClashGrouper.ACCIONA"
$PLUGIN_DLL = "$PLUGIN_DIR\ClashGrouper.ACCIONA.dll"

$resolving = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
[System.AppDomain]::CurrentDomain.add_AssemblyResolve({
    param($s, $e)
    $n = [System.Reflection.AssemblyName]::new($e.Name).Name
    if (-not $resolving.Add($n)) { return $null }
    try {
        $p = Join-Path $NW_DIR "$n.dll"
        if (Test-Path $p) { return [System.Reflection.Assembly]::LoadFrom($p) }
        return $null
    } finally { $resolving.Remove($n) | Out-Null }
})
[System.Reflection.Assembly]::LoadFrom("$NW_DIR\Autodesk.Navisworks.Api.dll")   | Out-Null
[System.Reflection.Assembly]::LoadFrom("$NW_DIR\Autodesk.Navisworks.Clash.dll") | Out-Null
Write-Host "[1/4] Ensamblados cargados"

# -------------------------------------------------------
# Codigo C# del plugin
# -------------------------------------------------------
$pluginCsharp = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Forms;
using Autodesk.Navisworks.Api;
using Autodesk.Navisworks.Api.Clash;
using Autodesk.Navisworks.Api.Plugins;

// ═══ MODELOS ══════════════════════════════════════════════════════════════════

class ClashData
{
    public ClashData() { Centroid = new double[3]; Element1 = new ElementInfo(); Element2 = new ElementInfo(); }
    public string   Id               { get; set; }
    public string   Name             { get; set; }
    public string   Status           { get; set; }
    public double   PenetrationDepth { get; set; }
    public double[] Centroid         { get; set; }
    public ElementInfo Element1      { get; set; }
    public ElementInfo Element2      { get; set; }
}

class ElementInfo
{
    public ElementInfo() { Params = new Dictionary<string,string>(); }
    public string SourceFile { get; set; }
    public string ObjectName { get; set; }
    public Dictionary<string,string> Params { get; set; }
}

class GroupingProposal
{
    public GroupingProposal() { Groups = new List<AiClashGroup>(); }
    public List<AiClashGroup> Groups { get; set; }
}

class AiClashGroup
{
    public AiClashGroup() { ClashIds = new List<string>(); }
    public string       GroupName  { get; set; }
    public string       Discipline { get; set; }
    public List<string> ClashIds   { get; set; }
}

// ═══ EXTRACTOR ════════════════════════════════════════════════════════════════

static class ClashExtractor
{
    public static List<ClashData> Extract(ClashTest test, List<string> paramNames)
    {
        var results = new List<ClashData>();
        foreach (SavedItem item in test.Children)
            if (item is ClashResult) results.Add(Build((ClashResult)item, paramNames));
        return results;
    }

    static ClashData Build(ClashResult clash, List<string> paramNames)
    {
        var cd = new ClashData();
        cd.Id               = clash.Guid.ToString();
        cd.Name             = clash.DisplayName;
        cd.Status           = clash.Status.ToString();
        cd.PenetrationDepth = clash.Distance;
        cd.Centroid         = new double[] { clash.Center.X, clash.Center.Y, clash.Center.Z };
        cd.Element1         = BuildElement(clash.CompositeItem1, paramNames);
        cd.Element2         = BuildElement(clash.CompositeItem2, paramNames);
        return cd;
    }

    static ElementInfo BuildElement(ModelItem item, List<string> paramNames)
    {
        if (item == null) return new ElementInfo();
        var info = new ElementInfo();
        info.ObjectName = item.DisplayName;
        info.SourceFile = RootName(item);
        foreach (PropertyCategory cat in item.PropertyCategories)
            foreach (DataProperty prop in cat.Properties)
            {
                string val;
                try { val = prop.Value.ToDisplayString(); } catch { continue; }
                if (string.IsNullOrEmpty(val)) continue;
                foreach (string pn in paramNames)
                    if (prop.DisplayName.StartsWith(pn, System.StringComparison.OrdinalIgnoreCase))
                        { info.Params[pn] = val; break; }
            }
        return info;
    }

    static string RootName(ModelItem item)
    {
        ModelItem cur = item;
        while (cur.Parent != null) cur = cur.Parent;
        return cur.DisplayName;
    }
}

// ═══ AGRUPADOR ════════════════════════════════════════════════════════════════

static class ClashGrouper
{
    public static GroupingProposal GroupByParams(List<ClashData> clashes, List<string> paramNames, Action<string> progress)
    {
        var proposal = new GroupingProposal();
        var byKey    = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);

        foreach (ClashData c in clashes)
        {
            var parts = new List<string>();
            foreach (string pn in paramNames)
            {
                string val = "";
                if (c.Element1.Params != null && c.Element1.Params.ContainsKey(pn))
                    val = c.Element1.Params[pn];
                else if (c.Element2.Params != null && c.Element2.Params.ContainsKey(pn))
                    val = c.Element2.Params[pn];
                parts.Add(string.IsNullOrEmpty(val) ? "Sin dato" : val);
            }
            string key = string.Join(" | ", parts.ToArray());
            if (!byKey.ContainsKey(key)) byKey[key] = new List<string>();
            byKey[key].Add(c.Id);
        }

        foreach (var kv in byKey)
        {
            var g = new AiClashGroup();
            g.GroupName  = kv.Key;
            g.Discipline = string.Join(" | ", paramNames.ToArray());
            g.ClashIds   = kv.Value;
            proposal.Groups.Add(g);
        }

        if (progress != null)
            progress(string.Format("Agrupamiento por '{0}': {1} grupos para {2} clashes",
                string.Join(" + ", paramNames.ToArray()), proposal.Groups.Count, clashes.Count));
        return proposal;
    }
}

// ═══ APLICADOR ════════════════════════════════════════════════════════════════

static class GroupingApplicator
{
    public static string Apply(Document doc, DocumentClash clashDoc, ClashTest test, GroupingProposal proposal)
    {
        var index = BuildIndex(test);
        int grouped = 0;
        var warnings = new List<string>();

        var emptyGroups = FindEmptyGroups(test);
        int needed = 0;
        foreach (AiClashGroup g in proposal.Groups)
            if (g.ClashIds != null && g.ClashIds.Count > 0) needed++;

        int neededTotal = needed + 1;
        if (emptyGroups.Count < needed)
            throw new InvalidOperationException(string.Format(
                "Necesitas {0} grupos vacios en Clash Detective pero solo hay {1}.\n\n" +
                "En Clash Detective haz clic en 'Nuevo grupo' {2} veces mas, guarda (Ctrl+Shift+S) y vuelve a aplicar.",
                neededTotal, emptyGroups.Count, neededTotal - emptyGroups.Count));

        int gi = 0;
        foreach (AiClashGroup group in proposal.Groups)
        {
            if (group.ClashIds == null || group.ClashIds.Count == 0) continue;
            var matched = new List<ClashResult>();
            foreach (string id in group.ClashIds)
                if (index.ContainsKey(id)) matched.Add(index[id]);

            if (matched.Count == 0) { warnings.Add("Grupo '" + group.GroupName + "': ningun ID encontrado."); continue; }

            var ng = emptyGroups[gi++];
            clashDoc.TestsData.TestsEditDisplayName(ng, group.GroupName);

            foreach (ClashResult cr in matched)
            {
                int crIdx = -1;
                for (int j = 0; j < test.Children.Count; j++)
                    if (test.Children[j] == cr) { crIdx = j; break; }
                if (crIdx < 0) continue;
                clashDoc.TestsData.TestsMove(test, crIdx, ng, ng.Children.Count);
                grouped++;
            }
        }

        var remaining = new List<ClashResult>();
        foreach (SavedItem si in test.Children)
            if (si is ClashResult) remaining.Add((ClashResult)si);

        if (remaining.Count > 0)
        {
            if (gi < emptyGroups.Count)
            {
                var fallback = emptyGroups[gi];
                clashDoc.TestsData.TestsEditDisplayName(fallback, "Sin clasificar (" + remaining.Count + " clashes)");
                foreach (ClashResult cr in remaining)
                {
                    int crIdx = -1;
                    for (int j = 0; j < test.Children.Count; j++)
                        if (test.Children[j] == cr) { crIdx = j; break; }
                    if (crIdx < 0) continue;
                    clashDoc.TestsData.TestsMove(test, crIdx, fallback, fallback.Children.Count);
                    grouped++;
                }
            }
            else
            {
                warnings.Add(remaining.Count + " clashes sin asignar. Crea 1 grupo vacio mas en Clash Detective para el grupo 'Sin clasificar'.");
            }
        }

        string summary = string.Format("Grupos aplicados: {0} | Clashes agrupados: {1}", needed, grouped);
        if (warnings.Count > 0) summary += "\nAvisos:\n  " + string.Join("\n  ", warnings.ToArray());
        return summary;
    }

    static List<ClashResultGroup> FindEmptyGroups(ClashTest test)
    {
        var result = new List<ClashResultGroup>();
        foreach (SavedItem si in test.Children)
        {
            if (!(si is ClashResultGroup)) continue;
            var g = (ClashResultGroup)si;
            bool hasResults = false;
            foreach (SavedItem c in g.Children) if (c is ClashResult) { hasResults = true; break; }
            if (!hasResults) result.Add(g);
        }
        return result;
    }

    static Dictionary<string, ClashResult> BuildIndex(ClashTest test)
    {
        var idx = new Dictionary<string, ClashResult>(StringComparer.OrdinalIgnoreCase);
        foreach (SavedItem item in test.Children)
            if (item is ClashResult) { ClashResult cr = (ClashResult)item; idx[cr.Guid.ToString()] = cr; }
        return idx;
    }
}

// ═══ DIALOGO ══════════════════════════════════════════════════════════════════

class ClashGrouperDialog : Form
{
    TextBox     txtParam;
    Label       lblNwStatus;
    ComboBox    cmbTest;
    List<ClashTest> _tests = new List<ClashTest>();
    RichTextBox rtbLog;
    ProgressBar pbProgress;
    Button      btnRun;
    Button      btnClose;

    readonly Document _doc;
    bool _running;

    public ClashGrouperDialog(Document doc)
    {
        _doc = doc;
        BuildUI();
        DetectState();
    }

    void BuildUI()
    {
        Text            = "ClashAI Beta - Agrupar por parametro";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox     = false;
        MinimizeBox     = false;
        StartPosition   = FormStartPosition.CenterScreen;
        Font            = new System.Drawing.Font("Segoe UI", 9f);
        int y = 14;

        SLbl("Parametros de agrupacion  (separa varios con  /)", y); y += 24;
        FLbl("Parametros:", y + 2);
        var txtParam_ = new TextBox { Location = new System.Drawing.Point(108, y), Width = 300 };
        txtParam = txtParam_; Controls.Add(txtParam); y += 26;

        Controls.Add(new Label
        {
            Location  = new System.Drawing.Point(108, y),
            Width     = 370,
            Text      = "Ej: ADIF_00_Descripcion_Producto  /  Tipo  /  Level",
            ForeColor = System.Drawing.Color.FromArgb(130, 130, 130),
            Font      = new System.Drawing.Font("Segoe UI", 8f)
        }); y += 24;

        SLbl("Estado", y); y += 24;
        FLbl("Navisworks:", y + 2);
        lblNwStatus = new Label { Location = new System.Drawing.Point(108, y), Width = 300, Text = "Comprobando...", ForeColor = System.Drawing.Color.Gray, AutoSize = false };
        Controls.Add(lblNwStatus); y += 22;

        FLbl("Clash Test:", y + 2);
        cmbTest = new ComboBox { Location = new System.Drawing.Point(108, y), Width = 300, DropDownStyle = ComboBoxStyle.DropDownList };
        Controls.Add(cmbTest); y += 32;

        SLbl("Actividad", y); y += 24;
        rtbLog = new RichTextBox
        {
            Location   = new System.Drawing.Point(14, y), Width = 472, Height = 150, ReadOnly = true,
            BackColor  = System.Drawing.Color.FromArgb(28, 28, 28), ForeColor = System.Drawing.Color.FromArgb(180, 230, 180),
            Font       = new System.Drawing.Font("Consolas", 8.5f), BorderStyle = BorderStyle.None,
            ScrollBars = RichTextBoxScrollBars.Vertical
        };
        Controls.Add(rtbLog); y += 156;

        pbProgress = new ProgressBar { Location = new System.Drawing.Point(14, y), Width = 472, Height = 5, Style = ProgressBarStyle.Marquee, MarqueeAnimationSpeed = 0 };
        Controls.Add(pbProgress); y += 22;

        btnRun = new Button
        {
            Location  = new System.Drawing.Point(14, y), Width = 170, Height = 32, Text = "Agrupar clashes",
            BackColor = System.Drawing.Color.FromArgb(0, 120, 215), ForeColor = System.Drawing.Color.White,
            FlatStyle = FlatStyle.Flat, Font = new System.Drawing.Font("Segoe UI", 9.5f, System.Drawing.FontStyle.Bold), Cursor = Cursors.Hand
        };
        btnRun.FlatAppearance.BorderSize = 0; btnRun.Click += OnRun; Controls.Add(btnRun);

        btnClose = new Button { Location = new System.Drawing.Point(412, y), Width = 74, Height = 32, Text = "Cerrar" };
        btnClose.Click += delegate { Close(); }; Controls.Add(btnClose);
        ClientSize = new System.Drawing.Size(500, y + 48);
    }

    void SLbl(string t, int y) { Controls.Add(new Label { Text = t, Location = new System.Drawing.Point(14, y), Width = 472, Font = new System.Drawing.Font("Segoe UI", 8.5f, System.Drawing.FontStyle.Bold), ForeColor = System.Drawing.Color.FromArgb(0, 84, 166) }); }
    void FLbl(string t, int y) { Controls.Add(new Label { Text = t, Location = new System.Drawing.Point(14, y), Width = 90, TextAlign = System.Drawing.ContentAlignment.MiddleRight, ForeColor = System.Drawing.Color.FromArgb(80, 80, 80) }); }

    void DetectState()
    {
        if (_doc == null) { SetSt(lblNwStatus, "Sin documento abierto", System.Drawing.Color.Crimson); btnRun.Enabled = false; return; }
        string file = string.IsNullOrEmpty(_doc.FileName) ? "sin guardar" : Path.GetFileName(_doc.FileName);
        SetSt(lblNwStatus, "OK: " + file, System.Drawing.Color.Green);
        try
        {
            _tests.Clear(); cmbTest.Items.Clear();
            var clashDoc = _doc.GetClash();
            if (clashDoc != null && clashDoc.TestsData != null && clashDoc.TestsData.Value != null && clashDoc.TestsData.Value.TestsRoot != null)
                foreach (SavedItem si in clashDoc.TestsData.Value.TestsRoot.Children)
                {
                    if (!(si is ClashTest)) continue;
                    ClashTest ct = (ClashTest)si;
                    int n = 0;
                    foreach (SavedItem c in ct.Children) if (c is ClashResult) n++;
                    if (n == 0) continue;
                    _tests.Add(ct);
                    cmbTest.Items.Add(string.Format("{0}  ({1} clashes)", ct.DisplayName, n));
                }
            if (_tests.Count > 0) { cmbTest.SelectedIndex = 0; }
            else { cmbTest.Items.Add("Sin tests con resultados — ejecute Clash Detective"); cmbTest.SelectedIndex = 0; btnRun.Enabled = false; }
        }
        catch (Exception ex) { cmbTest.Items.Clear(); cmbTest.Items.Add("Error: " + ex.Message); cmbTest.SelectedIndex = 0; btnRun.Enabled = false; }
    }

    static void SetSt(Label l, string t, System.Drawing.Color c) { l.Text = t; l.ForeColor = c; }

    void OnRun(object sender, EventArgs e)
    {
        if (_running) return;
        var paramNames = new List<string>();
        foreach (string p in txtParam.Text.Split('/'))
        { string t = p.Trim(); if (!string.IsNullOrEmpty(t)) paramNames.Add(t); }
        if (paramNames.Count == 0) { Log("Introduce al menos un nombre de parametro."); return; }

        DocumentClash clashDoc; ClashTest activeTest; List<ClashData> clashes;
        try
        {
            clashDoc = _doc.GetClash();
            int sel = cmbTest.SelectedIndex;
            if (sel < 0 || sel >= _tests.Count) throw new InvalidOperationException("Selecciona un Clash Test en el desplegable.");
            activeTest = _tests[sel];

            clashes = ClashExtractor.Extract(activeTest, paramNames);
            int withParams = 0;
            foreach (ClashData cd in clashes)
                if ((cd.Element1.Params != null && cd.Element1.Params.Count > 0) ||
                    (cd.Element2.Params != null && cd.Element2.Params.Count > 0)) withParams++;

            string paramsLabel = string.Join(" | ", paramNames.ToArray());
            Log(string.Format("Test: '{0}' - {1} clashes | parametros '{2}' en {3}/{1} elementos.",
                activeTest.DisplayName, clashes.Count, paramsLabel, withParams));

            if (withParams == 0)
                Log("AVISO: Ningun elemento tiene esos parametros. Verifica los nombres exactos en Propiedades de Navisworks (clic derecho sobre un elemento).");
        }
        catch (Exception ex) { Log("ERROR: " + ex.Message); return; }

        SetRunning(true);
        var capDoc = _doc; var capClash = clashDoc; var capTest = activeTest; var capParams = paramNames;
        Task.Run(delegate
        {
            GroupingProposal proposal;
            Action<string> progress = msg => Invoke((Action)delegate { Log(msg); });
            try { proposal = ClashGrouper.GroupByParams(clashes, capParams, progress); }
            catch (Exception ex) { Invoke((Action)delegate { Log("ERROR: " + ex.Message); SetRunning(false); }); return; }
            Invoke((Action)delegate
            {
                try
                {
                    Log(string.Format("{0} grupos generados:", proposal.Groups.Count));
                    foreach (AiClashGroup g in proposal.Groups)
                        Log(string.Format("  [{0}] - {1} clashes", g.GroupName, g.ClashIds.Count));
                    Log("Aplicando en Navisworks...");
                    Log(GroupingApplicator.Apply(capDoc, capClash, capTest, proposal));
                    Log("Completado. Guarda el NWF (Ctrl+Shift+S).");
                }
                catch (Exception ex) { Log("ERROR al aplicar: " + ex.Message); }
                finally { SetRunning(false); }
            });
        });
    }

    void SetRunning(bool r) { _running = r; btnRun.Enabled = !r; btnClose.Enabled = !r; pbProgress.MarqueeAnimationSpeed = r ? 30 : 0; }
    void Log(string msg) { rtbLog.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + msg + "\n"); rtbLog.ScrollToCaret(); }
}

// ═══ PLUGIN PRINCIPAL ═════════════════════════════════════════════════════════

[Plugin("ClashGrouper", "ACCIONA", DisplayName = "ClashAI Beta")]
[RibbonLayout("Ribbon_ClashGrouper.xaml")]
[RibbonTab("ID_Tab_ClashGrouper")]
[Command("ID_RunClashGrouper",
    DisplayName = "Agrupar clashes",
    ToolTip = "Agrupa los conflictos del Clash Detective por el valor de un parametro compartido")]
public class ClashGrouperPlugin : CommandHandlerPlugin
{
    public override CommandState CanExecuteCommand(string commandId)
    {
        return new CommandState(true);
    }

    public override int ExecuteCommand(string commandId, params string[] parameters)
    {
        if (commandId == "ID_RunClashGrouper")
        {
            var doc = Autodesk.Navisworks.Api.Application.ActiveDocument;
            using (ClashGrouperDialog dlg = new ClashGrouperDialog(doc))
                dlg.ShowDialog();
            return 0;
        }
        return 0;
    }
}
'@

# -------------------------------------------------------
# XAML del ribbon
# -------------------------------------------------------
$xaml = @'
<?xml version="1.0" encoding="utf-8"?>
<RibbonControl
    x:Uid="RibbonTab_ClashGrouper"
    xmlns="clr-namespace:Autodesk.Windows;assembly=AdWindows"
    xmlns:wpf="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:adwi="clr-namespace:Autodesk.Internal.Windows;assembly=AdWindows"
    xmlns:system="clr-namespace:System;assembly=mscorlib"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:local="clr-namespace:Autodesk.Navisworks.Gui.Roamer.AIRLook;assembly=navisworks.gui.roamer">

    <RibbonTab Id="ID_Tab_ClashGrouper" Title="ClashAI Beta" KeyTip="CB">
        <RibbonPanel x:Uid="RibbonPanel_ClashGrouper">
            <RibbonPanelSource x:Uid="RibbonPanelSource_ClashGrouper" Title="Agrupacion">
                <local:NWRibbonButton x:Uid="Button_RunClashGrouper"
                    Id="ID_RunClashGrouper"
                    Size="Large"
                    ShowText="True"
                    Orientation="Vertical"
                    Text="Agrupar&#x0a;clashes"
                    LargeImage="ICON_URI_PLACEHOLDER"
                    KeyTip="AG"/>
            </RibbonPanelSource>
        </RibbonPanel>
    </RibbonTab>
</RibbonControl>
'@

$nameFile = @'
$utf8

DisplayName=
ClashAI Beta

ID_Tab_ClashGrouper.DisplayName=
ClashAI Beta

ID_RunClashGrouper.DisplayName=
Agrupar clashes

ID_RunClashGrouper.ToolTip=
Agrupa los conflictos del Clash Detective por el valor de un parametro compartido
'@

# -------------------------------------------------------
# Crear estructura de carpetas y archivos
# -------------------------------------------------------
Write-Host "[2/4] Creando estructura del plugin..."
try {
    New-Item -ItemType Directory -Force "$PLUGIN_DIR\es-ES" | Out-Null
    New-Item -ItemType Directory -Force "$PLUGIN_DIR\en-US" | Out-Null

    # Generar icono 32x32 con los colores del logo (teal -> purple)
    Add-Type -AssemblyName System.Drawing
    $iconBmp = New-Object System.Drawing.Bitmap(32, 32, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $iconGr  = [System.Drawing.Graphics]::FromImage($iconBmp)
    $iconGr.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $iconGr.Clear([System.Drawing.Color]::Transparent)
    $cTeal   = [System.Drawing.Color]::FromArgb(0, 210, 195)
    $cPurple = [System.Drawing.Color]::FromArgb(118, 74, 230)
    # Loop izquierdo (dos circulos en teal)
    $penTeal = New-Object System.Drawing.Pen($cTeal, 2.5)
    $penTeal.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $penTeal.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $iconGr.DrawEllipse($penTeal, [float]1,  [float]3,  [float]8, [float]8)
    $iconGr.DrawEllipse($penTeal, [float]3,  [float]14, [float]8, [float]8)
    $iconGr.DrawLine(   $penTeal, [float]7,  [float]11, [float]7, [float]14)
    # Conector central (degradado teal -> purple)
    $gradConn = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        [System.Drawing.Point]::new(9, 12), [System.Drawing.Point]::new(14, 12), $cTeal, $cPurple)
    $penConn = New-Object System.Drawing.Pen($gradConn, 2.5)
    $iconGr.DrawLine($penConn, [float]9, [float]12, [float]14, [float]12)
    # Rombo derecho (degradado teal -> purple)
    $gradDiamond = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        [System.Drawing.Point]::new(14, 4), [System.Drawing.Point]::new(30, 20), $cTeal, $cPurple)
    $penDiamond = New-Object System.Drawing.Pen($gradDiamond, 2.5)
    $penDiamond.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $dpts = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new(22, 4),  [System.Drawing.PointF]::new(30, 12),
        [System.Drawing.PointF]::new(22, 20), [System.Drawing.PointF]::new(14, 12))
    $iconGr.DrawPolygon($penDiamond, $dpts)
    $penTeal.Dispose(); $penConn.Dispose(); $gradConn.Dispose()
    $penDiamond.Dispose(); $gradDiamond.Dispose(); $iconGr.Dispose()
    $iconBmp.Save("$PLUGIN_DIR\icon.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $iconBmp.Dispose()

    # URI del icono para el XAML (espacios codificados para WPF BitmapImage)
    $iconUri   = "file:///" + "$PLUGIN_DIR\icon.png".Replace('\', '/').Replace(' ', '%20')
    $xamlFinal = $xaml.Replace('ICON_URI_PLACEHOLDER', $iconUri)

    [System.IO.File]::WriteAllText("$PLUGIN_DIR\es-ES\Ribbon_ClashGrouper.xaml", $xamlFinal, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText("$PLUGIN_DIR\en-US\Ribbon_ClashGrouper.xaml", $xamlFinal, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText("$PLUGIN_DIR\es-ES\Ribbon_ClashGrouper.name", $nameFile,  [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText("$PLUGIN_DIR\en-US\Ribbon_ClashGrouper.name", $nameFile,  [System.Text.Encoding]::UTF8)
    Write-Host "      OK -> $PLUGIN_DIR"
} catch {
    Write-Host "ERROR creando carpetas: $_" -ForegroundColor Red
    Read-Host "Pulse Enter para salir"; exit 1
}

# -------------------------------------------------------
# Compilar DLL del plugin
# -------------------------------------------------------
Write-Host "[3/4] Compilando plugin DLL..."
$fxDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
$refs = @(
    "$NW_DIR\Autodesk.Navisworks.Api.dll",
    "$NW_DIR\Autodesk.Navisworks.Clash.dll",
    (Join-Path $fxDir "System.Windows.Forms.dll"),
    (Join-Path $fxDir "System.Drawing.dll"),
    (Join-Path $fxDir "System.Core.dll")
)
if (Test-Path $PLUGIN_DLL) { Remove-Item $PLUGIN_DLL -Force }
try {
    Add-Type -TypeDefinition $pluginCsharp -ReferencedAssemblies $refs -OutputAssembly $PLUGIN_DLL
    Write-Host "      OK -> $PLUGIN_DLL"
} catch {
    Write-Host "ERROR compilando:" -ForegroundColor Red
    $_.Exception.Message -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Read-Host "Pulse Enter para salir"; exit 1
}

Write-Host "[4/4] Instalacion completada"
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " CLASHAI BETA INSTALADO"                     -ForegroundColor Green
Write-Host "============================================"
Write-Host ""
Write-Host " Pasos:"
Write-Host " 1. Cierra y vuelve a abrir Navisworks"
Write-Host " 2. Abre el NWF federado con Clash Detective ejecutado"
Write-Host " 3. Pestana [ClashAI Beta] -> boton [Agrupar clashes]"
Write-Host " 4. Escribe uno o mas parametros separados por / (ej: Level / Zona)"
Write-Host " 5. Crea grupos vacios en Clash Detective antes de agrupar"
Write-Host ""
Read-Host "Pulse Enter para salir"
