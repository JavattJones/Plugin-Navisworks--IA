# ClashAI — Navisworks Clash Detective Grouper

> Automatically group hundreds of Navisworks clashes by BIM parameter or AI — in seconds.

![Platform](https://img.shields.io/badge/platform-Navisworks%202020--2026-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Status](https://img.shields.io/badge/status-beta-orange)
![Language](https://img.shields.io/badge/built%20with-PowerShell%20%2B%20C%23-blueviolet)

---

## The Problem

Navisworks Clash Detective can generate **hundreds of conflicts** between disciplines in a single model. Grouping them manually by zone, level or discipline takes hours of repetitive work every coordination cycle.

**ClashAI automates that.**

---

## Two Versions

| | ClashAI Beta | ClashAI Completo |
|---|---|---|
| **Installer** | `Instalar_Plugin_ClashBeta.ps1` | `Instalar_ClashAI_Completo.ps1` |
| **Ribbon tab** | `[ClashAI Beta]` | `[CoordinaciónBIM]` |
| **Grouping mode** | BIM parameter (deterministic) | BIM parameter + AI via Ollama |
| **Requires Ollama** | No | Optional (fallback to deterministic) |
| **Status** | ✅ In use | 🧪 Active development |

### ClashAI Beta — deterministic, no dependencies

Groups clashes by the exact value of any BIM shared parameter (`Level`, `Zone`, `ADIF_00_Descripcion_Producto`, etc.). No internet, no LLM, no external dependencies. Fast and reproducible.

### ClashAI Completo — AI-assisted grouping via Ollama

Extends the Beta with an AI layer: sends clash data to a local LLM (via [Ollama](https://ollama.com)) and lets it propose intelligent groupings based on plain-language criteria. Falls back to deterministic grouping when a specific parameter name is detected in the criteria.

---

## Installation

No Visual Studio. No NuGet. No build step.

**ClashAI Beta (recommended for production use)**
```powershell
.\Instalar_Plugin_ClashBeta.ps1
```
Or download `Instalar_ClashAI_Beta.exe` from [Releases](../../releases) and run it directly.

**ClashAI Completo (AI mode)**
```powershell
.\Instalar_ClashAI_Completo.ps1
```

Supports **Navisworks Manage 2020 through 2026**. Detected automatically.

Both versions can coexist — they install to different plugin folders and use different ribbon tabs.

---

## How to Use

### ClashAI Beta
1. Open the **[ClashAI Beta]** tab in Navisworks
2. Select your Clash Test from the dropdown
3. Type the BIM parameter name (e.g. `Level`, `Zone`, `ADIF_00_Descripcion_Producto`)
4. Click **Agrupar clashes** — done

### ClashAI Completo
1. Open the **[CoordinaciónBIM]** tab
2. Enter the Ollama URL and click **Buscar** to load available models
3. Select your Clash Test from the dropdown
4. Write your grouping criteria in plain language — or type a specific BIM parameter name to skip the LLM entirely
5. Optionally set a parameter prefix to extract (e.g. `ADIF_00`)
6. Click **Analizar clashes** — use **Cancelar** to interrupt if needed
7. Progress is tracked per chunk in the log and progress bar

> If the criteria contains a parameter name that starts with the given prefix, grouping runs deterministically in C# without calling the LLM — instant and reproducible.
>
> Clashes are sent in chunks of 20 with short IDs (`c0, c1...`) to keep LLM context clean. Unclassified clashes land in a *Sin clasificar* group automatically.

---

## Known Limitation

`ClashResultGroup` has no public constructor in the Navisworks API — **empty groups must be created manually** in Clash Detective before running the plugin. The log tells you exactly how many are needed.

---

## Architecture

The installer is a PowerShell script that:
1. Detects your Navisworks version automatically
2. Compiles the C# plugin on the fly using `Add-Type`
3. Drops the DLL + ribbon XAML in your Navisworks plugins folder

No build pipeline. No dependencies beyond Navisworks itself.

```
Clash Detective results
        ↓
ClashExtractor (reads BIM properties per element)
        ↓
ClashGrouper (deterministic) ──or── OllamaClient (AI chunks of 20)
        ↓
GroupingApplicator → TestsData.TestsMove()
        ↓
Groups applied in Clash Detective
```

---

## Roadmap

- [ ] Claude API support (alternative to Ollama for cloud environments)
- [ ] Group by discipline inferred from source filename
- [ ] Persistent config panel (save model + Ollama URL)
- [ ] Export grouping results to Excel / BCF
- [ ] Navisworks 2027 compatibility

👉 [Vote on features or suggest new ones](../../discussions/2)

---

## Contributing

Ideas, bug reports and pull requests are welcome.
Read [CONTRIBUTING.md](CONTRIBUTING.md) to get started.

---

## License

MIT © Javier — developed in the context of BIM coordination at ACCIONA.

> ⚠️ Every output is a draft for coordinator review. This tool assists grouping decisions — it does not replace engineering judgment.
