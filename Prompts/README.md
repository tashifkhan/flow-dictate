# Prompts

Every prompt Flow sends to a model lives in this folder as plain text. `scripts/build.sh` copies the `.txt` files into the app, and Flow reads them at launch. Edit a file and rebuild to change what the model sees.

- `policy.txt` has the cleanup rules every route shares, plus the lines for custom words, replacements, and personal details.
- `cloud.txt` has the transcription and cleanup prompts for cloud models.
- `local.txt` has the prompt for Apple Intelligence on this Mac, its schema field descriptions, and the note summary.

## Format

A line like `[refine]` starts a section, and the section runs to the next one. A prompt's id is its file and section, such as `cloud.refine`. A line that starts with `;` is a comment. Blank lines at either end of a section are dropped. Line breaks inside a section are kept.

Placeholders work like a Python format string. `{app_name}` is replaced at run time, and `{{` and `}}` write literal braces. Names use lowercase letters, digits, and underscores. A line holding only a placeholder disappears when that value is empty, so optional pieces such as `{hinglish}` leave no blank line.

Rendering is strict. A missing value, a value the section has no slot for, an unknown section, or a lone brace is an error. `Flow --self-check` renders every section the code uses and fails on any of these, and on a section nothing uses.

## Placeholders

| Prompt | Placeholders |
| --- | --- |
| `policy.terms` | `terms`, the custom words joined with commas |
| `policy.term`, `policy.term.described` | `term`, `description` |
| `policy.replacements` | `pairs`, the `policy.replacement` lines joined with semicolons |
| `policy.replacement` | `said`, `meant` |
| `policy.speaker` | `details`, the `policy.speaker.detail` lines joined with semicolons |
| `policy.speaker.detail`, `.described` | `name`, `description`, `value` |
| `cloud.refine` | `rules`, `app_name`, `app_description`, `context` (the style line and any optional lines, joined with spaces) |
| `cloud.one_pass` | `refine`, the rendered `cloud.refine` |
| `local.instructions` | `rules`, `hinglish`, `examples`, `app_name`, `app_description`, `field_role`, `style`, `context`, `commands` |
| `local.last_insert` | `text` |

Every other section has no placeholders.
