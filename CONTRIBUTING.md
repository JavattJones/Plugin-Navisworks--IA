# Contributing to ClashAI

Thanks for your interest. This project is built by one person solving a real BIM coordination problem — any help makes it better for the whole community.

---

## Ways to Contribute

### 💡 Share an idea
The easiest way. No coding required.

1. Go to [**Discussions → Ideas**](../../discussions/categories/ideas)
2. Open a new discussion
3. Describe the problem you face today, not just the feature you want

Good submissions answer: *"What takes you too long today in Navisworks coordination?"*

### 🐛 Report a bug
1. Go to [**Discussions → Bug Reports**](../../discussions/categories/bug-reports)
2. Include: Navisworks version, steps to reproduce, what you expected vs what happened

### 🔧 Contribute code
The plugin compiles from PowerShell at install time — no Visual Studio needed.

1. Fork the repo
2. Edit the C# block inside the `.ps1` script you want to improve
3. Test it by running the script on a model with clashes
4. Open a Pull Request describing what changed and why

**Ground rules:**
- One change per PR — keep it focused
- If adding a feature, open a Discussion first so we align before you build
- Match the existing style (WinForms UI, async tasks, real-time log output)

---

## Current Priorities

Areas where contributions matter most right now:

| Area | What's needed |
|------|--------------|
| **Claude API client** | Alternative to Ollama for corporate environments without local GPU |
| **BCF export** | Write grouping results to BCF 2.1 for traceability |
| **Navisworks 2027** | Test and update assembly references |
| **English UI review** | Ribbon and dialog strings need native English review |
| **Excel export** | Export clash groups to a structured Excel register |

---

## Feature Requests vs Ideas

| | Where | What to include |
|--|-------|-----------------|
| **Open idea** | [Discussions → Ideas](../../discussions/categories/ideas) | The problem, not just the solution |
| **Specific feature** | [Discussions → Ideas](../../discussions/categories/ideas) | Expected behavior + use case |
| **Bug** | [Discussions → Bug Reports](../../discussions/categories/bug-reports) | Steps to reproduce + NW version |

---

## Questions?

Open a [Discussion](../../discussions) — no question is too small.
