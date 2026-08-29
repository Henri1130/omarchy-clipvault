function normalizeEntry(value) {
  if (typeof value === "string")
    return value.trim().length > 0 ? { type: "text", text: value, pinned: false } : null

  if (!value || typeof value !== "object") return null

  var type = String(value.type || value.kind || "")
  if (type === "text") {
    var text = String(value.text || "")
    return text.trim().length > 0 ? { type: "text", text: text, pinned: !!value.pinned } : null
  }

  if (type === "image") {
    var path = String(value.path || "")
    if (!path) return null
    var entry = {
      type: "image",
      path: path,
      mime: String(value.mime || "image/png"),
      pinned: !!value.pinned
    }
    if (value.capturedAt !== undefined && value.capturedAt !== null)
      entry.capturedAt = String(value.capturedAt)
    return entry
  }

  return null
}

function entryKey(entry) {
  if (!entry) return ""
  if (entry.type === "image") return "image:" + String(entry.path || "")
  return "text:" + String(entry.text || "")
}

function parseHistory(raw) {
  try {
    var parsed = JSON.parse(String(raw || "[]"))
    var next = []
    if (!Array.isArray(parsed)) return next

    for (var i = 0; i < parsed.length; i++) {
      var entry = normalizeEntry(parsed[i])
      if (entry) next.push(entry)
    }
    return next
  } catch (e) {
    return []
  }
}

function addEntry(history, entry, limit) {
  var normalized = normalizeEntry(entry)
  var max = limit === undefined || limit === null ? 100 : Number(limit)
  if (isNaN(max)) max = 100
  max = Math.max(0, max)
  if (!normalized) return Array.isArray(history) ? history.slice(0, max) : []
  if (max === 0) return []

  var key = entryKey(normalized)
  var next = [normalized]
  var values = Array.isArray(history) ? history : []

  for (var i = 0; i < values.length; i++) {
    var existing = normalizeEntry(values[i])
    if (!existing) continue
    if (entryKey(existing) === key) {
      // Re-copying an already-pinned entry keeps its pin and floats to top.
      if (existing.pinned) normalized.pinned = true
      continue
    }
    next.push(existing)
  }

  // Drop oldest unpinned items first so pins survive a full history.
  while (next.length > max) {
    var dropped = false
    for (var j = next.length - 1; j >= 1; j--) {
      if (!next[j].pinned) {
        next.splice(j, 1)
        dropped = true
        break
      }
    }
    if (!dropped) next.pop()
  }

  return next
}

function removeEntryAt(history, index) {
  var values = Array.isArray(history) ? history : []
  var target = Number(index)
  if (isNaN(target) || target < 0 || target >= values.length) return values.slice()

  var next = values.slice()
  next.splice(target, 1)
  return next
}

function togglePinAt(history, index) {
  var values = Array.isArray(history) ? history : []
  var target = Number(index)
  if (isNaN(target) || target < 0 || target >= values.length) return values.slice()

  var entry = normalizeEntry(values[target])
  if (!entry) return values.slice()

  var next = values.slice()
  entry.pinned = !entry.pinned
  next[target] = entry
  return next
}

function clearHistory() {
  return []
}

// "Clear all" semantics: keep pinned entries, drop everything else.
function clearUnpinned(history) {
  var values = Array.isArray(history) ? history : []
  var next = []
  for (var i = 0; i < values.length; i++) {
    var e = normalizeEntry(values[i])
    if (e && e.pinned) next.push(e)
  }
  return next
}

function hasUnpinned(history) {
  var values = Array.isArray(history) ? history : []
  for (var i = 0; i < values.length; i++) {
    var e = normalizeEntry(values[i])
    if (e && !e.pinned) return true
  }
  return false
}

function parseEntryJson(line) {
  var raw = String(line || "").trim()
  if (!raw) return null
  try { return normalizeEntry(JSON.parse(raw)) } catch (e) { return null }
}

function searchableText(entry) {
  if (!entry) return ""
  if (entry.type === "image") return "image screenshot " + String(entry.mime || "") + " " + String(entry.capturedAt || "")
  return String(entry.text || "") + " " + fileEntryText(entry)
}

function decodeFileUri(uri) {
  var value = String(uri || "").trim()
  if (value.indexOf("file://") !== 0) return ""

  var path = value.substring(7)
  if (path.indexOf("localhost") === 0) path = path.substring("localhost".length)
  if (path.charAt(0) !== "/") return ""

  try { return decodeURIComponent(path) } catch (e) { return path }
}

function filePaths(entry) {
  if (!entry || entry.type !== "text") return []

  var lines = String(entry.text || "").split(/\r?\n/)
  var paths = []
  for (var i = 0; i < lines.length; i++) {
    var path = decodeFileUri(lines[i])
    if (path) paths.push(path)
  }
  return paths
}

function fileName(path) {
  var parts = String(path || "").split("/")
  return parts.length > 0 ? parts[parts.length - 1] : String(path || "")
}

function isImagePath(path) {
  return /\.(png|jpe?g|webp|gif|bmp|tiff?)$/i.test(String(path || ""))
}

function fileEntryText(entry) {
  var paths = filePaths(entry)
  if (paths.length === 0) return ""
  if (paths.length === 1) return fileName(paths[0])
  return paths.length + " files"
}

function imagePreviewText(entry) {
  var timestamp = String(entry && entry.capturedAt || "")
  if (!timestamp) return "Image"

  var label = String(entry && entry.mime || "") === "image/png" ? "Screenshot" : "Image"
  return label + " from " + timestamp
}

function previewText(entry) {
  if (!entry) return ""
  if (entry.type === "image") return imagePreviewText(entry)
  var fileText = fileEntryText(entry)
  if (fileText) return fileText
  return String(entry.text || "").replace(/\s+/g, " ")
}

function fullText(entry) {
  if (!entry) return ""
  var paths = filePaths(entry)
  if (paths.length > 0) return paths.join("\n")
  return String(entry.text || "")
}

// The picker only ever searches and renders a prefix of an entry, so scan and
// render just that much. A single huge paste otherwise costs hundreds of
// megabytes of string work on every keystroke and stalls the whole shell.
// Pasting reads the full entry back from history by index, so nothing is lost.
var displayTextLimit = 8192

function cappedEntry(entry) {
  if (!entry || entry.type !== "text" || entry.text.length <= displayTextLimit) return entry

  // Cut on a line break so a file:// URI never truncates into a bogus path.
  var cut = entry.text.lastIndexOf("\n", displayTextLimit)
  return {
    type: "text",
    text: entry.text.slice(0, cut > 0 ? cut : displayTextLimit),
    pinned: !!entry.pinned
  }
}

function displayRows(history, query, limit) {
  var values = Array.isArray(history) ? history : []
  var needle = String(query || "").trim().toLowerCase()
  var max = limit === undefined || limit === null ? 50 : Number(limit)
  if (isNaN(max)) max = 50
  max = Math.max(0, max)
  if (max === 0) return []

  var rows = []

  for (var i = 0; i < values.length; i++) {
    var entry = cappedEntry(normalizeEntry(values[i]))
    if (!entry) continue

    // Resolve file paths once and reuse for search, preview, and full text
    // instead of re-splitting every clipboard entry on each call.
    var paths = filePaths(entry)
    var isFile = paths.length > 0
    var isImage = entry.type === "image"

    if (needle) {
      var hay = isImage
        ? "image screenshot " + String(entry.mime || "") + " " + String(entry.capturedAt || "")
        : String(entry.text || "") + " " + (isFile
          ? (paths.length === 1 ? fileName(paths[0]) : paths.length + " files")
          : "")
      if (hay.toLowerCase().indexOf(needle) < 0) continue
    }

    var previewPath = isImage ? String(entry.path || "") : (isFile && paths.length === 1 && isImagePath(paths[0]) ? paths[0] : "")
    rows.push({
      entryType: isFile ? "file" : entry.type,
      fullText: isImage ? "" : (isFile ? paths.join("\n") : String(entry.text || "")),
      previewText: isImage ? imagePreviewText(entry)
        : (isFile ? (paths.length === 1 ? fileName(paths[0]) : paths.length + " files")
        : String(entry.text || "").replace(/\s+/g, " ")),
      previewImage: previewPath,
      path: isImage ? String(entry.path || "") : (isFile && paths.length === 1 ? paths[0] : ""),
      mime: isImage ? String(entry.mime || "image/png") : "text/plain",
      index: i,
      pinned: !!entry.pinned
    })
  }

  // Pinned entries float to the top (Windows 11 style). Sort by pin, then by
  // original history index so recency inside each group stays stable on engines
  // whose Array.sort is not stable.
  rows.sort(function (a, b) {
    if (a.pinned !== b.pinned) return a.pinned ? -1 : 1
    return a.index - b.index
  })

  if (rows.length > max) rows = rows.slice(0, max)
  return rows
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeEntry: normalizeEntry,
    entryKey: entryKey,
    parseHistory: parseHistory,
    addEntry: addEntry,
    removeEntryAt: removeEntryAt,
    togglePinAt: togglePinAt,
    clearHistory: clearHistory,
    clearUnpinned: clearUnpinned,
    hasUnpinned: hasUnpinned,
    parseEntryJson: parseEntryJson,
    searchableText: searchableText,
    previewText: previewText,
    imagePreviewText: imagePreviewText,
    decodeFileUri: decodeFileUri,
    filePaths: filePaths,
    fileEntryText: fileEntryText,
    fullText: fullText,
    displayRows: displayRows,
    displayTextLimit: displayTextLimit
  }
}
