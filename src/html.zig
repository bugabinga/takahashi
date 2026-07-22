//! HTML output form (SPEC 3.4): render a document to a single self-contained
//! HTML file — inline CSS, minimal vanilla JS for navigation, images embedded
//! as data URIs. Returns an owned buffer; the caller writes it out.
//!
//! Speaker notes (SPEC 2.1) live in a hidden `.notes` div per slide, invisible
//! to the audience. Pressing `p` opens a presenter window (a second browser
//! window) that reads those notes and stays synced to the deck; it uses a
//! direct window reference rather than BroadcastChannel so it also works when
//! the file is opened over `file://` (an opaque origin, where channels do not
//! connect).

const std = @import("std");
const Allocator = std.mem.Allocator;

const document = @import("document.zig");
const Slide = document.Slide;
const Span = document.Span;

const head =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>takahashi</title>
    \\<style>
    \\  html,body{margin:0;height:100%;background:#000;color:#f5f5f5;
    \\    font-family:system-ui,sans-serif}
    \\  section{display:none;height:100%;box-sizing:border-box;padding:5vmin;
    \\    place-content:center;text-align:center;white-space:pre-wrap;
    \\    font-size:8vmin;font-weight:700}
    \\  section.active{display:grid}
    \\  img{max-width:100%;max-height:70vh;object-fit:contain}
    \\  code{font-family:ui-monospace,monospace}
    \\  .rev{filter:invert(1)}
    \\  .notes{display:none}
    \\</style></head><body>
    \\
;

const tail =
    \\<script>
    \\  const slides=[...document.querySelectorAll('section')];
    \\  let i=0, pres=null;
    \\  const notesOf=n=>{const d=slides[n].querySelector('.notes');
    \\    return d?d.textContent:''};
    \\  const textOf=n=>{const s=slides[n].cloneNode(true);
    \\    const d=s.querySelector('.notes'); if(d)d.remove();
    \\    return s.textContent.trim()||'(media slide)'};
    \\  const nav=e=>{
    \\    if(e.key==='ArrowRight'||e.key===' ')show(i+1);
    \\    else if(e.key==='ArrowLeft')show(i-1);
    \\    else if(e.key==='Home')show(0);
    \\    else if(e.key==='End')show(slides.length-1);
    \\    else if(e.key==='p'||e.key==='P')togglePresenter()};
    \\  const show=n=>{slides[i].classList.remove('active');
    \\    i=Math.max(0,Math.min(slides.length-1,n));
    \\    slides[i].classList.add('active');
    \\    renderPresenter()};
    \\  function togglePresenter(){
    \\    if(pres&&!pres.closed){pres.focus();return}
    \\    pres=window.open('','taka-presenter','width=820,height=620');
    \\    if(!pres)return;
    \\    pres.document.write('<!doctype html><meta charset=utf-8>'
    \\      +'<title>taka · presenter</title><style>'
    \\      +'html,body{margin:0;height:100%;background:#111;color:#eee;'
    \\      +'font-family:system-ui,sans-serif}'
    \\      +'body{display:flex;flex-direction:column;gap:1rem;padding:2rem;'
    \\      +'box-sizing:border-box}'
    \\      +'#pos{font-size:.9rem;color:#888;letter-spacing:.1em;'
    \\      +'text-transform:uppercase}'
    \\      +'#cur{font-size:1.1rem;color:#9ab}'
    \\      +'#notes{flex:1;font-size:2rem;line-height:1.45;white-space:pre-wrap;'
    \\      +'overflow:auto}'
    \\      +'#next{font-size:1rem;color:#778;border-top:1px solid #333;'
    \\      +'padding-top:1rem}</style><body>'
    \\      +'<div id=pos></div><div id=cur></div><div id=notes></div>'
    \\      +'<div id=next></div>');
    \\    pres.document.close();
    \\    pres.document.addEventListener('keydown',nav);
    \\    renderPresenter();
    \\  }
    \\  function renderPresenter(){
    \\    if(!pres||pres.closed)return;
    \\    const d=pres.document;
    \\    d.getElementById('pos').textContent='Slide '+(i+1)+' / '+slides.length;
    \\    d.getElementById('cur').textContent=textOf(i);
    \\    d.getElementById('notes').textContent=notesOf(i)||'(no notes)';
    \\    d.getElementById('next').textContent=i+1<slides.length
    \\      ?'Next → '+textOf(i+1):'— end —';
    \\  }
    \\  addEventListener('keydown',nav);
    \\  addEventListener('beforeunload',()=>{if(pres&&!pres.closed)pres.close()});
    \\  if(slides.length)show(0);
    \\</script></body></html>
    \\
;

pub fn render(gpa: Allocator, slides: []const Slide) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, head);
    for (slides) |slide| {
        try out.appendSlice(gpa, "<section>");
        for (slide.spans) |span| try writeSpan(gpa, &out, span);
        for (slide.media) |media| try writeMedia(gpa, &out, media);
        if (slide.notes.len != 0) {
            try out.appendSlice(gpa, "<div class=\"notes\">");
            try appendEscaped(gpa, &out, slide.notes);
            try out.appendSlice(gpa, "</div>");
        }
        try out.appendSlice(gpa, "</section>\n");
    }
    try out.appendSlice(gpa, tail);
    return out.toOwnedSlice(gpa);
}

fn writeSpan(gpa: Allocator, out: *std.ArrayList(u8), span: Span) Allocator.Error!void {
    const s = span.style;
    if (s.mono) try out.appendSlice(gpa, "<code>");
    if (s.bold) try out.appendSlice(gpa, "<b>");
    if (s.italic) try out.appendSlice(gpa, "<i>");
    if (s.underline) try out.appendSlice(gpa, "<u>");
    if (s.strike) try out.appendSlice(gpa, "<s>");
    if (s.reverse) try out.appendSlice(gpa, "<span class=\"rev\">");
    try appendEscaped(gpa, out, span.text);
    if (s.reverse) try out.appendSlice(gpa, "</span>");
    if (s.strike) try out.appendSlice(gpa, "</s>");
    if (s.underline) try out.appendSlice(gpa, "</u>");
    if (s.italic) try out.appendSlice(gpa, "</i>");
    if (s.bold) try out.appendSlice(gpa, "</b>");
    if (s.mono) try out.appendSlice(gpa, "</code>");
}

fn writeMedia(gpa: Allocator, out: *std.ArrayList(u8), media: document.Media) Allocator.Error!void {
    const src = media.data_uri orelse media.path;
    switch (media.kind) {
        .image => {
            try out.appendSlice(gpa, "<img src=\"");
            try appendEscaped(gpa, out, src);
            try out.appendSlice(gpa, "\">");
        },
        .audio => {
            try out.appendSlice(gpa, "<audio controls src=\"");
            try appendEscaped(gpa, out, src);
            try out.appendSlice(gpa, "\"></audio>");
        },
    }
}

fn appendEscaped(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |byte| switch (byte) {
        '&' => try out.appendSlice(gpa, "&amp;"),
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '"' => try out.appendSlice(gpa, "&quot;"),
        else => try out.append(gpa, byte),
    };
}

test "renders styled spans, media and one section per slide" {
    const gpa = std.testing.allocator;
    const spans = [_]Span{
        .{ .text = "big ", .style = .{} },
        .{ .text = "bold", .style = .{ .bold = true } },
    };
    const media = [_]document.Media{.{ .kind = .image, .path = "p.png", .data_uri = "data:image/png;base64,AAA" }};
    const slides = [_]Slide{.{ .spans = &spans, .media = &media, .notes = "hi" }};

    const doc = try render(gpa, &slides);
    defer gpa.free(doc);
    try std.testing.expect(std.mem.startsWith(u8, doc, "<!doctype html>"));
    try std.testing.expect(std.mem.indexOf(u8, doc, "<b>bold</b>") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "src=\"data:image/png;base64,AAA\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, doc, "<section>"));
    // Notes are present but hidden, and a presenter window can surface them.
    try std.testing.expect(std.mem.indexOf(u8, doc, "<div class=\"notes\">hi</div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, ".notes{display:none}") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "taka-presenter") != null);
}

test {
    std.testing.refAllDecls(@This());
}
