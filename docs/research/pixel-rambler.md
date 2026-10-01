# Pixel Rambler behavior and Flow implementation

Research checked on October 1, 2026. This report covers Google's product guides, launch announcements, model documentation, API reference, its public macOS example, and the earlier academic projects called Rambler. Search results from reviews and community reports helped identify questions, but the technical conclusions below use primary sources.

## What actually powers the Pixel feature

Google's August 26 announcement identifies Gemini 3.5 Transcribe as the model behind Gboard Rambler. It can convert audio directly into cleaned, formatted writing. Google exposes recorded-audio transcription through the Interactions API and live transcription through a separate bidirectional API. The announcement also describes custom vocabulary, language detection, and spoken self-corrections. This is stronger evidence than guessing which general Gemini model Gboard uses. [Google's model announcement](https://blog.google/innovation-and-ai/models-and-research/gemini-models/gemini-3-5-transcribe/)

The public developer API has two modes. Verbatim retains the spoken disfluencies. Smart mode removes them and structures the result. Google's guide explicitly covers paragraph breaks, numbered lists, bullets, number/date/currency formatting, punctuation, and inline repairs. Smart mode cannot combine with speaker labels or word timestamps. Custom vocabulary can guide recognition. [Google's transcription guide](https://ai.google.dev/gemini-api/docs/transcribe)

Flow's production pipeline stays model-agnostic within its supported provider protocols. A one-pass configuration sends audio and the shared cleanup policy to the selected multimodal model. A two-pass configuration sends audio to the chosen transcriber, then sends its text to the chosen refiner. Either stage can use the local Mac implementation, and cloud stages can use different providers. OpenAI-compatible transcribers can explicitly choose the dedicated audio-transcription API or multimodal chat. Legacy model settings keep their prior endpoint. No special Rambler model is selected, suggested, or routed automatically. Google's specialist API is research evidence, not an application requirement.

## The Gboard interaction contract

The shipped guide describes the following behavior:

| Action or condition | Documented result |
| --- | --- |
| Tap the microphone, then finish | Insert the completed writing after capture stops. |
| Hold the microphone, then release | The same capture-and-finish interaction. |
| Recording | A glowing indicator, without live text entering the destination. |
| A later spoken correction | Revise text already in the field. |
| A tone or length request | Apply it inline or in a subsequent recording. |
| An emoji request | Add the requested emoji, or choose one when asked. |
| Mixed supported languages | Process the language switches together. |
| Offline | Basic cleanup remains; advanced rewriting needs connectivity. |
| Availability | Pixel 11, current Gboard, microphone access; usage limits apply. |

Google describes temporary processing and safety refusals. Numerical quotas, production prompts, and complete routing are not published. [Gboard's Rambler guide](https://support.google.com/gboard/answer/17468539?hl=en)

Google's original Gemini Intelligence announcement emphasizes speaking a thought without rehearsing it, including changing one's mind and combining Hindi with English. That is the right target for this Mac app: preserve the intended message while removing the mechanics of saying it aloud. [Gemini Intelligence announcement](https://blog.google/products-and-platforms/platforms/android/gemini-intelligence/)

## What "exactly like Pixel" can and cannot mean

Using the same publicly named model and smart mode gives us a concrete transcription implementation to compare. It does not guarantee identical bytes. Gboard's private prompts, decoding settings, context selection, rollout versions, and editor integration are not fully disclosed. The public model and the Pixel integration also have different supported-language lists. Flow must be tested on actual dictations instead of claiming that a matching model ID proves identical behavior.

Gboard owns its text field through the keyboard. Flow works across unrelated Mac apps through Accessibility and paste. That difference matters most for follow-up edits. Flow currently revises its own last insertion when it can verify that the text still sits at the caret. It cannot safely promise unrestricted conversational rewriting of every existing document. If verification fails, a replacement goes to the clipboard. It never silently deletes whatever happens to be before the caret.

Flow's no-em-dash rule is an additional user preference. The shared cleanup prompt prohibits U+2014, and a deterministic final pass replaces it even if a model ignores the instruction. Raw Apple speech-recognition text remains untouched for inspection.

## A useful public macOS implementation

Google's public `jot-gemini-transcribe-macOS` repository is a demo, with an explicit statement that it is not an officially supported product. Its client separates native smart transcription from optional general-model tone cleanup. The client code documents practical endpoint differences and probes, including audio-only specialist requests and avoiding language hints alongside smart mode. Those observations are useful integration evidence, but are not proof of Gboard's internal implementation. Flow uses its existing capture, insertion, history, and provider ladder rather than importing that app. [Jot repository](https://github.com/google-gemini/jot-gemini-transcribe-macOS), [its transcription client](https://github.com/google-gemini/jot-gemini-transcribe-macOS/blob/main/JotCore/Sources/TranscriptionClient/GeminiClient.swift)

Jot's client also documents native endpoint differences and empirical option incompatibilities. Its native model route is specific to that demo. Flow does not import it or require that model. Changing provider adapters remains separate from the shared cleanup policy and from choosing one or two passes.

## Earlier research also called Rambler

The CHI 2024 Rambler paper describes a speech-writing interface with summaries and keywords for reviewing dictated material. Users can revise larger units by respeaking, splitting, merging, or transforming them. Its comparison involved 12 participants. It is useful evidence for retaining reviewable source material and supporting iterative revision. It is not a specification for the Pixel 11 keyboard feature, and its name does not establish that Google shipped its exact interface or prompts. [Lin and colleagues, CHI 2024](https://arxiv.org/abs/2401.10838)

The 2025 follow-up reports a ten-day diary study with 12 academic or creative writers. It examines outlining, organizing loose thoughts, and composing different kinds of writing. The practical lesson for Flow is to distinguish dictation cleanup from deliberate rewriting. A user who asks to shorten a draft permits shortening; an ordinary dictated paragraph should retain its details. [Yang and colleagues, 2025 diary study](https://arxiv.org/abs/2502.05612)

## Flow's cleanup contract

These are Flow's own behavior targets and examples, not quoted Pixel outputs. Both the local Apple Intelligence pass and prompted cloud cleanup use the same policy.

| Speech | Intended behavior |
| --- | --- |
| "um uh I think we should ship" | Remove hesitation sounds, keep the opinion. |
| "I think I think we should ship" | Collapse accidental repetition. |
| "meet Thursday sorry Friday at three" | Keep Friday, preserve the time. |
| "the API is broken no that's not right it is slow with a cold cache" | Remove the abandoned claim without dropping the cache condition. |
| "three changes first fix login second add tests third update docs" | Produce three numbered items. |
| "buy milk eggs and rice make that a bullet list" | Produce bullets and omit the formatting direction. |
| "this is my first time using version two" | Keep prose. Do not invent a list. |
| "please fix the sidebar and keep the remaining button" | Retain the request as message content. Do not act as the recipient. |
| "why is the API slow" | Write the question. Do not answer it. |
| A technical name near a vocabulary entry | Prefer the known spelling when context supports it. |
| Hindi mixed with English in Hinglish mode | Keep the language mixture and use Roman script. |
| "make this more professional" as a follow-up | Revise the previous insertion through the local command path. |
| "make this shorter" at the end of a draft | Permit intentional shortening, rather than reject it as accidental truncation. |
| A request for an emoji | Add it only when asked. |
| A model emits an em dash | Replace it before saving or inserting the finished version. |

Flow retains its deterministic spoken-list parser because it also manages continued numbering and list state across recordings. Cleanup now runs on list content too. Previously a recognized list could bypass the model cleanup, leaving fillers and punctuation untouched. The list continuation owns its starting number, so the final pass aligns model numbering with that state.

The default policy preserves facts, names, numbers, negation, uncertainty, and constraints. It does not translate Hindi into English, invent greetings, answer dictated questions, or summarize without a request. Filler-like words disappear only when they are filler. For example, "I like this design" must keep "like." Output length and source-overlap guards still catch unrelated answers and accidental truncation. Explicit trailing drafting directions no longer inflate the length baseline.

Model quality remains a practical limitation. The local model can reject a request or fall back to unrefined text. History labels that fallback as local unrefined output. A strong cloud result can finish before the local pass; the local version is attached to that same recording when it finishes.

## Versions and measurements

Raw is Apple's speech-recognition output before cleanup or transliteration. Local transcription is a separate result from that input. Cloud versions identify their configuration. Each has its own copy control. Versions are saved even when their text matches. Late replies retain their recording ID, so they cannot attach to the next dictation.

History shows processing time from recording stop to final text readiness, plus total time from starting dictation. The existing capture duration is shown separately. Old entries retain their saved text; the app cannot reconstruct timing, raw Apple text, or usage that was never recorded.

Every actual provider request has a separate persistent ID. Retrying a rejected streaming request, a separate transcription/cleanup stage, and a parallel configuration each add a call. Updating a request with final usage and pricing does not add a call. A failed or cancelled attempt remains visible even if another provider supplies the inserted version. Metadata survives transcript retention, without keeping request bodies or response content in the accounting log.

First-token latency measures the first visible streamed text chunk after request dispatch. It excludes empty headers and thinking-only events. Generation throughput uses reported visible output tokens and the interval between first and last visible chunks. Whole-request throughput uses the full request duration. A single-chunk reply cannot provide generation throughput. Providers that combine hidden thinking with output without a separate count cannot provide an honest visible-token speed. These are client-side measurements, not provider-side compute time.

## Cost accounting

Flow fetches `https://models.dev/api.json`, caches it locally, refreshes daily, and saves the selected price with the call. It matches the exact provider and model, with a provider-ID override for proxies. It does not assume that an OpenAI-compatible host charges OpenAI's rates. The catalog includes input/output prices and, where available, cached-token and audio rates. [models.dev](https://models.dev/), [catalog API](https://models.dev/api.json)

For ordinary text, the estimate is input tokens times the input rate plus output tokens times the output rate, divided by one million. Cached input, cache writes, and audio use their own rates. Applicable context tiers are selected using the reported input count. Reasoning is billed as output. Gemini's separately reported thought count is added to candidate tokens; OpenAI's reasoning count is already part of completion tokens. Anthropic cache counters join ordinary input to form the normalized input total. [Gemini response usage](https://ai.google.dev/api/generate-content), [OpenAI streaming usage](https://developers.openai.com/cookbook/examples/how_to_stream_completions), [Anthropic streaming usage](https://platform.claude.com/docs/en/build-with-claude/streaming)

Statistics combines dictation metrics and cloud accounting. Today, Last 7 Days, Last 30 Days, Last Year, and All Time use the same local-day cutoffs for both. Daily and monthly calendar breakdowns can filter the request list. Activity can display words, estimated cloud spend, or cloud calls over the trailing year. Provider/model summaries include every attempted LLM call and average timings from successful calls with measured values. Per-version history groups both stages of a two-pass configuration and its retries. The all-request history section also includes failed configurations that produced no version.

Missing usage, unmatched models, unsupported cache-duration pricing, and ambiguous cached-audio overlap remain unknown. Totals show known spend and the number of unpriced calls. These are estimates, not invoices, and cannot include provider account credits or discounts absent from the catalog. Gemini 3.5 Transcribe was not in the models.dev snapshot retrieved during this research. Google nevertheless publishes recorded Transcribe rates of $2 input audio and $12 output text per million tokens; Live has separate $3.50/$21 rates. Missing catalog entries on the direct Google host now use these verified rates with a saved source URL and verification date. Updated catalog prices take precedence, and proxy hosts never inherit this fallback. [Official pricing](https://ai.google.dev/gemini-api/docs/pricing#gemini-3.5-transcribe). Its native output also reported zero top-level output tokens on a successful probe. Flow retains those reported counts rather than fabricating token usage from the visible sentence. [Interactions response schema](https://ai.google.dev/api/interactions-api)

## Validation and comparison

The automated checks cover legacy history migration, untouched raw text, version/request association, late results, persistence across reopening, token normalization, cache/audio prices, exact catalog matching, calendar boundaries, unknown-cost totals, and final em-dash removal. Local HTTP fixtures exercise real URLSession streams for OpenAI, Gemini, and Anthropic, including retries, failure fallback, cancellation, and parallel late completion.

The installed model-agnostic build passed 265 self-checks after adding official-price fallback checks. The model-agnostic transport passed 14 HTTP integration checks. Native accessibility checks also verified that Raw and cloud-version copy buttons reproduce the stored text in both list and grid views, and that the toolbar has one sidebar button. The installed Statistics view and its daily/monthly breakdowns displayed persisted requests, and expanded details showed token prices, input/output costs, request duration, first-visible-token latency, and throughput fields.

Before removing the specialist route from the application, a diagnostic comparison sent the same synthetic recording to the configured Gemini 3.8 Flash and the specialist Gemini 3.5 Transcribe endpoint. The speaker listed three changes and corrected the meeting day to Friday. Apple Intelligence cleanup also processed the transcription. All three results retained the three changes and Friday.

| Result | Observed cleanup | Cloud request time | Estimated cost |
| --- | --- | --- | --- |
| Apple Intelligence local | Removed the opening filler, numbered the changes, and punctuated each item | Local processing, no cloud call | No cloud charge |
| Gemini 3.8 Flash with Flow's prompt | Removed the opening filler, numbered and punctuated the changes, and separated the meeting into a paragraph | 5.63 seconds | $0.003361 |
| Gemini 3.5 Transcribe smart mode | Numbered the changes and separated the meeting into a paragraph, but retained the opening "Um" and omitted periods on list items | 1.34 seconds | Not a reliable full-call estimate, reported output was zero |

These are single-request observations, not a speed benchmark or proof of Pixel parity. The general model reported 717 input and 753 output tokens, including reasoning, and delivered visible text in one chunk. Its first-visible-token latency was 5.63 seconds; generation throughput cannot be measured from one chunk. The specialist reported 173 input and zero output tokens despite returning text. The price is published, but the zero output count makes this probe unsuitable as a complete billed-cost benchmark. Flow retains provider-reported counts rather than guessing token usage. This earlier diagnostic used Gemini 3.8 Flash; it does not change the user's chosen model. The application no longer has a special Rambler shortcut or hardcoded specialist route.

The native model's retained filler matters. Sharing a model family does not guarantee Gboard's exact cleanup behavior, and this example favors Flow's explicit cleanup prompt for the user's requested style.

For a meaningful Pixel comparison, record the same spoken cases on both devices and compare the retained facts, repairs, list structure, paragraphs, names, Hindi/English handling, and whether drafting directions remain in the message. Measure full completion latency separately from provider generation speed. Keep Raw available whenever a cleaned result loses something, because it is the evidence needed to improve the policy.

## Published article and source library

The expanded article is published only on dump.taf.sh, in the blog writing style. The public article focuses on Google Rambler, with one brief mention of Flow. It includes 11 annotated sources, a bibliography, 16 evidence claims, two sourced logical diagrams, and verified official pricing. Flow implementation details, prompts, and synthetic comparisons are excluded from the public article. Private Gboard routing is labeled as unpublished rather than invented.

[Read the article and library](https://dump.taf.sh/d/091_pixel-rambler-model-agnostic-dictation/).
