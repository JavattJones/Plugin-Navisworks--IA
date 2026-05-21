# ============================================================
# Instala plugin "Coordinacion BIM" en Navisworks
# Incluye: ClashAI (Agrupar con IA con Ollama local)
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

$PLUGIN_DIR = "$env:APPDATA\Autodesk\$( Split-Path $NW_DIR -Leaf )\Plugins\ViewpointCreator.ACCIONA"
$PLUGIN_DLL = "$PLUGIN_DIR\ViewpointCreator.ACCIONA.dll"

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
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Autodesk.Navisworks.Api;
using Autodesk.Navisworks.Api.Clash;
using Autodesk.Navisworks.Api.Plugins;

// ═══ CLAASHAI: MODELOS ═══════════════════════════════════════════════════════

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
    public string Category   { get; set; }
    public string Level      { get; set; }
    public Dictionary<string,string> Params { get; set; }
}

class OllamaResponse
{
    public string Model    { get; set; }
    public string Response { get; set; }
    public bool   Done     { get; set; }
    public string Error    { get; set; }
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
    public string       Level      { get; set; }
    public string       Reasoning  { get; set; }
    public List<string> ClashIds   { get; set; }
}

// ═══ CLAASHAI: EXTRACTOR ═════════════════════════════════════════════════════

static class ClashExtractor
{
    public static List<ClashData> Extract(ClashTest test, string paramPrefix)
    {
        var results = new List<ClashData>();
        foreach (SavedItem item in test.Children)
            if (item is ClashResult) results.Add(Build((ClashResult)item, paramPrefix));
        return results;
    }

    static ClashData Build(ClashResult clash, string paramPrefix)
    {
        var cd = new ClashData();
        cd.Id               = clash.Guid.ToString();
        cd.Name             = clash.DisplayName;
        cd.Status           = clash.Status.ToString();
        cd.PenetrationDepth = clash.Distance;
        cd.Centroid         = new double[] { clash.Center.X, clash.Center.Y, clash.Center.Z };
        cd.Element1         = BuildElement(clash.CompositeItem1, paramPrefix);
        cd.Element2         = BuildElement(clash.CompositeItem2, paramPrefix);
        return cd;
    }

    static ElementInfo BuildElement(ModelItem item, string paramPrefix)
    {
        if (item == null) return new ElementInfo();
        var info = new ElementInfo();
        info.ObjectName = item.DisplayName;
        info.SourceFile = RootName(item);
        bool usePrefix = !string.IsNullOrEmpty(paramPrefix);
        foreach (PropertyCategory cat in item.PropertyCategories)
            foreach (DataProperty prop in cat.Properties)
            {
                string val;
                try { val = prop.Value.ToDisplayString(); } catch { continue; }
                if (string.IsNullOrEmpty(val)) continue;
                string pn = prop.DisplayName;
                string pnLow = pn.ToLowerInvariant();
                // Parámetros con prefijo personalizado (ej: ADIF_)
                if (usePrefix && pn.StartsWith(paramPrefix, System.StringComparison.OrdinalIgnoreCase))
                    info.Params[pn] = val;
                // Fallback: category y level por heurística
                if (string.IsNullOrEmpty(info.Category) && (pnLow.Contains("categor") || pnLow.Contains("type")))
                    info.Category = val;
                if (string.IsNullOrEmpty(info.Level) && (pnLow.Contains("level") || pnLow.Contains("planta") || pnLow.Contains("floor") || pnLow.Contains("nivel") || pnLow.Contains("storey")))
                    info.Level = val;
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

// ═══ CLAASHAI: OLLAMA CLIENT ══════════════════════════════════════════════════

static class OllamaClient
{
    const int MaxChunk = 20;
    static readonly HttpClient Http = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };

    public static async Task<List<string>> ListModelsAsync(string baseUrl)
    {
        string raw = await Http.GetStringAsync(baseUrl + "/api/tags");
        var jss = new JavaScriptSerializer();
        var result = new List<string>();
        object obj = jss.DeserializeObject(raw);
        if (obj is Dictionary<string, object>)
        {
            var d = (Dictionary<string, object>)obj;
            if (d.ContainsKey("models") && d["models"] is object[])
                foreach (object m in (object[])d["models"])
                    if (m is Dictionary<string, object>)
                    {
                        var md = (Dictionary<string, object>)m;
                        if (md.ContainsKey("name") && md["name"] != null)
                        {
                            string n = md["name"].ToString();
                            if (!string.IsNullOrEmpty(n)) result.Add(n);
                        }
                    }
        }
        return result;
    }

    // Agrupamiento determinista por valor de parámetro — sin LLM
    static GroupingProposal GroupByParam(List<ClashData> clashes, string paramName, Action<string> progress)
    {
        var proposal = new GroupingProposal();
        var byValue  = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);

        foreach (ClashData c in clashes)
        {
            string val = "";
            if (c.Element1.Params != null && c.Element1.Params.ContainsKey(paramName))
                val = c.Element1.Params[paramName];
            else if (c.Element2.Params != null && c.Element2.Params.ContainsKey(paramName))
                val = c.Element2.Params[paramName];
            if (string.IsNullOrEmpty(val)) val = "Sin clasificar";
            if (!byValue.ContainsKey(val)) byValue[val] = new List<string>();
            byValue[val].Add(c.Id);
        }

        foreach (var kv in byValue)
        {
            var g = new AiClashGroup();
            g.GroupName = kv.Key;
            g.Discipline = paramName;
            g.ClashIds   = kv.Value;
            proposal.Groups.Add(g);
        }

        if (progress != null)
            progress(string.Format("Agrupamiento por '{0}': {1} grupos para {2} clashes", paramName, proposal.Groups.Count, clashes.Count));
        return proposal;
    }

    public static GroupingProposal Propose(List<ClashData> clashes, string model, string baseUrl, string criteria, string specificParam, Action<string> progress)
    {
        // Si hay un parámetro específico, agrupar directamente sin LLM
        if (!string.IsNullOrEmpty(specificParam))
            return GroupByParam(clashes, specificParam, progress);

        var merged = new GroupingProposal();
        int total = (int)Math.Ceiling((double)clashes.Count / MaxChunk);
        for (int i = 0; i < clashes.Count; i += MaxChunk)
        {
            int chunk = i / MaxChunk + 1;
            int take = Math.Min(MaxChunk, clashes.Count - i);
            if (progress != null)
            {
                int sinNivel = 0, sinCat = 0;
                var bloque = clashes.GetRange(i, take);
                foreach (ClashData c in bloque)
                {
                    if (string.IsNullOrEmpty(c.Element1.Level) && string.IsNullOrEmpty(c.Element2.Level)) sinNivel++;
                    if (string.IsNullOrEmpty(c.Element1.Category) && string.IsNullOrEmpty(c.Element2.Category)) sinCat++;
                }
                progress(string.Format("Bloque {0}/{1}: {2} clashes | sin nivel: {3} | sin categoria: {4}", chunk, total, take, sinNivel, sinCat));
            }
            var part = CallAsync(clashes.GetRange(i, take), model, baseUrl, criteria).GetAwaiter().GetResult();
            merged.Groups.AddRange(part.Groups);
            if (progress != null)
            {
                progress(string.Format("  -> {0} grupos en bloque {1}", part.Groups.Count, chunk));
                if (part.Groups.Count == 0 && progress != null)
                    progress("     AVISO: 0 grupos. Los clashes de este bloque pueden tener propiedades IFC vacias.");
            }
        }
        return merged;
    }

    static async Task<GroupingProposal> CallAsync(List<ClashData> clashes, string model, string baseUrl, string criteria)
    {
        var jss = new JavaScriptSerializer();
        jss.MaxJsonLength = int.MaxValue;

        // IDs simples (c0, c1...) en lugar de GUIDs — el LLM los copia sin errores
        var idMap = new Dictionary<string, string>();
        var list = new List<Dictionary<string, object>>();
        for (int i = 0; i < clashes.Count; i++)
        {
            string sid = "c" + i;
            idMap[sid] = clashes[i].Id;
            var d = ToDict(clashes[i]);
            d["id"] = sid;
            list.Add(d);
        }
        string clashJson = jss.Serialize(list);

        string userCriteria = string.IsNullOrEmpty(criteria)
            ? "Group by discipline pair (Structure-HVAC, Structure-Plumbing, MEP-MEP, etc.)"
            : criteria;

        string prompt =
            "You are a BIM coordination expert. Group the following Navisworks clashes.\n\n" +
            "GROUPING CRITERIA (follow this instruction from the user):\n" +
            userCriteria + "\n\n" +
            "CLASHES:\n" + clashJson + "\n\n" +
            "RULES:\n" +
            "* Every clash must appear in exactly one group\n" +
            "* Use the exact id values (c0, c1, c2...) in the clashIds array\n" +
            "* groupName must be descriptive, in Spanish\n" +
            "* Return ONLY valid JSON\n\n" +
            "OUTPUT FORMAT: {\"groups\":[{\"groupName\":\"G01 - Descripcion\",\"discipline\":\"A-B\",\"clashIds\":[\"c0\",\"c1\"]}]}";

        var body = new Dictionary<string, object>();
        body["model"] = model; body["prompt"] = prompt; body["stream"] = false; body["format"] = "json";
        var opts = new Dictionary<string, object>(); opts["temperature"] = 0.1; body["options"] = opts;

        string json = jss.Serialize(body);
        var content = new StringContent(json, Encoding.UTF8, "application/json");
        var resp = await Http.PostAsync(baseUrl + "/api/generate", content);
        resp.EnsureSuccessStatusCode();
        string raw = await resp.Content.ReadAsStringAsync();

        var ollamaResp = jss.Deserialize<OllamaResponse>(raw);
        if (ollamaResp == null) throw new InvalidOperationException("Respuesta vacia de Ollama.");
        if (!string.IsNullOrEmpty(ollamaResp.Error)) throw new InvalidOperationException("Ollama: " + ollamaResp.Error);

        string responseText = (ollamaResp.Response ?? "").Trim();
        // Limpiar fences markdown si el modelo los incluye
        if (responseText.StartsWith("```"))
        {
            int nl = responseText.IndexOf('\n');
            int fence = responseText.LastIndexOf("```");
            if (nl >= 0 && fence > nl)
                responseText = responseText.Substring(nl + 1, fence - nl - 1).Trim();
        }

        var proposal = jss.Deserialize<GroupingProposal>(responseText);
        if (proposal == null) throw new InvalidOperationException("No se pudo parsear la propuesta.");

        // Remap IDs simples → GUIDs reales de Navisworks
        foreach (AiClashGroup group in proposal.Groups)
            for (int i = 0; i < group.ClashIds.Count; i++)
            {
                string sid = group.ClashIds[i];
                string realId;
                if (idMap.TryGetValue(sid, out realId))
                    group.ClashIds[i] = realId;
            }

        return proposal;
    }

    static Dictionary<string, object> ToDict(ClashData c)
    {
        var d = new Dictionary<string, object>();
        d["id"]               = c.Id     != null ? c.Id     : "";
        d["name"]             = c.Name   != null ? c.Name   : "";
        d["status"]           = c.Status != null ? c.Status : "";
        d["penetrationDepth"] = c.PenetrationDepth;
        d["centroid"]         = c.Centroid;
        d["element1"]         = ElemDict(c.Element1);
        d["element2"]         = ElemDict(c.Element2);
        return d;
    }

    static Dictionary<string, object> ElemDict(ElementInfo e)
    {
        var d = new Dictionary<string, object>();
        if (e == null) return d;
        d["sourceFile"] = e.SourceFile != null ? e.SourceFile : "";
        d["objectName"] = e.ObjectName != null ? e.ObjectName : "";
        d["category"]   = e.Category   != null ? e.Category   : "";
        d["level"]      = e.Level      != null ? e.Level      : "";
        if (e.Params != null && e.Params.Count > 0)
            d["params"] = e.Params;
        return d;
    }
}

// ═══ CLAASHAI: APPLICATOR ════════════════════════════════════════════════════

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

        // +1 por si hay clashes sin clasificar (el LLM no los asigna todos cuando el criterio es parcial)
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

        // Clashes no asignados por la IA (sin nivel, sin metadatos, etc.) → "Sin clasificar"
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
                warnings.Add(remaining.Count + " clashes sin asignar (la IA no pudo clasificarlos). Crea 1 grupo vacio mas en Clash Detective para el grupo 'Sin clasificar'.");
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

// ═══ CLAASHAI: DIALOGO ═══════════════════════════════════════════════════════

class ClashAIDialog : Form
{
    TextBox     txtUrl;
    TextBox     txtCriteria;
    TextBox     txtParam;
    ComboBox    cmbModel;
    Button      btnRefresh;
    Label       lblNwStatus;
    Label       lblTestInfo;
    RichTextBox rtbLog;
    ProgressBar pbProgress;
    Button      btnRun;
    Button      btnClose;

    readonly Document _doc;
    bool _running;

    public ClashAIDialog(Document doc)
    {
        _doc = doc;
        BuildUI();
        DetectState();
    }

    void BuildUI()
    {
        Text            = "ClashAI - Agrupacion inteligente de conflictos";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox     = false;
        MinimizeBox     = false;
        StartPosition   = FormStartPosition.CenterScreen;
        Font            = new System.Drawing.Font("Segoe UI", 9f);
        int y = 14;

        SLbl("Configuracion IA", y); y += 24;
        FLbl("URL Ollama:", y + 2);
        txtUrl = new TextBox { Location = new System.Drawing.Point(108, y), Width = 300, Text = "http://localhost:11434" };
        Controls.Add(txtUrl); y += 28;

        FLbl("Criterio:", y + 2);
        txtCriteria = new TextBox
        {
            Location  = new System.Drawing.Point(108, y),
            Width     = 300,
            Height    = 48,
            Multiline = true,
            ScrollBars = ScrollBars.Vertical,
            Text      = "Agrupa por nivel, proximidad espacial y tipo de elemento"
        };
        Controls.Add(txtCriteria); y += 56;

        FLbl("Parametro:", y + 2);
        txtParam = new TextBox { Location = new System.Drawing.Point(108, y), Width = 300 };
        Controls.Add(txtParam); y += 28;

        FLbl("Modelo IA:", y + 2);
        cmbModel = new ComboBox { Location = new System.Drawing.Point(108, y), Width = 228, DropDownStyle = ComboBoxStyle.DropDownList };
        cmbModel.Items.Add("llama3.2"); cmbModel.SelectedIndex = 0; Controls.Add(cmbModel);

        btnRefresh = new Button { Location = new System.Drawing.Point(340, y - 1), Width = 68, Height = 24, Text = "Buscar", Font = new System.Drawing.Font("Segoe UI", 8.5f) };
        btnRefresh.Click += OnRefresh; Controls.Add(btnRefresh); y += 34;

        SLbl("Estado", y); y += 24;
        FLbl("Navisworks:", y + 2);
        lblNwStatus = new Label { Location = new System.Drawing.Point(108, y), Width = 300, Text = "Comprobando...", ForeColor = System.Drawing.Color.Gray, AutoSize = false };
        Controls.Add(lblNwStatus); y += 22;

        FLbl("Test activo:", y + 2);
        lblTestInfo = new Label { Location = new System.Drawing.Point(108, y), Width = 300, Text = "-", ForeColor = System.Drawing.Color.Gray, AutoSize = false };
        Controls.Add(lblTestInfo); y += 32;

        SLbl("Actividad", y); y += 24;
        rtbLog = new RichTextBox
        {
            Location = new System.Drawing.Point(14, y), Width = 472, Height = 150, ReadOnly = true,
            BackColor = System.Drawing.Color.FromArgb(28, 28, 28), ForeColor = System.Drawing.Color.FromArgb(180, 230, 180),
            Font = new System.Drawing.Font("Consolas", 8.5f), BorderStyle = BorderStyle.None, ScrollBars = RichTextBoxScrollBars.Vertical
        };
        Controls.Add(rtbLog); y += 156;

        pbProgress = new ProgressBar { Location = new System.Drawing.Point(14, y), Width = 472, Height = 5, Style = ProgressBarStyle.Marquee, MarqueeAnimationSpeed = 0 };
        Controls.Add(pbProgress); y += 22;

        btnRun = new Button
        {
            Location = new System.Drawing.Point(14, y), Width = 170, Height = 32, Text = "Analizar clashes",
            BackColor = System.Drawing.Color.FromArgb(0, 120, 215), ForeColor = System.Drawing.Color.White,
            FlatStyle = FlatStyle.Flat, Font = new System.Drawing.Font("Segoe UI", 9.5f, System.Drawing.FontStyle.Bold), Cursor = Cursors.Hand
        };
        btnRun.FlatAppearance.BorderSize = 0; btnRun.Click += OnRun; Controls.Add(btnRun);

        var btnTest = new Button { Location = new System.Drawing.Point(192, y), Width = 130, Height = 32, Text = "Test agrupacion", FlatStyle = FlatStyle.Flat };
        btnTest.Click += OnTestGroup; Controls.Add(btnTest);

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
            var clashDoc = _doc.GetClash();
            ClashTest test = null;
            if (clashDoc != null && clashDoc.TestsData != null && clashDoc.TestsData.Value != null && clashDoc.TestsData.Value.TestsRoot != null)
                foreach (SavedItem si in clashDoc.TestsData.Value.TestsRoot.Children)
                    if (si is ClashTest) { ClashTest ct = (ClashTest)si; if (ct.Children.Count > 0) { test = ct; break; } }

            if (test != null)
            {
                int n = 0; foreach (SavedItem si in test.Children) if (si is ClashResult) n++;
                SetSt(lblTestInfo, string.Format("'{0}' - {1} clashes", test.DisplayName, n), System.Drawing.Color.DarkGreen);
            }
            else { SetSt(lblTestInfo, "Sin test con resultados. Ejecute Clash Detective.", System.Drawing.Color.OrangeRed); btnRun.Enabled = false; }
        }
        catch (Exception ex) { SetSt(lblTestInfo, "Error: " + ex.Message, System.Drawing.Color.Crimson); btnRun.Enabled = false; }
    }

    static void SetSt(Label l, string t, System.Drawing.Color c) { l.Text = t; l.ForeColor = c; }

    void OnRefresh(object sender, EventArgs e)
    {
        string url = txtUrl.Text.TrimEnd('/');
        btnRefresh.Enabled = false; btnRefresh.Text = "...";
        Task.Run(async delegate
        {
            try
            {
                var models = await OllamaClient.ListModelsAsync(url);
                Invoke((Action)delegate { cmbModel.Items.Clear(); foreach (string m in models) cmbModel.Items.Add(m); if (cmbModel.Items.Count > 0) cmbModel.SelectedIndex = 0; Log("Modelos: " + string.Join(", ", models.ToArray())); });
            }
            catch (Exception ex) { Invoke((Action)delegate { Log("Error Ollama: " + ex.Message); }); }
            finally { Invoke((Action)delegate { btnRefresh.Enabled = true; btnRefresh.Text = "Buscar"; }); }
        });
    }

    void OnRun(object sender, EventArgs e)
    {
        if (_running) return;
        string model       = cmbModel.SelectedItem != null ? cmbModel.SelectedItem.ToString() : "llama3.2";
        string url         = txtUrl.Text.TrimEnd('/');
        string paramPrefix = txtParam.Text.Trim();
        List<ClashData> clashes; DocumentClash clashDoc; ClashTest activeTest;
        try
        {
            clashDoc = _doc.GetClash(); activeTest = null;
            foreach (SavedItem si in clashDoc.TestsData.Value.TestsRoot.Children)
                if (si is ClashTest) { ClashTest ct = (ClashTest)si; if (ct.Children.Count > 0) { activeTest = ct; break; } }
            if (activeTest == null) throw new InvalidOperationException("No hay ningun test con resultados.");
            clashes = ClashExtractor.Extract(activeTest, paramPrefix);
            int withParams = 0;
            foreach (ClashData cd in clashes)
                if ((cd.Element1.Params != null && cd.Element1.Params.Count > 0) ||
                    (cd.Element2.Params != null && cd.Element2.Params.Count > 0)) withParams++;
            string paramInfo = string.IsNullOrEmpty(paramPrefix) ? "" :
                string.Format(" | parametros '{0}' encontrados en {1}/{2} clashes", paramPrefix, withParams, clashes.Count);
            Log(string.Format("Test: '{0}' - {1} clashes extraidos{2}.", activeTest.DisplayName, clashes.Count, paramInfo));
        }
        catch (Exception ex) { Log("ERROR: " + ex.Message); return; }

        SetRunning(true);
        string criteria = txtCriteria.Text.Trim();

        // Detectar si el criterio menciona un parametro especifico con el prefijo dado
        string specificParam = "";
        if (!string.IsNullOrEmpty(paramPrefix))
        {
            string[] words = criteria.Split(new char[]{' ',',',':','\n','\t'}, StringSplitOptions.RemoveEmptyEntries);
            foreach (string w in words)
                if (w.StartsWith(paramPrefix, StringComparison.OrdinalIgnoreCase) && w.Length > paramPrefix.Length)
                { specificParam = w; break; }
        }
        Log(string.Format("Enviando a {0}... (puede tardar 30-90 s)", model));
        var capDoc = _doc; var capClash = clashDoc; var capTest = activeTest;
        Task.Run(delegate
        {
            GroupingProposal proposal;
            Action<string> progress = msg => Invoke((Action)delegate { Log(msg); });
            try { proposal = OllamaClient.Propose(clashes, model, url, criteria, specificParam, progress); }
            catch (Exception ex) { Invoke((Action)delegate { Log("ERROR Ollama: " + ex.Message); SetRunning(false); }); return; }
            Invoke((Action)delegate
            {
                try
                {
                    Log(string.Format("IA propone {0} grupos:", proposal.Groups.Count));
                    foreach (AiClashGroup g in proposal.Groups) Log(string.Format("  [{0}] - {1} clashes", g.GroupName, g.ClashIds.Count));
                    Log("Aplicando en Navisworks...");
                    Log(GroupingApplicator.Apply(capDoc, capClash, capTest, proposal));
                    Log("Completado. Guarde el NWF (Ctrl+Shift+S).");
                }
                catch (Exception ex) { Log("ERROR al aplicar: " + ex.Message); }
                finally { SetRunning(false); }
            });
        });
    }

    void OnTestGroup(object sender, EventArgs e)
    {
        try
        {
            var clashDoc = _doc.GetClash();
            if (clashDoc == null) { Log("DocumentClash null."); return; }
            if (clashDoc.TestsData == null || clashDoc.TestsData.Value == null) { Log("TestsData null."); return; }
            var root = clashDoc.TestsData.Value.TestsRoot;
            if (root == null) { Log("TestsRoot null."); return; }

            Log(string.Format("TestsRoot tiene {0} elementos:", root.Children.Count));
            ClashTest test = null;
            foreach (SavedItem si in root.Children)
            {
                string tipo = si.GetType().Name;
                string hijos = si is ClashTest ? ((ClashTest)si).Children.Count.ToString() : "?";
                Log(string.Format("  [{0}] '{1}' hijos={2}", tipo, si.DisplayName, hijos));
                if (si is ClashTest) test = (ClashTest)si;
            }
            if (test == null) { Log("No hay ningun ClashTest."); return; }

            Log(string.Format("Usando test '{0}' con {1} hijos.", test.DisplayName, test.Children.Count));
            var clashes = new List<ClashResult>();
            foreach (SavedItem si in test.Children)
            {
                Log(string.Format("  hijo: [{0}] '{1}'", si.GetType().Name, si.DisplayName));
                if (si is ClashResult) { clashes.Add((ClashResult)si); if (clashes.Count >= 2) break; }
            }
            if (clashes.Count == 0) { Log("Sin ClashResult directos en el test."); return; }

            var fakeProposal = new GroupingProposal();
            var g = new AiClashGroup(); g.GroupName = "TEST_IA_grupo"; g.ClashIds = new List<string>();
            foreach (ClashResult cr in clashes) g.ClashIds.Add(cr.Guid.ToString());
            fakeProposal.Groups.Add(g);

            Log("Metodos Tests* en clashDoc.TestsData:");
            foreach (var m in clashDoc.TestsData.GetType().GetMethods(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance))
                if (m.Name.StartsWith("Tests"))
                {
                    var ps = m.GetParameters();
                    string sig = string.Join(", ", System.Array.ConvertAll(ps, p => p.ParameterType.Name + " " + p.Name));
                    Log("  " + m.Name + "(" + sig + ")");
                }

            var seed = (ClashResultGroup)test.Children[0];
            Log("Renombrando SEED a 'TEST_IA_grupo'...");
            clashDoc.TestsData.TestsEditDisplayName(seed, "TEST_IA_grupo");
            Log("Moviendo " + clashes.Count + " clashes a TEST_IA_grupo con TestsMove...");
            foreach (ClashResult cr in clashes)
            {
                int crIdx = -1;
                for (int j = 0; j < test.Children.Count; j++)
                    if (test.Children[j] == cr) { crIdx = j; break; }
                Log("  TestsMove clash '" + cr.DisplayName + "' en idx=" + crIdx);
                clashDoc.TestsData.TestsMove(test, crIdx, seed, seed.Children.Count);
            }
            Log("Hijos en grupo tras TestsMove: " + seed.Children.Count);
        }
        catch (Exception ex) { Log("ERROR test: " + ex.Message); }
    }

    void SetRunning(bool r) { _running = r; btnRun.Enabled = !r; btnClose.Enabled = !r; pbProgress.MarqueeAnimationSpeed = r ? 30 : 0; }
    void Log(string msg) { rtbLog.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + msg + "\n"); rtbLog.ScrollToCaret(); }
}

// ═══ VIEWPOINTCREATOR: PLUGIN PRINCIPAL ══════════════════════════════════════

[Plugin("ViewpointCreator", "ACCIONA", DisplayName = "Coordinacion BIM")]
[RibbonLayout("Ribbon_ViewpointCreator.xaml")]
[RibbonTab("ID_Tab_ViewpointCreator")]
[Command("ID_RunClashAI",
    DisplayName = "Agrupar con IA",
    ToolTip = "Agrupa los conflictos del Clash Detective usando IA local (Ollama)")]
public class ViewpointCreatorPlugin : CommandHandlerPlugin
{
    // ── Plugin entry points ───────────────────────────────────────────────────

    public override CommandState CanExecuteCommand(string commandId)
    {
        return new CommandState(true);
    }

    public override int ExecuteCommand(string commandId, params string[] parameters)
    {
        if (commandId == "ID_RunClashAI")
        {
            var doc = Autodesk.Navisworks.Api.Application.ActiveDocument;
            using (ClashAIDialog dlg = new ClashAIDialog(doc))
                dlg.ShowDialog();
            return 0;
        }

        return 0;
    }
}
'@

# -------------------------------------------------------
# XAML del ribbon - una pestana, dos paneles
# -------------------------------------------------------
$xaml = @'
<?xml version="1.0" encoding="utf-8"?>
<RibbonControl
    x:Uid="RibbonTab_ViewpointCreator"
    xmlns="clr-namespace:Autodesk.Windows;assembly=AdWindows"
    xmlns:wpf="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:adwi="clr-namespace:Autodesk.Internal.Windows;assembly=AdWindows"
    xmlns:system="clr-namespace:System;assembly=mscorlib"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:local="clr-namespace:Autodesk.Navisworks.Gui.Roamer.AIRLook;assembly=navisworks.gui.roamer">

    <RibbonTab Id="ID_Tab_ViewpointCreator" Title="Coordinacion BIM" KeyTip="CB">
        <RibbonPanel x:Uid="RibbonPanel_ClashAI">
            <RibbonPanelSource x:Uid="RibbonPanelSource_ClashAI" Title="Analisis IA">
                <local:NWRibbonButton x:Uid="Button_RunClashAI"
                    Id="ID_RunClashAI"
                    Size="Large"
                    ShowText="True"
                    Orientation="Vertical"
                    Text="Agrupar con IA"
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
Coordinacion BIM

ID_Tab_ViewpointCreator.DisplayName=
Coordinacion BIM

ID_RunClashAI.DisplayName=
Agrupar con IA

ID_RunClashAI.ToolTip=
Agrupa los conflictos del Clash Detective usando IA local (Ollama)
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

    [System.IO.File]::WriteAllText("$PLUGIN_DIR\es-ES\Ribbon_ViewpointCreator.xaml", $xamlFinal, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText("$PLUGIN_DIR\en-US\Ribbon_ViewpointCreator.xaml", $xamlFinal, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText("$PLUGIN_DIR\es-ES\Ribbon_ViewpointCreator.name", $nameFile,  [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText("$PLUGIN_DIR\en-US\Ribbon_ViewpointCreator.name", $nameFile,  [System.Text.Encoding]::UTF8)
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
    (Join-Path $fxDir "System.Net.Http.dll"),
    (Join-Path $fxDir "System.Web.Extensions.dll"),
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
Write-Host " PLUGIN INSTALADO"                           -ForegroundColor Green
Write-Host "============================================"
Write-Host ""
Write-Host " Pasos:"
Write-Host " 1. Cierra y vuelve a abrir Navisworks 2026"
Write-Host " 2. Abre cualquier NWF federado"
Write-Host " 3. Pestana [Coordinacion BIM] -> dos botones:"
Write-Host "    - [Crear Viewpoints]  (desde XML)"
Write-Host "    - [Agrupar con IA]    (Ollama en localhost:11434)"
Write-Host ""
Read-Host "Pulse Enter para salir"
