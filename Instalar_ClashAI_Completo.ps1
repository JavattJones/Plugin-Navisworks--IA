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

class ClashSignature
{
    public ClashSignature() { ClashIds = new List<string>(); }
    public string       Key      { get; set; }
    public string       Elem1    { get; set; }
    public string       Elem2    { get; set; }
    public int          Count    { get; set; }
    public List<string> ClashIds { get; set; }
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
            g.GroupName  = kv.Key;
            g.Discipline = paramName;
            g.ClashIds   = kv.Value;
            proposal.Groups.Add(g);
        }

        if (progress != null)
            progress(string.Format("Agrupamiento por '{0}': {1} grupos para {2} clashes", paramName, proposal.Groups.Count, clashes.Count));
        return proposal;
    }

    // ── Fase 1: extraer firmas únicas (par de tipos de elementos) ────────────
    static List<ClashSignature> ExtractSignatures(List<ClashData> clashes)
    {
        var map = new Dictionary<string, ClashSignature>(StringComparer.OrdinalIgnoreCase);
        foreach (ClashData c in clashes)
        {
            string d1  = ElemDescriptor(c.Element1);
            string d2  = ElemDescriptor(c.Element2);
            // Clave canónica: orden alfabético para que A-vs-B == B-vs-A
            string key = string.Compare(d1, d2, StringComparison.OrdinalIgnoreCase) <= 0
                ? d1 + " vs " + d2
                : d2 + " vs " + d1;
            ClashSignature sig;
            if (!map.TryGetValue(key, out sig))
            {
                sig = new ClashSignature { Key = key, Elem1 = d1, Elem2 = d2 };
                map[key] = sig;
            }
            sig.Count++;
            sig.ClashIds.Add(c.Id);
        }
        return new List<ClashSignature>(map.Values);
    }

    static string ElemDescriptor(ElementInfo e)
    {
        if (e == null) return "Desconocido";
        // Parámetros personalizados tienen prioridad (ya filtrados por prefijo en Extract)
        if (e.Params != null)
            foreach (var kv in e.Params)
                if (!string.IsNullOrEmpty(kv.Value)) return kv.Value;
        var parts = new List<string>();
        if (!string.IsNullOrEmpty(e.Category)) parts.Add(e.Category);
        if (!string.IsNullOrEmpty(e.Level))    parts.Add(e.Level);
        if (parts.Count == 0 && !string.IsNullOrEmpty(e.SourceFile)) parts.Add(e.SourceFile);
        return parts.Count > 0 ? string.Join(" | ", parts.ToArray()) : "Desconocido";
    }

    // ── Llamada base a Ollama (reutilizable) ─────────────────────────────────
    static async Task<string> CallOllamaRawAsync(
        string prompt, string model, string baseUrl,
        double temperature, System.Threading.CancellationToken ct)
    {
        var jss = new JavaScriptSerializer();
        jss.MaxJsonLength = int.MaxValue;
        var body = new Dictionary<string, object>();
        body["model"]  = model;
        body["prompt"] = prompt;
        body["stream"] = false;
        body["format"] = "json";
        var opts = new Dictionary<string, object>();
        opts["temperature"] = temperature;
        body["options"] = opts;
        string json = jss.Serialize(body);
        var content = new StringContent(json, Encoding.UTF8, "application/json");
        var resp    = await Http.PostAsync(baseUrl + "/api/generate", content, ct);
        resp.EnsureSuccessStatusCode();
        string raw  = await resp.Content.ReadAsStringAsync();
        var ollamaResp = jss.Deserialize<OllamaResponse>(raw);
        if (ollamaResp == null) throw new InvalidOperationException("Respuesta vacia de Ollama.");
        if (!string.IsNullOrEmpty(ollamaResp.Error)) throw new InvalidOperationException("Ollama: " + ollamaResp.Error);
        string responseText = (ollamaResp.Response ?? "").Trim();
        if (responseText.StartsWith("```"))
        {
            int nl    = responseText.IndexOf('\n');
            int fence = responseText.LastIndexOf("```");
            if (nl >= 0 && fence > nl)
                responseText = responseText.Substring(nl + 1, fence - nl - 1).Trim();
        }
        return responseText;
    }

    // Extrae un mapa string→string desde un objeto JSON deserializado (solo valores escalares)
    static Dictionary<string, string> ExtractStringMap(object parsed)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!(parsed is Dictionary<string, object>)) return result;
        foreach (var kv in (Dictionary<string, object>)parsed)
            if (kv.Value != null && !(kv.Value is Dictionary<string, object>) && !(kv.Value is object[]))
                result[kv.Key] = kv.Value.ToString();
        return result;
    }

    // ── Fase 2a: Chain of Thought — razona y propone taxonomía inicial ────────
    // ── Fase 2b: Reflexión — el LLM critica y refina su propia propuesta ──────
    static async Task<Dictionary<string, string>> DefineTaxonomyAsync(
        List<ClashSignature> signatures, string model, string baseUrl,
        string criteria, Action<string> progress, System.Threading.CancellationToken ct)
    {
        var jss = new JavaScriptSerializer();
        jss.MaxJsonLength = int.MaxValue;

        var sigList = new List<Dictionary<string, object>>();
        foreach (ClashSignature s in signatures)
        {
            var d = new Dictionary<string, object>();
            d["key"]   = s.Key;
            d["elem1"] = s.Elem1;
            d["elem2"] = s.Elem2;
            d["count"] = s.Count;
            sigList.Add(d);
        }
        string sigJson = jss.Serialize(sigList);

        string userCriteria = string.IsNullOrEmpty(criteria)
            ? "Group by discipline pair and level (Structure-HVAC, Structure-Plumbing, MEP-MEP, etc.)"
            : criteria;

        // ── Pasada 1: Chain of Thought ────────────────────────────────────────
        if (progress != null) progress("Fase 2a: LLM genera taxonomia (Chain of Thought)...");
        string prompt1 =
            "You are a BIM coordination expert. Define grouping rules for Navisworks clash results.\n\n" +
            "GROUPING CRITERIA:\n" + userCriteria + "\n\n" +
            "ELEMENT TYPE PAIRS:\n" + sigJson + "\n\n" +
            "INSTRUCTIONS:\n" +
            "Step 1: Briefly analyze what grouping dimensions make sense for these element types (2-3 sentences).\n" +
            "Step 2: Define a group name for every key using those dimensions.\n" +
            "RULES:\n" +
            "* Every 'key' must appear in the taxonomy\n" +
            "* groupNames must be in Spanish\n" +
            "* You may assign multiple keys to the same groupName to consolidate\n" +
            "* Return ONLY valid JSON\n\n" +
            "OUTPUT FORMAT: {\"reasoning\":\"your analysis\",\"taxonomy\":{\"key1\":\"Nombre A\",\"key2\":\"Nombre B\"}}";

        string raw1    = await CallOllamaRawAsync(prompt1, model, baseUrl, 0.1, ct);
        object parsed1 = jss.DeserializeObject(raw1);

        string reasoning = "";
        Dictionary<string, string> taxonomy1;
        if (parsed1 is Dictionary<string, object>)
        {
            var d1 = (Dictionary<string, object>)parsed1;
            if (d1.ContainsKey("reasoning") && d1["reasoning"] != null)
                reasoning = d1["reasoning"].ToString();
            object taxObj = d1.ContainsKey("taxonomy") ? d1["taxonomy"] : parsed1;
            taxonomy1 = ExtractStringMap(taxObj);
        }
        else { taxonomy1 = ExtractStringMap(parsed1); }

        if (progress != null && !string.IsNullOrEmpty(reasoning))
            progress("  Razonamiento: " + reasoning);
        if (progress != null)
            progress(string.Format("  -> {0} reglas en propuesta inicial", taxonomy1.Count));

        // ── Pasada 2: Reflexión iterativa ─────────────────────────────────────
        if (progress != null) progress("Fase 2b: LLM revisa y refina la propuesta...");
        string prompt2 =
            "You are a BIM coordination expert reviewing a grouping proposal.\n\n" +
            "ORIGINAL ELEMENT PAIRS:\n" + sigJson + "\n\n" +
            "YOUR PREVIOUS GROUPING PROPOSAL:\n" + jss.Serialize(taxonomy1) + "\n\n" +
            "REVIEW CHECKLIST:\n" +
            "* Are any groups semantically identical but named differently? Merge them into one canonical Spanish name.\n" +
            "* Are there singleton groups (count=1 in original pairs) that logically belong to a larger group? Move them.\n" +
            "* Does every 'key' from the original pairs appear in your output?\n\n" +
            "Return the corrected taxonomy. If already correct, return it unchanged.\n" +
            "Return ONLY valid JSON: {\"key1\":\"Nombre A\",\"key2\":\"Nombre B\"}";

        string raw2    = await CallOllamaRawAsync(prompt2, model, baseUrl, 0.1, ct);
        object parsed2 = jss.DeserializeObject(raw2);

        Dictionary<string, string> taxonomy2;
        if (parsed2 is Dictionary<string, object>)
        {
            var d2 = (Dictionary<string, object>)parsed2;
            object taxObj2 = d2.ContainsKey("taxonomy") ? d2["taxonomy"] : parsed2;
            taxonomy2 = ExtractStringMap(taxObj2);
        }
        else { taxonomy2 = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); }

        // Contar fusiones realizadas
        var uniqueBefore = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string v in taxonomy1.Values) uniqueBefore.Add(v);
        var uniqueAfter = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string v in taxonomy2.Values) uniqueAfter.Add(v);
        int merged = uniqueBefore.Count - uniqueAfter.Count;

        // Fallback: si la segunda pasada devuelve muy pocas reglas, usar la primera
        if (taxonomy2.Count < taxonomy1.Count / 2)
        {
            if (progress != null) progress("  AVISO: revision incompleta. Usando propuesta inicial.");
            return taxonomy1;
        }

        // Rellenar claves que la segunda pasada pudiera haber omitido
        foreach (var kv in taxonomy1)
            if (!taxonomy2.ContainsKey(kv.Key)) taxonomy2[kv.Key] = kv.Value;

        if (progress != null)
        {
            string mergedInfo = merged > 0
                ? string.Format("{0} grupos fusionados", merged)
                : "sin fusiones";
            progress(string.Format("  -> {0} reglas finales ({1})", taxonomy2.Count, mergedInfo));
        }
        return taxonomy2;
    }

    // ── Fase 3: asignación determinista clash → grupo (C#, sin LLM) ─────────
    static GroupingProposal AssignByTaxonomy(
        List<ClashData> clashes, List<ClashSignature> signatures,
        Dictionary<string, string> taxonomy)
    {
        // Preconstruir mapa clashId → groupName a partir de las firmas
        var clashToGroup = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (ClashSignature sig in signatures)
        {
            string groupName;
            if (!taxonomy.TryGetValue(sig.Key, out groupName))
                groupName = "Sin clasificar";
            foreach (string id in sig.ClashIds)
                clashToGroup[id] = groupName;
        }

        var byGroup = new Dictionary<string, AiClashGroup>(StringComparer.OrdinalIgnoreCase);
        foreach (ClashData c in clashes)
        {
            string gn;
            if (!clashToGroup.TryGetValue(c.Id, out gn)) gn = "Sin clasificar";
            if (!byGroup.ContainsKey(gn))
                byGroup[gn] = new AiClashGroup { GroupName = gn };
            byGroup[gn].ClashIds.Add(c.Id);
        }

        var proposal = new GroupingProposal();
        foreach (var kv in byGroup) proposal.Groups.Add(kv.Value);
        return proposal;
    }

    // ── Entrada principal ─────────────────────────────────────────────────────
    public static GroupingProposal Propose(
        List<ClashData> clashes, string model, string baseUrl,
        string criteria, string specificParam,
        Action<string> progress, Action<int> onChunk,
        System.Threading.CancellationToken ct)
    {
        if (!string.IsNullOrEmpty(specificParam))
            return GroupByParam(clashes, specificParam, progress);

        // Fase 1: firmas únicas (C#, sin LLM, milisegundos)
        if (progress != null)
            progress(string.Format("Fase 1: extrayendo firmas de {0} clashes...", clashes.Count));
        var signatures = ExtractSignatures(clashes);
        if (progress != null)
            progress(string.Format("  -> {0} combinaciones unicas de tipos de elementos", signatures.Count));
        if (onChunk != null) onChunk(1);

        // Fase 2: CoT + reflexion iterativa (2 llamadas LLM)
        ct.ThrowIfCancellationRequested();
        var taxonomy = DefineTaxonomyAsync(signatures, model, baseUrl, criteria, progress, ct).GetAwaiter().GetResult();
        if (onChunk != null) onChunk(2);

        // Fase 3: asignacion en C# puro — sin mas LLM
        if (progress != null) progress("Fase 3: asignando clashes por firma...");
        var proposal = AssignByTaxonomy(clashes, signatures, taxonomy);
        if (progress != null)
            progress(string.Format("  -> {0} grupos, {1} clashes asignados", proposal.Groups.Count, clashes.Count));
        if (onChunk != null) onChunk(3);

        return proposal;
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
    ComboBox    cmbTest;
    List<ClashTest> _tests = new List<ClashTest>();
    RichTextBox rtbLog;
    ProgressBar pbProgress;
    Button      btnRun;
    Button      btnCancel;
    Button      btnClose;

    readonly Document _doc;
    bool _running;
    System.Threading.CancellationTokenSource _cts;

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

        FLbl("Clash Test:", y + 2);
        cmbTest = new ComboBox { Location = new System.Drawing.Point(108, y), Width = 300, DropDownStyle = ComboBoxStyle.DropDownList };
        Controls.Add(cmbTest); y += 32;

        SLbl("Actividad", y); y += 24;
        rtbLog = new RichTextBox
        {
            Location = new System.Drawing.Point(14, y), Width = 472, Height = 150, ReadOnly = true,
            BackColor = System.Drawing.Color.FromArgb(28, 28, 28), ForeColor = System.Drawing.Color.FromArgb(180, 230, 180),
            Font = new System.Drawing.Font("Consolas", 8.5f), BorderStyle = BorderStyle.None, ScrollBars = RichTextBoxScrollBars.Vertical
        };
        Controls.Add(rtbLog); y += 156;

        pbProgress = new ProgressBar { Location = new System.Drawing.Point(14, y), Width = 472, Height = 8, Style = ProgressBarStyle.Blocks, Minimum = 0, Maximum = 100, Value = 0 };
        Controls.Add(pbProgress); y += 22;

        btnRun = new Button
        {
            Location = new System.Drawing.Point(14, y), Width = 145, Height = 32, Text = "Analizar clashes",
            BackColor = System.Drawing.Color.FromArgb(0, 120, 215), ForeColor = System.Drawing.Color.White,
            FlatStyle = FlatStyle.Flat, Font = new System.Drawing.Font("Segoe UI", 9.5f, System.Drawing.FontStyle.Bold), Cursor = Cursors.Hand
        };
        btnRun.FlatAppearance.BorderSize = 0; btnRun.Click += OnRun; Controls.Add(btnRun);

        var btnTest = new Button { Location = new System.Drawing.Point(164, y), Width = 108, Height = 32, Text = "Test agrupacion", FlatStyle = FlatStyle.Flat };
        btnTest.Click += OnTestGroup; Controls.Add(btnTest);

        btnCancel = new Button { Location = new System.Drawing.Point(276, y), Width = 110, Height = 32, Text = "Cancelar", FlatStyle = FlatStyle.Flat, Enabled = false };
        btnCancel.Click += OnCancel; Controls.Add(btnCancel);

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
            clashDoc = _doc.GetClash();
            int sel = cmbTest.SelectedIndex;
            if (sel < 0 || sel >= _tests.Count) throw new InvalidOperationException("Selecciona un Clash Test en el desplegable.");
            activeTest = _tests[sel];
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
        Log(string.Format("Iniciando analisis con {0}...", model));
        int totalChunks = string.IsNullOrEmpty(specificParam) ? 3 : 1;
        pbProgress.Maximum = totalChunks; pbProgress.Value = 0;
        _cts = new System.Threading.CancellationTokenSource();
        System.Threading.CancellationToken token = _cts.Token;
        var capDoc = _doc; var capClash = clashDoc; var capTest = activeTest;
        Task.Run(delegate
        {
            GroupingProposal proposal;
            Action<string> progress = msg => Invoke((Action)delegate { Log(msg); });
            Action<int> onChunk = n => Invoke((Action)delegate { if (pbProgress.Value < pbProgress.Maximum) pbProgress.Value = n; });
            try { proposal = OllamaClient.Propose(clashes, model, url, criteria, specificParam, progress, onChunk, token); }
            catch (System.OperationCanceledException) { Invoke((Action)delegate { Log("Operacion cancelada por el usuario."); SetRunning(false); }); return; }
            catch (Exception ex) { Invoke((Action)delegate { Log("ERROR Ollama: " + ex.Message); SetRunning(false); }); return; }
            Invoke((Action)delegate
            {
                try
                {
                    pbProgress.Value = pbProgress.Maximum;
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

    void SetRunning(bool r) { _running = r; btnRun.Enabled = !r; btnClose.Enabled = !r; btnCancel.Enabled = r; if (!r) { pbProgress.Value = 0; } }
    void OnCancel(object s, EventArgs e)
    {
        if (_cts != null) _cts.Cancel();
        btnCancel.Enabled = false;
        Log("Cancelando...");
    }
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
