# taka — Specification

This document defines the **artifact**: the `.taka` file format, the `taka`
command-line interface, and the output forms it produces. It states *what*
taka is, not *how* it is built. Implementation choices live in the scaffold
and in the rules under `.claude/` and `CLAUDE.md`.

taka turns a plain-text file into a takahashi-style presentation: many
slides, few words each, scaled to fill the frame. Slides are auxiliary;
the speaker is the focus.

---

## 1. File format

A `.taka` file is UTF-8 text. It is a sequence of **slides**.

- A slide is a paragraph: a run of non-empty lines delimited by one or more
  blank lines. Order is preserved.
- Content is scaled to fill the frame while preserving aspect ratio and
  keeping padding to the edges.

### 1.1 Comments

- A line whose first character is `#` is a comment.
- Comments are not rendered. Each comment attaches to the slide that
  follows it and carries into that slide's speaker notes.

### 1.2 Text markup

Inline styles are delimited by a marker on both sides of the text:

| Marker      | Style       |
|-------------|-------------|
| `` `text` `` | monospace   |
| `*text*`    | bold        |
| `/text/`    | italic      |
| `_text_`    | underline   |
| `-text-`    | strikethrough |
| `\|text\|`  | reverse (swap foreground/background) |

A marker is escaped by preceding it with `\`, which renders the marker
literally.

### 1.3 Functions

A function call has the form `@name(arguments)` and is replaced by its
result before rendering.

Argument rules, shared by all functions:

- Arguments are separated by whitespace or `|`.
- Group an argument (e.g. to include whitespace) with `'single quotes'`.
- Escape a literal `'` or `|` with a leading `\`.

Defined functions:

- **`@image(path)`** — includes the image at `path` (relative to the file,
  or absolute). Supported formats: JPEG, PNG, GIF. The image is placed in
  the slide's background layer.
- **`@system(program args…)`** — runs `program` (resolved via `PATH`) with
  the given arguments and substitutes its standard output. The file's full
  contents are piped to the program's standard input. The token `%` expands
  to the absolute path of the current file; its presence suppresses the
  stdin piping. Output must be UTF-8 text or a supported image format.
- **`@pipe(a args… | b args… | …)`** — runs the listed programs as a
  pipeline, each program's output feeding the next, and substitutes the
  final output. Same output, quoting, and grouping rules as `@system`.

Every function receives the file as it was before any function ran, so
functions never affect one another's input.

---

## 2. Command-line interface

```
taka [options] <file>
```

- `<file>` is a path to a `.taka` file, or `-` to read from standard input.
- The default output form is an interactive window (§3.1).
- An option selects the output form; file forms accept a destination path,
  defaulting to standard output.
- Diagnostics go to standard error and reference the offending line.
  Malformed input is reported, never silently dropped.
- Exit status is zero on success, non-zero on any error.

### 2.1 Presenting (interactive forms)

Interactive forms (window, terminal) give the speaker control over pacing
and a sense of position in the talk. They provide, at minimum:

- advance to the next slide and return to the previous one,
- jump to the first and last slide,
- an always-available indication of position (e.g. current slide and total),
- a presenter affordance surfacing the current slide's speaker notes,
- a way to quit.

---

## 3. Output forms

All forms share the layout rules of §1: one slide per paragraph, content
scaled to fill with padding, aspect ratio preserved. Multiple images on a
slide are arranged in an equally weighted grid from top-left to
bottom-right. Images render in the background; text renders on top.

Each form maps speaker notes as noted below.

### 3.1 Window

A full-screen graphical window (X11, Wayland, macOS, Windows). Interactive
(§2.1). Notes are shown via the presenter affordance.

### 3.2 Terminal

A text-based application in a terminal emulator. Interactive (§2.1). Text
markup and layout degrade gracefully to what the terminal supports. Notes
are shown via the presenter affordance.

### 3.3 PDF

A paginated PDF document, one slide per page. Notes become page notes where
the format allows, and are otherwise discarded.

### 3.4 HTML

A single HTML file. Slides are navigable in a browser. Notes become
presenter/speaker notes where supported, and are otherwise discarded.
