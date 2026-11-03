# Prompts used by `02_code-text.py`

Every prompt the coder sends is assembled from the files in this folder and
`../coding_prompt.md`, so a run can be reproduced from the repository alone.

| Part | File | Where it goes |
|---|---|---|
| Coding rules (shared by both tasks) | `../coding_prompt.md` | system prompt, first block |
| Task framing | `task_transcript.md` or `task_open_ended.md` | system prompt, second block |
| Codebook (`data/processed/codebook.csv` rendered as a Markdown table) | generated at run time | system prompt, third block, cached |
| Transcript context | the transcript text | first user block, cached, transcript task only |
| Unit to code | `user_transcript.md` / `user_open_ended.md` filled in | last user block |

The model answers through one tool, `submit_codes`, whose JSON schema is defined in
`02_code-text.py` (`SUBMIT_TOOL`): a `passages` array with one entry per `passage_id`, each carrying its codes. Each run writes the fully
rendered system prompt and the SHA-1 of every prompt file into its `manifest.json`.
