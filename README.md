> this project is work in progress. nothing to see yet.

# Create presentation slides quickly

`taka` is an application, that converts a text file with special markup into a presentation.
It is inspired by the [takahashi method], a presentation style that uses a large number of slides containing few word (often only one word).
These words are scaled to the size of the slide, making them the sole focus.

While `taka` allows more than a few words per slide, the guiding principle is the same.
- a presentations main focus is the speaker, slides are auxiliary
- slides help guiding a presentation and provide context (where are we relative to the start and end of the presentation?)
- a single slide should be understandable in seconds by humans, a to not distract too long from the speaker

## Things you can put into slides

- words
- an image
- the output of some program (which can be words or an image)

## How taka will show your slides

When it comes time to present for you, there are multiple ways you can use `taka` to show your slides.

- launch full screen window (X11, Wayland, mac, windows)
- launch text-based application in terminal emulator (some VT100 descendant or conhost)
- create a PDF file
- create a HTML file

## How to write slides

You can write your slides in a text file, that follows some special markup rules.

- every paragraph (text blocks delimited by empty lines) will become a slide
- contents of a slide (words and/or images) will be scaled to take up the maximum amount of available space, while preserving aspect ratio and keeping some padding distance to the edges
- the encoding of the file must be UTF-8

### Special markup for words

- mono space: \`example\` -> `example`
- bold: \*example\* -> __example__
- italic: \/example\/ -> _example_
- underline: \_example\_ -> <u>example</u>
- strike through: \-example\- -> ~~example~~
- reverse: \|example\| -> <span style="color:Background; background-color:WindowText">example</span>

### Comments

Any line starting with `#` is a comment line.
Comments are __not ignored__.
But they are invisible in the final rendered slide.
Comments are always mapped to the following slide.
Depending on the output format, they get turned into notes, presentor mode or are simply discarded.

### Importing images into a slide

Reference an image on disk by using the `@image(<path>)` function.
The `path` to the image can be either a path relative to slides file or an absolute path.
A single slide can hold an arbitrary number of images.
Images will always be scaled so that their size is maximized (respecting aspect ratio).
Multiple images are arranged in a equally weighted grid from top left to bottom right.

Images are rendered in the background layer of the slide, so that laying out images and text can happen separately.
This results in text always being rendered on top of images if both are present on a single slide.

### Shelling out to produce a slide

Assume that a slide should show the output of some command.
Many people are comfortable with shell scripts, so here is an example of using some POSIX shell:

```
Welcome To This Presentation

Demonstrating the \`system\` function

number of words on all slides: @system(sh -c wl -c)
```

The `@system(...)` part will be replaced by the output of running `sh -c wc -c` and piping the contents of the slides file into standard input.
The `system` function can run any program, that is accessible via the `PATH` environment variable.
So the above example could have been written as `@system(wl -c)` if `wl` is program in your `PATH`.

A common use case for shelling out is to construct a pipeline of commands.
If all you need is a pure pipeline (no control flow or string manipulation) then the `pipe` function can be used.
It works similarly to the `system` function, but takes a list of programs that will be composed into a pipeline.

```
number of unique words: @pipe(tr -c a-zA-Z | sed '/^$/d' | sort | uniq -i -c)
```

Programs are separated by `|` so that it looks very similar to a shell script.
The pipeline however is constructed by taka.
These features are intended to make taka slightly more portable across *Unix* and *Windows* systems.

## Functions

### `@image(<path>)`

Lists the functions built-in to taka and their documentation.
The general syntax for functions is: `@function_name(parameter_list)`.
Parameters are delimited by whitespace or the special character `|`.
Use `''` to group parameters, for example to include whitespace into a parameter.
Escape the `'` character with `\\` to `\\'` if you want to literally specify `'` as a parameter.
The same applies to `|`.

Looks for an image file at `path` and includes it into the background layer of the current slide.
`path` can be absolute or relative to the current file.
Supported image formats are JPEG, PNG and GIF.
Images are scaled to take up the maximum amount of slide space, while still respecting the aspect ratio of the image.
If multiple images are shown on one slide, they are arranged in a equally weighted grid, from top left to bottom right.
*Equally weighted* means, that all images will have roughly the same size.
*Roughly*, because, unless all images have the same aspect ratio, it is unlikely that the resulting sizes will be equal.

### `@system(<program> <arguments...>)`

Looks for `program` in the `PATH` environment variable and invokes it with `arguments...`.
Arguments are separated by whitespace and grouped with `'...'`.
Assuming you want to invoke the program `echo` with arguments `a`, `b` and `c`.
The difference between `@system(echo a b c)` and `@system(echo 'a b c')` is that the first invokes the program `echo` with _three_ arguments (`a`, `b` and `c`) while the second invokes `echo` with _one_ argument (`a b c`).

> A program `echo` usually does not exist but is a shell builtin function.

The contents of the current file is piped into the standard input of the invoked command.
The standard output of the command will be used to replace the `@system(...)` symbols before rendering output.
All `system` functions are given the file contents before any system function was run.
That means, the order of slides and the outputs of `system` functions do not potentially disturb each other.

Some programs do not work well with standard input but want to take in paths as arguments.
In those cases use the special `%` placeholder in the argument list.
This special symbol will expand to the current file path (absolute).
Its presence will also prevent the piping of the file contents to standard input.
If the path to the current file is hard coded into the argument list, the effect will be the invoked program will receive the file contents via standard input and via path.

```
INCEPTION

deeper @system(cat %)
```

The output of the invoked program is expected to be text (UTF-8) or one of the supported image file formats.

Example:

```
Todays weather in Berlin
@system(curl wttr.in/Berlin?qpt0)

This time as an image
@system(curl wttr.in/Berlin_qpt0.png)
```

### `@pipe(<program> <arguments...> | <program> <arguments...> | ...)`

Looks for `programs` in the `PATH` variable and constructs a pipeline out of the given programs separated by `|`.
The output of the previous command becomes the input of the current command.
From left to right until the number of programs is exhausted.
The resulting output will be used to replace the `@pipe(...)` call in the final rendering of the slides.
Same rules for output, quoting and grouping as for `system` apply.

Example:

This example assumes there is a `source.png` file that will be combined with some weather info.

```
Who needs Photoshop?
@pipe(curl wttr.in/Berlin_qpt0.png | magick convert source.png - -geometry +50+50 -composite -)

when you can have cryptic commands!
```
