**Related issue(s):**

**What changed and why:**

**Checklist**
- [ ] `quarto render scripts/01_clean-data.qmd` runs; the only warnings are the ones documented in `SURVEY.md`
- [ ] `quarto render scripts/survey/01_chartbook.qmd` runs on the current processed data
- [ ] Rendered HTML files committed alongside the `.qmd` changes
- [ ] `data/processed/data-dictionary.csv` regenerated if any column or answer option changed
- [ ] `SURVEY.md` updated with any new fact about the instrument or export (routing, wording, file naming, format)
- [ ] No data files added (only `data-dictionary.csv` is allowed under `data/`)
