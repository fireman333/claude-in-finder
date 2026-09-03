import Foundation

/// Renders a session into a self-contained HTML document.
///
/// The file is given our own UTI (com.klaude.claude-session, extension
/// .claudesession) which *conforms to public.html*. That single decision buys
/// two things at once: Finder/Quick Look previews it with the built-in
/// Web.qlgenerator, while LaunchServices still routes double-clicks to our app
/// because our UTI is the more specific declared type.
enum Render {

    static let maxMessages = 300
    static let maxCharsPerMessage = 4000

    static func html(for session: Session, transcript: URL?) -> String {
        render(for: session, transcript: transcript).html
    }

    /// Also reports whether the transcript could actually be read.
    ///
    /// A transcript that is only a placeholder in iCloud, or that the read gave
    /// up waiting on, renders as an empty conversation. That is the right thing
    /// to show, but the wrong thing to *remember*: a caller that caches this
    /// preview would keep serving the empty one until the file's size or date
    /// happened to change.
    static func render(for session: Session, transcript: URL?) -> (html: String, complete: Bool) {
        let parsed = transcript.flatMap { parse(jsonl: $0) }
        let complete = transcript == nil || parsed != nil
        let all = parsed ?? []
        // Keep the tail: the end of a conversation is what you need to recognise
        // it. Say so when there is a head to keep, though — a preview that opens
        // mid-conversation and does not admit it reads as a corrupted file.
        let dropped = max(0, all.count - maxMessages)
        let messages = dropped > 0 ? Array(all.suffix(maxMessages)) : all
        let notice = dropped == 0 ? "" : """
        <p class="truncated">\(dropped) earlier message\(dropped == 1 ? "" : "s") \
        not shown — this preview keeps the last \(maxMessages). Open the session \
        to read the whole conversation.</p>
        """
        let body = messages.isEmpty
            ? "<p class=\"empty\">No messages to show — the transcript may have been removed.</p>"
            : notice + messages.map(renderMessage).joined()

        let meta = """
        <meta charset="utf-8">
        <meta name="claude-session" content="\(esc(session.cliSessionID ?? ""))">
        <meta name="claude-desktop-id" content="\(esc(session.desktopID))">
        <meta name="claude-cwd" content="\(esc(session.cwd))">
        <meta name="claude-title" content="\(esc(session.title))">
        """

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let when = session.lastActivityAt.map { df.string(from: $0) } ?? "—"
        let folder = (session.cwd as NSString).lastPathComponent

        let openable = session.cliSessionID != nil
        let hint = openable
            ? "Double-click to reopen this conversation in Claude Code desktop"
            : "This session has no CLI transcript id and cannot be reopened by deep link"

        let page = """
        <!doctype html>
        <html lang="en">
        <head>
        \(meta)
        <title>\(esc(session.title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <header>
          <h1>\(esc(session.title))</h1>
          <div class="meta">
            <span>\(esc(folder))</span><span>·</span>
            <span>\(esc(when))</span>
            \(session.model.map { "<span>·</span><span>\(esc($0))</span>" } ?? "")
          </div>
          <div class="hint">\(hint)</div>
        </header>
        <main>\(body)</main>
        </body>
        </html>
        """
        return (page, complete)
    }

    // MARK: - Transcript parsing

    struct Message {
        let role: String
        let text: String
        let tools: [String]
    }

    /// Returns nil when the file could not be read at all, which a caller needs
    /// to tell apart from a conversation that is genuinely empty.
    static func parse(jsonl: URL) -> [Message]? {
        // Transcripts can be large and, on iCloud, not actually present yet.
        guard let bytes = TimeLimited.data(at: jsonl, seconds: 5) else { return nil }
        var out: [Message] = []

        // Split on newline bytes rather than on a String. Swift's String is a
        // sequence of grapheme clusters, so splitting one costs a full Unicode
        // segmentation pass over every character in the file — on a transcript
        // of any size that dwarfs the JSON parsing it exists to feed, and the
        // lines are handed to JSONSerialization as bytes anyway.
        let newline = UInt8(ascii: "\n")
        var start = bytes.startIndex

        while start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: newline) ?? bytes.endIndex
            defer { start = end < bytes.endIndex ? bytes.index(after: end) : bytes.endIndex }
            guard end > start else { continue }

            // Every line leaves autoreleased Foundation objects behind, and nothing
            // drains them until the whole pass ends. Over tens of thousands of lines
            // and then hundreds of sessions that is the difference between an agent
            // that holds 30 MB and one that holds three gigabytes.
            let parsed: (role: String, text: String, tools: [String])? = autoreleasepool {
                guard let obj = try? JSONSerialization.jsonObject(with: bytes[start..<end])
                            as? [String: Any],
                      let type = obj["type"] as? String, type == "user" || type == "assistant",
                      // Sidechain entries are subagent chatter, not the conversation.
                      obj["isSidechain"] as? Bool != true,
                      let message = obj["message"] as? [String: Any]
                else { return nil }

                var text = ""
                var tools: [String] = []

                if let s = message["content"] as? String {
                    text = s
                } else if let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks {
                        switch block["type"] as? String {
                        case "text":
                            if let t = block["text"] as? String { text += t }
                        case "tool_use":
                            if let n = block["name"] as? String { tools.append(n) }
                        default:
                            continue   // thinking, tool_result, images: not shown
                        }
                    }
                }

                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty && tools.isEmpty { return nil }
                // Skip the synthetic system reminders injected into user turns.
                if text.hasPrefix("<system-reminder>") { return nil }
                return (type, text, tools)
            }
            guard let parsed else { continue }

            // A single assistant turn arrives as several lines (text, then one per
            // tool call). Coalesce runs of the same role so the preview reads as a
            // conversation rather than as a log of individual blocks.
            if let last = out.last, last.role == parsed.role {
                let joined = [last.text, parsed.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                out[out.count - 1] = Message(role: parsed.role, text: joined,
                                             tools: last.tools + parsed.tools)
            } else {
                out.append(Message(role: parsed.role, text: parsed.text, tools: parsed.tools))
            }
        }

        return out
    }

    private static func renderMessage(_ m: Message) -> String {
        var text = m.text
        if text.count > maxCharsPerMessage {
            text = String(text.prefix(maxCharsPerMessage)) + "…"
        }
        var seen = Set<String>()
        let uniqueTools = m.tools.filter { seen.insert($0).inserted }
        let toolHTML = uniqueTools.isEmpty ? "" :
            "<div class=\"tools\">" + uniqueTools.map { "<code>\(esc($0))</code>" }.joined() + "</div>"
        let bodyHTML = text.isEmpty ? "" : "<div class=\"text\">\(esc(text))</div>"
        let label = m.role == "user" ? "You" : "Claude"
        return """
        <article class="msg \(m.role)">
          <div class="role">\(label)</div>
          \(bodyHTML)\(toolHTML)
        </article>
        """
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
    :root { color-scheme: light dark; --bg:#fff; --fg:#1d1d1f; --dim:#6e6e73;
            --line:#e5e5e7; --user:#f2f2f7; --accent:#c96442; }
    @media (prefers-color-scheme: dark) {
      :root { --bg:#1c1c1e; --fg:#f2f2f7; --dim:#98989d; --line:#38383a; --user:#2c2c2e; }
    }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--bg); color:var(--fg);
           font: 14px/1.6 -apple-system, "PingFang TC", sans-serif; }
    header { padding:20px 24px 14px; border-bottom:1px solid var(--line); }
    h1 { margin:0 0 6px; font-size:19px; font-weight:600; }
    .meta { color:var(--dim); font-size:12px; display:flex; gap:6px; flex-wrap:wrap; }
    .hint { margin-top:8px; font-size:12px; color:var(--accent); }
    main { padding:16px 24px 40px; }
    .msg { padding:12px 14px; margin:0 0 10px; border-radius:10px; }
    .msg.user { background:var(--user); }
    .msg.assistant { border:1px solid var(--line); }
    .role { font-size:11px; font-weight:600; color:var(--dim);
            text-transform:uppercase; letter-spacing:.04em; margin-bottom:6px; }
    .text { white-space:pre-wrap; word-break:break-word; }
    .tools { margin-top:8px; display:flex; gap:6px; flex-wrap:wrap; }
    .tools code { font-size:11px; padding:2px 7px; border-radius:5px;
                  background:var(--line); color:var(--dim); }
    .empty { color:var(--dim); }
    .truncated { margin:0 0 14px; padding:9px 12px; border-radius:8px; font-size:12px;
                 color:var(--dim); background:var(--user); border:1px solid var(--line); }
    """
}
