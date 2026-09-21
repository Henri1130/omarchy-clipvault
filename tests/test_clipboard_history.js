#!/usr/bin/env node
"use strict"

const assert = require("assert")
const fs = require("fs")
const path = require("path")
const H = require("../ClipboardHistory.js")

function test(name, fn) {
  fn()
  console.log("ok  " + name)
}

test("normalizeEntry preserves pinned on text and image", () => {
  assert.deepStrictEqual(
    H.normalizeEntry({ type: "text", text: "hi", pinned: true }),
    { type: "text", text: "hi", pinned: true }
  )
  const img = H.normalizeEntry({ type: "image", path: "/tmp/a.png", pinned: 1 })
  assert.strictEqual(img.pinned, true)
  assert.strictEqual(img.path, "/tmp/a.png")
})

test("addEntry keeps pin when the same item is copied again", () => {
  const history = [{ type: "text", text: "keep", pinned: true }]
  const next = H.addEntry(history, { type: "text", text: "keep" }, 10)
  assert.strictEqual(next.length, 1)
  assert.strictEqual(next[0].pinned, true)
})

test("addEntry evicts unpinned items before pinned ones", () => {
  const history = [
    { type: "text", text: "newish", pinned: false },
    { type: "text", text: "pin-me", pinned: true },
    { type: "text", text: "old", pinned: false }
  ]
  const next = H.addEntry(history, { type: "text", text: "fresh" }, 3)
  assert.strictEqual(next.length, 3)
  assert.ok(next.some((e) => e.text === "pin-me" && e.pinned))
  assert.ok(next.some((e) => e.text === "fresh"))
  assert.ok(!next.some((e) => e.text === "old"))
})

test("clearUnpinned keeps only pins", () => {
  const next = H.clearUnpinned([
    { type: "text", text: "a", pinned: false },
    { type: "text", text: "b", pinned: true },
    { type: "text", text: "c" }
  ])
  assert.deepStrictEqual(next, [{ type: "text", text: "b", pinned: true }])
})

test("hasUnpinned", () => {
  assert.strictEqual(H.hasUnpinned([{ type: "text", text: "b", pinned: true }]), false)
  assert.strictEqual(H.hasUnpinned([{ type: "text", text: "a" }]), true)
  assert.strictEqual(H.hasUnpinned([]), false)
})

test("togglePinAt flips only the targeted row", () => {
  const history = [
    { type: "text", text: "a", pinned: false },
    { type: "text", text: "b", pinned: false }
  ]
  const next = H.togglePinAt(history, 1)
  assert.strictEqual(next[0].pinned, false)
  assert.strictEqual(next[1].pinned, true)
  assert.strictEqual(history[1].pinned, false)
})

test("normalizeEntry and parseEntryJson discard oversized text", () => {
  const huge = "x".repeat(H.maxTextChars + 1)
  assert.strictEqual(H.normalizeEntry({ type: "text", text: huge }), null)
  assert.strictEqual(H.normalizeEntry(huge), null)
  assert.strictEqual(H.parseEntryJson(JSON.stringify({ type: "text", text: huge })), null)
  assert.strictEqual(H.parseEntryJson("x".repeat(H.maxJsonChars + 1)), null)
  assert.deepStrictEqual(H.parseHistory(JSON.stringify([{ type: "text", text: huge }])), [])
  assert.ok(H.normalizeEntry({ type: "text", text: "ok" }))
})

test("Clipboard.qml collectors abort oversized capture records", () => {
  const qml = fs.readFileSync(path.join(__dirname, "../Clipboard.qml"), "utf8")
  assert.ok(qml.includes("captureJsonLimit: 2097152"))
  assert.ok(qml.includes("raw.length > root.captureJsonLimit"))
  assert.ok(qml.includes("text.length > root.captureJsonLimit"))
  assert.ok(qml.includes("root.acceptCaptureChunk(data)"))
  assert.ok(!/onStreamFinished:\s*root\.addClipboardJson\(text\)/.test(qml))
  assert.ok(!/onRead:\s*function\(data\)\s*\{\s*root\.addClipboardJson\(data\)\s*\}/.test(qml))
})

test("capped huge text still reports pinned in displayRows", () => {
  const huge = "x".repeat(H.displayTextLimit + 50)
  const rows = H.displayRows([{ type: "text", text: huge, pinned: true }], "", 50)
  assert.strictEqual(rows.length, 1)
  assert.strictEqual(rows[0].pinned, true)
  assert.ok(rows[0].fullText.length <= H.displayTextLimit)
})

test("displayRows floats pinned items without changing recency inside a group", () => {
  const rows = H.displayRows([
    { type: "text", text: "newest" },
    { type: "text", text: "pinned-old", pinned: true },
    { type: "text", text: "middle" },
    { type: "text", text: "pinned-new", pinned: true }
  ], "", 50)
  assert.deepStrictEqual(rows.map((r) => r.previewText), [
    "pinned-old",
    "pinned-new",
    "newest",
    "middle"
  ])
})

test("displayRows keeps unpinned recency by history index", () => {
  const items = []
  for (let i = 0; i < 12; i++) items.push({ type: "text", text: "u" + i })
  items[3].pinned = true
  const rows = H.displayRows(items, "", 50)
  assert.strictEqual(rows[0].previewText, "u3")
  assert.deepStrictEqual(
    rows.filter((r) => !r.pinned).map((r) => r.previewText),
    ["u0", "u1", "u2", "u4", "u5", "u6", "u7", "u8", "u9", "u10", "u11"]
  )
})

test("decodeFileUri handles file://localhost/ paths", () => {
  assert.strictEqual(H.decodeFileUri("file:///home/henri/a.txt"), "/home/henri/a.txt")
  assert.strictEqual(H.decodeFileUri("file://localhost/home/henri/a.txt"), "/home/henri/a.txt")
  assert.strictEqual(H.decodeFileUri("file://hostname/home/henri/a.txt"), "")
})

test("parseHistory ignores corrupt JSON and empty text", () => {
  assert.deepStrictEqual(H.parseHistory("nope"), [])
  assert.deepStrictEqual(H.parseHistory('[{"type":"text","text":"  "}]'), [])
  assert.strictEqual(H.parseHistory('[{"type":"text","text":"ok","pinned":true}]')[0].pinned, true)
})

test("Clipboard.qml forces plain text on every Text element", () => {
  const qml = fs.readFileSync(path.join(__dirname, "../Clipboard.qml"), "utf8")
  const texts = qml.match(/^\s*Text\s*\{/gm)
  const plains = qml.match(/^\s*textFormat:\s*Text\.PlainText\s*$/gm)
  assert.ok(texts && texts.length > 0)
  assert.strictEqual(texts.length, plains.length)
})

test("Clipboard.qml does not write history through FileView atomicWrites", () => {
  const qml = fs.readFileSync(path.join(__dirname, "../Clipboard.qml"), "utf8")
  assert.ok(qml.includes("save-history.sh"))
  assert.ok(qml.includes("atomicWrites: false"))
  assert.ok(!qml.includes("historyFile.setText"))
  assert.ok(!/atomicWrites:\s*true/.test(qml))
})

console.log("all tests passed")
