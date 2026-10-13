# Prompts

Every prompt Flow sends to a model lives in this folder as Markdown. `scripts/build.sh` copies the files into the app, and Flow reads them at launch. Edit a file and rebuild to change what the models see. `Flow --print-prompts` prints the rendered cloud and Apple Intelligence prompts for a sample dictation.

| File | What it is |
| --- | --- |
| `cleanup-rules.md` | The cleanup rules and examples every model gets, as numbered steps. |
| `cleanup-context.md` | Optional blocks: custom words, replacements, details about the speaker, Hindi and English, and the last insertion. Each appears only when it applies. |
| `cloud-cleanup.md` | The cloud cleanup prompt: one version for a transcript, one for audio sent directly, and a style line per kind of app. |
| `cloud-transcription.md` | Transcription only, the first step of a two-pass cloud route. |
| `apple-intelligence-cleanup.md` | The prompt for Apple Intelligence on this Mac, including spoken commands and its schema field descriptions. The model has a 4,096-token context, so keep it short. |
| `note-summary.md` | The scratchpad note summary. |

## Format

A line like `[transcript]` starts a section, and the section runs to the next one. A prompt's id is its file name and section, such as `cloud-cleanup.transcript`. A line that starts with `;` is a comment. Blank lines at either end of a section are dropped. Line breaks inside a section are kept.

Placeholders work like a Python format string. `{app_name}` is replaced at run time, and `{{` and `}}` write literal braces. Names use lowercase letters, digits, and underscores. A line holding only a placeholder disappears when its value is empty, along with one blank line next to it, so a missing optional block leaves no gap.

Rendering is strict. A missing value, a value the section has no slot for, an unknown section, or a lone brace is an error. `Flow --self-check` renders every section the code uses, and fails on any of these and on a section nothing uses.

## Placeholders

| Prompt | Placeholders |
| --- | --- |
| `cloud-cleanup.transcript`, `cloud-cleanup.audio` | `app_name`, `app_description`, `body` (the rendered `cloud-cleanup.body`) |
| `cloud-cleanup.body` | `app_name`, `cleanup_rules`, `style`, `context` |
| `apple-intelligence-cleanup.prompt` | `app_name`, `app_description`, `field_role`, `cleanup_rules`, `style`, `context` |
| `cleanup-context.terms` | `terms`, the `term` or `term.described` entries joined with commas |
| `cleanup-context.term`, `cleanup-context.term.described` | `term`, `description` |
| `cleanup-context.replacements` | `pairs`, one `replacement` line per rule |
| `cleanup-context.replacement` | `said`, `meant` |
| `cleanup-context.speaker` | `details`, one `speaker.detail` line per field |
| `cleanup-context.speaker.detail`, `.described` | `name`, `description`, `value` |
| `cleanup-context.last_insert` | `text` |

`cleanup_rules` is the rendered `cleanup-rules.rules`. `context` is the `cleanup-context.md` blocks that apply, separated by blank lines. `style` is the prompt's own `style.chat`, `style.email`, `style.development`, `style.document`, or `style.general`. Every other section has no placeholders.
