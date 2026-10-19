#!/usr/bin/env node
"use strict"

// Mouse selection and paste hand-off (v1.4.x). Pure helpers live in
// ClipboardHistory.js; QML wiring is checked structurally like the other tests.

const assert = require("assert")
const fs = require("fs")
const path = require("path")
const H = require("../ClipboardHistory.js")

function test(name, fn) {
  fn()
  console.log("ok  " + name)
}

const qml = fs.readFileSync(path.join(__dirname, "../Clipboard.qml"), "utf8")

function block(source, marker) {
  const start = source.indexOf(marker)
  assert.ok(start >= 0, "missing " + marker)
  let depth = 0
  for (let i = source.indexOf("{", start); i < source.length; i++) {
    if (source[i] === "{") depth++
    else if (source[i] === "}" && --depth === 0) return source.slice(start, i + 1)
  }
  throw new Error("unbalanced " + marker)
}

test("pasteRequest returns the full original text, not the capped display text", () => {
  const big = "x".repeat(H.displayTextLimit + 500) + "\nend"
  const history = [{ type: "text", text: big, pinned: false }]
  const req = H.pasteRequest(history, 0)
  assert.deepStrictEqual(req, { kind: "text", text: big })
})

test("pasteRequest keeps file:// URIs for copied files", () => {
  const uris = "file:///home/user/a%20b.png\nfile:///home/user/c.txt"
  const req = H.pasteRequest([{ type: "text", text: uris }], 0)
  assert.strictEqual(req.text, uris)
})

test("pasteRequest returns mime and path for images", () => {
  const req = H.pasteRequest([{ type: "image", path: "/tmp/i.png", mime: "image/png" }], 0)
  assert.deepStrictEqual(req, { kind: "image", mime: "image/png", path: "/tmp/i.png" })
})

test("pasteRequest rejects bad indexes and empty text", () => {
  assert.strictEqual(H.pasteRequest([], 0), null)
  assert.strictEqual(H.pasteRequest([{ type: "text", text: "a" }], 1), null)
  assert.strictEqual(H.pasteRequest([{ type: "text", text: "a" }], -1), null)
  assert.strictEqual(H.pasteRequest([{ type: "text", text: "a" }], "nope"), null)
  assert.strictEqual(H.pasteRequest([{ type: "text", text: "   " }], 0), null)
})

test("normalizeWindowAddress accepts Hyprland hex addresses only", () => {
  assert.strictEqual(H.normalizeWindowAddress("593bd871e490"), "0x593bd871e490")
  assert.strictEqual(H.normalizeWindowAddress("0x593bd871e490"), "0x593bd871e490")
  assert.strictEqual(H.normalizeWindowAddress(""), "")
  assert.strictEqual(H.normalizeWindowAddress(null), "")
  assert.strictEqual(H.normalizeWindowAddress('0x1" }) os.exit() --'), "")
  assert.strictEqual(H.normalizeWindowAddress("address:0x12"), "")
})

test("historyIndexAfterRemoval shifts only later entries", () => {
  assert.strictEqual(H.historyIndexAfterRemoval(5, 3), 4)
  assert.strictEqual(H.historyIndexAfterRemoval(2, 3), 2)
  assert.strictEqual(H.historyIndexAfterRemoval(3, 3), -1)
})

test("row click cannot be stolen by the list", () => {
  const row = block(qml, "id: rowClick")
  assert.ok(/preventStealing:\s*true/.test(row))
})

test("list keeps native Qt wheel/touchpad scrolling", () => {
  const list = block(qml, "ListView {")
  assert.ok(!/interactive:\s*false/.test(list))
  assert.ok(!/WheelHandler\s*\{/.test(list))
})

test("paste goes through the plugin helper with exact text, not a history index", () => {
  assert.ok(qml.includes("paste.sh"))
  assert.ok(!qml.includes("omarchy-clipboard-paste-text"))
  assert.ok(!qml.includes("omarchy-clipboard-paste-file"))
  assert.ok(qml.includes("pasteRequest"))
  assert.ok(qml.includes("--window"))
})

test("overlay remembers the focused window via Quickshell.Hyprland", () => {
  assert.ok(/^import Quickshell\.Hyprland$/m.test(qml))
  assert.ok(qml.includes("Hyprland.activeToplevel"))
  assert.ok(qml.includes("normalizeWindowAddress"))
})

test("pin and delete update rows in place instead of rebuilding", () => {
  const pin = block(qml, "function togglePinHistory")
  assert.ok(!pin.includes("rebuildDisplay"))
  assert.ok(pin.includes("setProperty"))
  const del = block(qml, "function removeDisplayIndex")
  assert.ok(!del.includes("rebuildDisplay"))
  assert.ok(del.includes("displayModel.remove"))
  assert.ok(del.includes("historyIndexAfterRemoval"))
})

test("theme colors use Commons.Color (Qt 6.12 QtQuick exports its own Color)", () => {
  assert.ok(/^import qs\.Commons as Commons$/m.test(qml))
  assert.ok(!/[^.\w]Color\.menu\./.test(qml))
})

test("history FileView never chmods from its own change handlers (inotify ATTRIB loop)", () => {
  const fv = block(qml, "FileView {")
  assert.ok(!fv.includes("lockHistoryPermissions"))
  assert.ok(!fv.includes("chmod"))
})

test("loadHistory ignores reloads whose content did not change", () => {
  const fn = block(qml, "function loadHistory")
  assert.ok(fn.includes("lastLoadedRaw"))
})

test("header search is a real TextInput bound to the filter", () => {
  const input = block(qml, "TextInput {")
  assert.ok(input.includes("id: searchInput"))
  assert.ok(/^\s*TextInput\s*\{\s*$/m.test(qml))
  assert.ok(input.includes("root.setFilter(text)") || input.includes("root.setFilter(searchInput.text)"))
  assert.ok(input.includes("root.handleKey(event"))
  assert.ok(input.includes("selectByMouse: true"))
  assert.ok(qml.includes("Search clipboard"))
})

test("search input gets focus on open and after dialogs/actions", () => {
  assert.ok(!qml.includes("keyCatcher.forceActiveFocus()"))
  assert.ok((qml.match(/root\.focusSearch\(\)/g) || []).length >= 3)
  assert.ok(block(qml, "function focusSearch").includes("searchInput.forceActiveFocus()"))
})

console.log("all mouse/paste tests passed")
