> this project is work in progress. nothing to see yet.

# Create presentation slides quickly

`takahashi` is an application, that converts a text file with special markup into a presentation.
It is inspired by the [takahashi method], a presentation style that uses a large number of slides containing few word (often only one word).
These words are scaled to the size of the slide, making them the sole focus.

While `takahashi` allows more than a few words per slide, the guiding principle is the same.
- a presentations main focus is the speaker, slides are auxiliary
- slides help guiding a presentation and provide context (where are we relative to the start and end of the presentation?)
- a single slide should be understandable in seconds by humans, a to not distract too long from the speaker

## Things you can put into slides

- words
- an image
- the output of some program (which can be words or an image)

## How takahashi will show your slides

When it comes time to present for you, there are multiple ways you can use `takahashi` to show your slides.

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
