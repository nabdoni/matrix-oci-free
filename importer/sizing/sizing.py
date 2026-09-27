#!/usr/bin/env python3
"""sizing.py - tally a Discord server's size from DiscordChatExporter JSON exports.

Read-only measurement for the buncha migration (Spike 0). It never downloads media:
each attachment in a DCE JSON export carries `fileSizeBytes`, so the size of the whole
media archive is known from the metadata alone.

Subcommands (driven by sizing-run.ps1, but usable by hand):
  begin  --db DB --id ID [--name N --kind K --parent P]   forget any partial data for a channel
  ingest --db DB --file EXPORT.json                       add one DCE JSON file (a partition)
  finish --db DB --id ID                                  mark the channel complete
  report --db DB --out DIR                                write CSVs + sizing-summary.md

All state lives in one SQLite file, so runs are resumable and idempotent per channel.
"""
import argparse
import csv
import json
import os
import sqlite3
import sys
from collections import defaultdict

# --- assumptions used ONLY for labelled estimates in the report ---------------------------
B2_PRICE_PER_GB_MONTH = 0.00695      # Backblaze B2, $6.95/TB-month (decimal TB)
B2_FREE_GB = 10                      # first 10 GB free
ORACLE_FREE_MEDIA_GB = 120           # media that comfortably fits the free block volume
BUDGET_MONTHLY = 10.0                # user's stated ceiling
DB_BYTES_PER_MESSAGE = (1500, 4000)  # ASSUMPTION, replaced by pilot measurement
BACKFILL_RATES_PER_MIN = (10, 60, 300, 1000)  # sensitivity table, not a prediction

TYPE_BY_EXT = {}
for _cls, _exts in {
    "image": "png jpg jpeg gif webp bmp tif tiff heic heif avif svg ico",
    "video": "mp4 mov webm mkv avi wmv flv m4v mpg mpeg 3gp",
    "audio": "mp3 wav ogg oga flac m4a aac opus wma",
    "archive": "zip rar 7z tar gz bz2 xz",
    "document": "pdf doc docx xls xlsx ppt pptx txt rtf odt csv md json log",
}.items():
    for _e in _exts.split():
        TYPE_BY_EXT[_e] = _cls

SCHEMA = """
CREATE TABLE IF NOT EXISTS channels(
  id TEXT PRIMARY KEY, name TEXT, kind TEXT, parent TEXT, done INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS chan_year(
  channel_id TEXT, year INTEGER,
  messages INTEGER DEFAULT 0, system_messages INTEGER DEFAULT 0,
  msgs_with_attach INTEGER DEFAULT 0, attach_count INTEGER DEFAULT 0, attach_bytes INTEGER DEFAULT 0,
  fwd_attach_count INTEGER DEFAULT 0, fwd_attach_bytes INTEGER DEFAULT 0,
  embeds INTEGER DEFAULT 0, stickers INTEGER DEFAULT 0, reactions INTEGER DEFAULT 0,
  replies INTEGER DEFAULT 0, pinned INTEGER DEFAULT 0, edited INTEGER DEFAULT 0,
  text_bytes INTEGER DEFAULT 0, max_attach INTEGER DEFAULT 0,
  first_ts TEXT, last_ts TEXT,
  PRIMARY KEY(channel_id, year));
CREATE TABLE IF NOT EXISTS type_year(
  channel_id TEXT, year INTEGER, cls TEXT, files INTEGER DEFAULT 0, bytes INTEGER DEFAULT 0,
  PRIMARY KEY(channel_id, year, cls));
CREATE TABLE IF NOT EXISTS authors(
  channel_id TEXT, author_id TEXT, name TEXT, is_bot INTEGER, messages INTEGER DEFAULT 0,
  PRIMARY KEY(channel_id, author_id));
CREATE TABLE IF NOT EXISTS big_files(
  channel_id TEXT, message_id TEXT, file_name TEXT, bytes INTEGER,
  PRIMARY KEY(channel_id, message_id, file_name));
CREATE TABLE IF NOT EXISTS msg_types(
  channel_id TEXT, type TEXT, n INTEGER DEFAULT 0, PRIMARY KEY(channel_id, type));
"""

# Message types that are real user content; everything else is a system notification.
CONTENT_TYPES = {"Default", "Reply", "ForwardedMessage"}


def connect(path):
    con = sqlite3.connect(path)
    con.executescript(SCHEMA)
    return con


def ext_class(name):
    ext = os.path.splitext(name or "")[1].lower().lstrip(".")
    return TYPE_BY_EXT.get(ext, "other")


def cmd_begin(a):
    con = connect(a.db)
    for t in ("chan_year", "type_year", "authors", "big_files", "msg_types"):
        con.execute(f"DELETE FROM {t} WHERE channel_id=?", (a.id,))
    con.execute(
        "INSERT INTO channels(id,name,kind,parent,done) VALUES(?,?,?,?,0) "
        "ON CONFLICT(id) DO UPDATE SET name=excluded.name, kind=excluded.kind, parent=excluded.parent, done=0",
        (a.id, a.name, a.kind, a.parent))
    con.commit()


def cmd_finish(a):
    con = connect(a.db)
    con.execute("UPDATE channels SET done=1 WHERE id=?", (a.id,))
    con.commit()


def cmd_ingest(a):
    with open(a.file, "r", encoding="utf-8") as fh:
        doc = json.load(fh)
    ch = doc.get("channel", {})
    cid = str(ch.get("id"))
    con = connect(a.db)
    # Record real channel metadata the exporter knows (type, name, parent) if we lack it.
    con.execute(
        "INSERT INTO channels(id,name,kind,parent,done) VALUES(?,?,?,?,0) "
        "ON CONFLICT(id) DO UPDATE SET kind=COALESCE(excluded.kind, channels.kind), "
        "name=COALESCE(excluded.name, channels.name), parent=COALESCE(excluded.parent, channels.parent)",
        (cid, ch.get("name"), ch.get("type"), ch.get("category")))

    years = defaultdict(lambda: defaultdict(int))
    firsts, lasts = {}, {}
    types = defaultdict(lambda: defaultdict(lambda: [0, 0]))
    authors = {}
    types_seen = defaultdict(int)
    bigs = []

    for m in doc.get("messages", []):
        ts = m.get("timestamp") or ""
        try:
            y = int(ts[:4])
        except ValueError:
            y = 0
        mtype = m.get("type", "Default")
        types_seen[mtype] += 1
        d = years[y]
        if mtype in CONTENT_TYPES:
            d["messages"] += 1
        else:
            d["system_messages"] += 1
        atts = m.get("attachments") or []
        if atts:
            d["msgs_with_attach"] += 1
        for att in atts:
            size = int(att.get("fileSizeBytes") or 0)
            d["attach_count"] += 1
            d["attach_bytes"] += size
            d["max_attach"] = max(d["max_attach"], size)
            cls = ext_class(att.get("fileName"))
            types[y][cls][0] += 1
            types[y][cls][1] += size
            bigs.append((cid, str(m.get("id")), att.get("fileName") or "", size))
        fwd = m.get("forwardedMessage") or {}
        for att in fwd.get("attachments") or []:
            d["fwd_attach_count"] += 1
            d["fwd_attach_bytes"] += int(att.get("fileSizeBytes") or 0)
        d["embeds"] += len(m.get("embeds") or [])
        d["stickers"] += len(m.get("stickers") or [])
        d["reactions"] += sum(int(r.get("count") or 0) for r in (m.get("reactions") or []))
        if m.get("reference"):
            d["replies"] += 1
        if m.get("isPinned"):
            d["pinned"] += 1
        if m.get("timestampEdited"):
            d["edited"] += 1
        d["text_bytes"] += len((m.get("content") or "").encode("utf-8"))
        if ts:
            if y not in firsts or ts < firsts[y]:
                firsts[y] = ts
            if y not in lasts or ts > lasts[y]:
                lasts[y] = ts
        au = m.get("author") or {}
        aid = str(au.get("id"))
        cur = authors.setdefault(aid, [au.get("name"), 1 if au.get("isBot") else 0, 0])
        cur[2] += 1

    cols = ["messages", "system_messages", "msgs_with_attach", "attach_count", "attach_bytes",
            "fwd_attach_count", "fwd_attach_bytes", "embeds", "stickers", "reactions",
            "replies", "pinned", "edited", "text_bytes"]
    for y, d in years.items():
        con.execute("INSERT OR IGNORE INTO chan_year(channel_id, year) VALUES(?,?)", (cid, y))
        sets = ", ".join(f"{c}={c}+?" for c in cols)
        con.execute(f"UPDATE chan_year SET {sets}, max_attach=MAX(max_attach, ?), "
                    "first_ts=CASE WHEN first_ts IS NULL OR ? < first_ts THEN ? ELSE first_ts END, "
                    "last_ts=CASE WHEN last_ts IS NULL OR ? > last_ts THEN ? ELSE last_ts END "
                    "WHERE channel_id=? AND year=?",
                    [d[c] for c in cols] + [d["max_attach"], firsts.get(y), firsts.get(y),
                                            lasts.get(y), lasts.get(y), cid, y])
    for y, byc in types.items():
        for cls, (files, size) in byc.items():
            con.execute("INSERT OR IGNORE INTO type_year(channel_id, year, cls) VALUES(?,?,?)", (cid, y, cls))
            con.execute("UPDATE type_year SET files=files+?, bytes=bytes+? WHERE channel_id=? AND year=? AND cls=?",
                        (files, size, cid, y, cls))
    for aid, (name, is_bot, n) in authors.items():
        con.execute("INSERT OR IGNORE INTO authors(channel_id, author_id, name, is_bot) VALUES(?,?,?,?)",
                    (cid, aid, name, is_bot))
        con.execute("UPDATE authors SET messages=messages+? WHERE channel_id=? AND author_id=?", (n, cid, aid))
    for t, n in types_seen.items():
        con.execute("INSERT OR IGNORE INTO msg_types(channel_id, type) VALUES(?,?)", (cid, t))
        con.execute("UPDATE msg_types SET n=n+? WHERE channel_id=? AND type=?", (n, cid, t))
    # keep only the 50 biggest files per channel to bound the table
    bigs.sort(key=lambda r: -r[3])
    for r in bigs[:50]:
        con.execute("INSERT OR REPLACE INTO big_files VALUES(?,?,?,?)", r)
    con.execute("DELETE FROM big_files WHERE channel_id=? AND rowid NOT IN "
                "(SELECT rowid FROM big_files WHERE channel_id=? ORDER BY bytes DESC LIMIT 50)", (cid, cid))
    con.commit()
    print(f"ingested {a.file}: channel {cid}, {sum(v['messages'] + v['system_messages'] for v in years.values())} messages")


def cmd_stats(a):
    """One JSON line of running totals, used by the driver's progress display."""
    con = connect(a.db)
    m, s, b = con.execute(
        "SELECT COALESCE(SUM(messages),0), COALESCE(SUM(system_messages),0), "
        "COALESCE(SUM(attach_bytes + fwd_attach_bytes),0) FROM chan_year").fetchone()
    done = con.execute("SELECT COUNT(*) FROM channels WHERE done=1").fetchone()[0]
    print(json.dumps({"messages": m, "system_messages": s, "media_bytes": b, "channels_done": done}))


def gb(n):
    return n / 1e9


def fmt_gb(n):
    return f"{gb(n):,.2f} GB"


def cost_b2(total_gb):
    return max(0.0, total_gb - B2_FREE_GB) * B2_PRICE_PER_GB_MONTH


def cmd_report(a):
    con = connect(a.db)
    os.makedirs(a.out, exist_ok=True)
    q = con.execute

    chan_rows = q("""
        SELECT c.id, COALESCE(c.name,''), COALESCE(c.kind,''), COALESCE(c.parent,''), c.done,
               COALESCE(SUM(y.messages),0), COALESCE(SUM(y.system_messages),0),
               COALESCE(SUM(y.msgs_with_attach),0), COALESCE(SUM(y.attach_count),0),
               COALESCE(SUM(y.attach_bytes),0), COALESCE(SUM(y.fwd_attach_bytes),0),
               COALESCE(SUM(y.embeds),0), COALESCE(SUM(y.stickers),0), COALESCE(SUM(y.reactions),0),
               COALESCE(SUM(y.replies),0), COALESCE(SUM(y.pinned),0), COALESCE(SUM(y.text_bytes),0),
               COALESCE(MAX(y.max_attach),0), MIN(y.first_ts), MAX(y.last_ts),
               (SELECT COUNT(*) FROM authors a WHERE a.channel_id=c.id)
        FROM channels c LEFT JOIN chan_year y ON y.channel_id=c.id
        GROUP BY c.id ORDER BY 6 DESC""").fetchall()
    with open(os.path.join(a.out, "sizing-channels.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["channel_id", "name", "type", "parent", "complete", "messages", "system_messages",
                    "msgs_with_attachments", "attachments", "attachment_bytes", "forwarded_attachment_bytes",
                    "embeds", "stickers", "reactions", "replies", "pinned", "text_bytes",
                    "largest_attachment_bytes", "first_message", "last_message", "distinct_authors"])
        w.writerows(chan_rows)

    year_rows = q("""
        SELECT year, SUM(messages), SUM(system_messages), SUM(msgs_with_attach), SUM(attach_count),
               SUM(attach_bytes), SUM(fwd_attach_bytes), SUM(embeds), SUM(stickers), SUM(reactions),
               SUM(replies), SUM(text_bytes), MAX(max_attach)
        FROM chan_year GROUP BY year ORDER BY year""").fetchall()
    with open(os.path.join(a.out, "sizing-years.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["year", "messages", "system_messages", "msgs_with_attachments", "attachments",
                    "attachment_bytes", "forwarded_attachment_bytes", "embeds", "stickers", "reactions",
                    "replies", "text_bytes", "largest_attachment_bytes"])
        w.writerows(year_rows)

    tot = q("""SELECT COALESCE(SUM(messages),0), COALESCE(SUM(system_messages),0), COALESCE(SUM(attach_count),0),
                      COALESCE(SUM(attach_bytes),0), COALESCE(SUM(fwd_attach_bytes),0), COALESCE(SUM(text_bytes),0),
                      COALESCE(SUM(embeds),0), COALESCE(SUM(stickers),0), COALESCE(SUM(replies),0),
                      COALESCE(SUM(pinned),0), MIN(first_ts), MAX(last_ts), COALESCE(MAX(max_attach),0)
               FROM chan_year""").fetchone()
    (msgs, sysmsgs, att_n, att_b, fwd_b, text_b, embeds, stickers, replies, pinned, first_ts, last_ts, max_att) = tot
    n_chan = q("SELECT COUNT(*) FROM channels").fetchone()[0]
    n_done = q("SELECT COUNT(*) FROM channels WHERE done=1").fetchone()[0]
    n_threads = q("SELECT COUNT(*) FROM channels WHERE kind LIKE '%Thread%'").fetchone()[0]
    kinds = q("SELECT COALESCE(kind,'?'), COUNT(*) FROM channels GROUP BY kind ORDER BY 2 DESC").fetchall()
    authors = q("SELECT COUNT(DISTINCT author_id), COUNT(DISTINCT CASE WHEN is_bot=1 THEN author_id END) FROM authors").fetchone()
    top_authors = q("SELECT name, SUM(messages) m FROM authors GROUP BY author_id ORDER BY m DESC LIMIT 10").fetchall()
    by_cls = q("SELECT cls, SUM(files), SUM(bytes) FROM type_year GROUP BY cls ORDER BY 3 DESC").fetchall()
    big = q("SELECT channel_id, file_name, bytes FROM big_files ORDER BY bytes DESC LIMIT 20").fetchall()
    names = {r[0]: r[1] for r in chan_rows}

    media_b = att_b + fwd_b
    media_gb = gb(media_b)
    b2 = cost_b2(media_gb)
    if media_gb <= ORACLE_FREE_MEDIA_GB:
        verdict = (f"**FITS FREE TIER.** {media_gb:,.1f} GB of media fits the ~150 GB spare Oracle block volume "
                   f"(with headroom for the database). Cost: $0.")
    elif b2 <= BUDGET_MONTHLY:
        verdict = (f"**BACKBLAZE B2 OFFLOAD.** {media_gb:,.1f} GB of media costs about ${b2:,.2f}/month on B2 "
                   f"(first {B2_FREE_GB} GB free) - inside the ${BUDGET_MONTHLY:.0f}/month budget.")
    else:
        cap_gb = B2_FREE_GB + BUDGET_MONTHLY / B2_PRICE_PER_GB_MONTH
        verdict = (f"**OVER BUDGET.** {media_gb:,.1f} GB of media would cost about ${b2:,.2f}/month on B2; the "
                   f"${BUDGET_MONTHLY:.0f}/month budget covers about {cap_gb:,.0f} GB. A policy cut is needed "
                   f"(per-file cap, drop large videos, or a cutoff year) - see the per-year and largest-file tables.")

    L = []
    ap = L.append
    ap("# Discord server sizing (Spike 0)\n")
    ap(f"_{n_done} of {n_chan} channels/threads complete._" + (
        "" if n_done == n_chan else " **Partial: totals will grow until every channel is complete.**") + "\n")
    ap("_Only channels the token can see are counted. Compare the channel count below with the server's real "
       "channel list; a channel the bot cannot see is silently absent, not reported as a failure._\n")
    ap("## Verdict\n")
    ap(verdict + "\n")
    ap("## Totals\n")
    ap("| Metric | Value |\n|---|---|")
    ap(f"| Messages (user content) | {msgs:,} |")
    ap(f"| System notifications (joins, pins, etc.) | {sysmsgs:,} |")
    ap(f"| Date range | {(first_ts or '')[:10]} to {(last_ts or '')[:10]} |")
    ap(f"| Attachments | {att_n:,} |")
    ap(f"| Attachment bytes | {fmt_gb(att_b)} |")
    ap(f"| Forwarded-message attachment bytes (may duplicate originals) | {fmt_gb(fwd_b)} |")
    ap(f"| Largest single attachment | {max_att / 1e6:,.1f} MB |")
    ap(f"| Message text (raw) | {fmt_gb(text_b)} |")
    ap(f"| Embeds / stickers / replies / pinned | {embeds:,} / {stickers:,} / {replies:,} / {pinned:,} |")
    ap(f"| Channels + threads counted | {n_chan:,} (threads: {n_threads:,}) |")
    ap(f"| Distinct authors (= ghost users to expect) | {authors[0]:,} (bots/webhooks: {authors[1]:,}) |")
    ap("")
    ap("## Media by year\n")
    ap("| Year | Messages | Attachments | Media | Largest file |\n|---|---:|---:|---:|---:|")
    for r in year_rows:
        ap(f"| {r[0]} | {r[1]:,} | {r[4]:,} | {fmt_gb(r[5] + r[6])} | {r[12] / 1e6:,.1f} MB |")
    ap("")
    ap("## Media by type\n")
    ap("| Type | Files | Size |\n|---|---:|---:|")
    for cls, files, size in by_cls:
        ap(f"| {cls} | {files:,} | {fmt_gb(size)} |")
    ap("")
    ap("## Top 20 channels by messages\n")
    ap("| Channel | Type | Messages | Media |\n|---|---|---:|---:|")
    for r in chan_rows[:20]:
        ap(f"| {r[1] or r[0]} | {r[2]} | {r[5]:,} | {fmt_gb(r[9] + r[10])} |")
    ap("")
    ap("## Top 20 channels by media\n")
    ap("| Channel | Type | Messages | Media |\n|---|---|---:|---:|")
    for r in sorted(chan_rows, key=lambda r: -(r[9] + r[10]))[:20]:
        ap(f"| {r[1] or r[0]} | {r[2]} | {r[5]:,} | {fmt_gb(r[9] + r[10])} |")
    ap("")
    ap("## 20 largest files\n")
    ap("| File | Channel | Size |\n|---|---|---:|")
    for cid, fname, size in big:
        ap(f"| {fname} | {names.get(cid) or cid} | {size / 1e6:,.1f} MB |")
    ap("")
    ap("## Channel/thread types (what the bridge can and cannot carry)\n")
    ap("| Type | Count |\n|---|---:|")
    for k, n in kinds:
        ap(f"| {k} | {n:,} |")
    ap("")
    ap("Voice, stage and forum channels are not bridged as such; forum posts are threads.\n")
    ap("## Estimates (assumptions, NOT measurements)\n")
    lo, hi = DB_BYTES_PER_MESSAGE
    ap(f"* **Database size**: {msgs:,} messages x {lo:,}-{hi:,} bytes = about "
       f"{msgs * lo / 1e9:,.1f}-{msgs * hi / 1e9:,.1f} GB. The per-message range is a placeholder; the pilot replaces it "
       f"with a measured number. Oracle's spare block volume is about 150 GB.")
    ap("* **Backfill duration** (the bridge sends one message at a time on Synapse); sensitivity, not a prediction:\n")
    ap("| Messages per minute | Days for all messages |\n|---:|---:|")
    for rate in BACKFILL_RATES_PER_MIN:
        ap(f"| {rate:,} | {msgs / rate / 60 / 24:,.1f} |")
    ap("")
    ap("## Media cost table (Backblaze B2, $6.95/TB-month, first 10 GB free)\n")
    ap("| Media kept | Monthly cost |\n|---:|---:|")
    for keep in sorted({round(media_gb * f, 1) for f in (0.25, 0.5, 0.75, 1.0)}):
        ap(f"| {keep:,.1f} GB | ${cost_b2(keep):,.2f} |")
    ap("")
    with open(os.path.join(a.out, "sizing-summary.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))
    print(f"report written to {a.out} ({n_done}/{n_chan} complete, {msgs:,} messages, {media_gb:,.1f} GB media)")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("begin"); b.add_argument("--db", required=True); b.add_argument("--id", required=True)
    b.add_argument("--name", default=None); b.add_argument("--kind", default=None); b.add_argument("--parent", default=None)
    b.set_defaults(fn=cmd_begin)
    i = sub.add_parser("ingest"); i.add_argument("--db", required=True); i.add_argument("--file", required=True)
    i.set_defaults(fn=cmd_ingest)
    f = sub.add_parser("finish"); f.add_argument("--db", required=True); f.add_argument("--id", required=True)
    f.set_defaults(fn=cmd_finish)
    r = sub.add_parser("report"); r.add_argument("--db", required=True); r.add_argument("--out", required=True)
    r.set_defaults(fn=cmd_report)
    s = sub.add_parser("stats"); s.add_argument("--db", required=True)
    s.set_defaults(fn=cmd_stats)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
