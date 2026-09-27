# Spike 0: how big is the Discord server?

Read-only. Measures messages and media size with DiscordChatExporter **without downloading any media**
(each attachment in the JSON export carries `fileSizeBytes`). Nothing on Discord or on the Oracle server is changed.

## Run (Windows PowerShell, from this folder)

```powershell
# 1. first run: download the exporter (win-x64, 11,448,499 bytes, size-verified) and start
.\sizing-run.ps1 -GuildId <SERVER_ID> -DownloadDce

# resume after an interruption (finished channels are skipped, failed ones retried)
.\sizing-run.ps1 -GuildId <SERVER_ID>

# rebuild the report from what is already collected (works while a run is in progress)
.\sizing-run.ps1 -GuildId <SERVER_ID> -ReportOnly

# dry run on the first 5 channels
.\sizing-run.ps1 -GuildId <SERVER_ID> -Limit 5
```

The token is read from `$env:DISCORD_TOKEN` or prompted for with hidden input. It is kept in memory for
that PowerShell process only; it is never written to disk or printed.

## Output (in `work\`, git-ignored)

* `sizing-summary.md`: verdict against the storage tiers, totals, media by year/type, top channels, largest files, estimates
* `sizing-channels.csv`, `sizing-years.csv`: the full tables
* `failures.tsv`: channels the token could not read (usually a permissions gap), with the reason
* `sizing.db`, `state.json`: resumable state

## Notes

* Disk use is about one 50,000-message partition at a time; each export is tallied and deleted.
* Progress: a live bar shows channels done, elapsed time, a rough ETA (channel sizes vary, so it firms up as the run goes), running message and media totals, and what the current channel is doing. A status line prints for each finished channel and every 60 s during a long one.
* Runtime is set by Discord's API rate limits; expect hours to days for a very large server. Keep the PC awake.
* Voice/stage/forum channels appear in the type table; forum posts are threads.
* Database size and backfill time in the report are **labelled assumptions**, replaced by measurements in the pilot.
