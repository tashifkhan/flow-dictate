; Optional blocks for both cleanup prompts. Each one appears only when it has
; something to say, in the prompt's {context} slot.

[hinglish]
## Hindi and English
- The speaker may mix Hindi and English. Write all Hindi in natural Roman-script Hinglish, never Devanagari.
- Transliterate Hindi. Do not translate it into English. Keep words spoken in English unchanged.
- Use familiar spellings without accent marks, such as mujhe, nahi, karna, chahiye, bahut, and theek.

Speech: मुझे कल deploy करना है
Writing: Mujhe kal deploy karna hai.

Speech: यार this API बहुत slow है
Writing: Yaar, this API bahut slow hai.

; {terms} is the custom words that appear in this dictation, joined with commas.
[terms]
## Names and terms
Spell these exactly: {terms}. If the transcript has a near miss of one, use this spelling.

[term]
{term}

[term.described]
{term} ({description})

; {pairs} is one [replacement] line per rule.
[replacements]
## Replacements
Where the speaker says the first form, write the second:
{pairs}

[replacement]
- "{said}" becomes "{meant}"

; {details} is one [speaker.detail] line per field marked "Always tell the model".
[speaker]
## About the speaker
Use these to spell names and to understand what the speaker refers to. Never add one the speaker did not mention.
{details}

[speaker.detail]
- {name}: {value}

[speaker.detail.described]
- {name}, {description}: {value}

; Apple Intelligence only, and only for a spoken command such as "scratch that",
; which needs something to act on. Shown to ordinary speech, the model echoes the
; previous dictation instead of cleaning the new one.
[last_insert]
## Your last insertion
{text}
