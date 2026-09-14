// 本项目的文档模板。
// 约定：任何章节文件只允许出现内容与局部 #let，禁止 #set / #show / #include。
// 原因（实测）：#include 会把被包含文件里的 #set 规则泄漏到后续整篇文档，#import 不会。

#let opl-conf(
  title: [],
  subtitle: none,
  authors: (),
  date: none,
  version: none,
  abstract: none,
  doc,
) = {
  set document(title: title, author: authors.map(a => a.name))
  set page(
    paper: "a4",
    margin: (x: 2.1cm, y: 2.2cm, top: 2.6cm),
    numbering: "1",
    number-align: center,
    header: context {
      let hs = query(selector(heading.where(level: 1)).before(here()))
        .filter(h => h.body != [目录])
      if hs.len() > 0 {
        set text(size: 8pt, fill: luma(130))
        hs.last().body
        v(-0.75em)
        line(length: 100%, stroke: 0.4pt + luma(205))
      }
    },
  )
  set text(
    font: ("Noto Serif CJK SC", "Noto Serif", "Liberation Serif"),
    size: 10.5pt,
    lang: "zh",
    region: "cn",
  )
  set par(justify: true, leading: 0.85em, spacing: 1.05em)
  set heading(numbering: "1.1")
  show heading: it => {
    if it.level == 1 {
      pagebreak(weak: true)
      v(0.2em)
      block(below: 1.0em, text(size: 16.5pt, weight: "bold", it))
      v(-0.5em)
      line(length: 100%, stroke: 0.7pt + luma(160))
    } else if it.level == 2 {
      block(above: 1.25em, below: 0.6em, text(size: 13pt, weight: "bold", it))
    } else {
      block(above: 1.0em, below: 0.45em, text(size: 11pt, weight: "bold", it))
    }
  }
  show raw.where(block: true): it => block(
    width: 100%,
    inset: 8pt,
    radius: 3pt,
    fill: luma(246),
    stroke: 0.4pt + luma(215),
    text(font: ("DejaVu Sans Mono", "Noto Sans Mono CJK SC"), size: 8.4pt, it),
  )
  show link: it => text(fill: rgb("#0b5fa5"), it)
  set list(marker: ([•], [--]))
  set table(
    stroke: 0.4pt + luma(190),
    inset: 5pt,
    align: horizon,
  )
  show table.cell.where(y: 0): set text(weight: "bold")

  // 封面
  align(center)[
    #v(2.0cm)
    #text(size: 22pt, weight: "bold", title)
    #if subtitle != none [
      #v(0.5em)
      #text(size: 12pt, fill: luma(90), subtitle)
    ]
    #v(1.2em)
    #line(length: 45%, stroke: 0.8pt + luma(150))
    #v(1.2em)
    #if authors.len() > 0 [
      #for a in authors [
        #a.name
        #if "affiliation" in a [ #text(size: 9.5pt, fill: luma(100), "（" + a.affiliation + "）") ]
        #linebreak()
      ]
    ]
    #v(0.8em)
    #if version != none [ #text(size: 9.5pt, fill: luma(100), version) #linebreak() ]
    #if date != none [ #text(size: 9.5pt, fill: luma(100), date) ]
  ]
  if abstract != none [
    #v(1.6em)
    #block(
      width: 100%,
      inset: 11pt,
      radius: 3pt,
      fill: luma(248),
      stroke: 0.4pt + luma(205),
    )[
      #text(size: 10.5pt, weight: "bold")[摘要]
      #v(0.35em)
      #text(size: 10pt, abstract)
    ]
  ]
  v(1.6em)
  outline(title: [目录], indent: auto, depth: 2)
  pagebreak()
  doc
}
