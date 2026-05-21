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

## What It Does

ClashAI adds a tab to your Navisworks ribbon with two grouping modes:

| Mode | How it works | Requires |
|------|-------------|----------|
| **BIM Parameter** | Groups clashes by any shared parameter (e.g. `Level`, `Zone`, `Area`) | Nothing extra |
| **AI via Ollama** | Sends clashes to a local LLM and lets it propose intelligent groupings | [Ollama](https://ollama.com) installed locally |

Both modes write the groups directly back into Clash Detective — no copy-paste, no manual work.

---

## Installation

No Visual Studio. No NuGet. No build step.

**Option A — Double click (recommended)**
1. Download `Instalar_ClashAI_Beta.exe` from [Releases](../../releases)
2. Run it as administrator
3. Restart Navisworks → look for the **[ClashAI Beta]** tab

**Option B — PowerShell**
```powershell
# BIM Parameter mode (no LLM)
.\Instalar_Plugin_ClashBeta.ps1

# AI mode via Ollama
.\Instalar_Plugin_Viewpoints.ps1
```

Supports **Navisworks Manage 2020 through 2026**. Detected automatically.

---

## How to Use

### BIM Parameter Mode
1. Open the **[ClashAI Beta]** tab in Navisworks
2. Select your Clash Test from the dropdown
3. Type the BIM parameter name(s) you want to group by (e.g. `Level / Zone`)
4. Click **Group** — done

### AI Mode (Ollama)
1. Make sure [Ollama](https://ollama.com) is running locally
2. Open the **[CoordinaciónBIM]** tab
3. Choose your model (e.g. `llama3.2`) and Ollama URL
4. Click **Analyze** — the plugin sends clashes in batches to your local LLM
5. Review the proposed groups and apply

> Clashes are sent in chunks of 20 with short IDs (`c0, c1...`) to keep the LLM context clean. Unclassified clashes land in a *Sin clasificar* group automatically.

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
ClashGrouper (deterministic) ──or── OllamaClient (AI)
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
