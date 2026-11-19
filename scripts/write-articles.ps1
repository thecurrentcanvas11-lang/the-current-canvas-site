# Writes ONE new original article per run with the Claude API and publishes it to generated.js.
#
#   powershell -ExecutionPolicy Bypass -File scripts\write-articles.ps1            (normal run)
#   powershell -ExecutionPolicy Bypass -File scripts\write-articles.ps1 -DryRun    (show chosen story + prompt, no API call)
#   powershell -ExecutionPolicy Bypass -File scripts\write-articles.ps1 -SelfTest -OutDir <folder>   (no API call, canned article, writes to <folder>)
#
# How it stays honest and safe:
#   * Recent headlines + summaries from public RSS feeds are used ONLY as fact notes; they are never displayed.
#   * The model must use only facts in those notes (no invented quotes/numbers/background) or return skip=true.
#   * Output is rejected if it reuses any 8-word run from the notes, or is too short/long.
#   * Sensitive topics (sexual violence, abuse, suicide), live blogs and opinion columns are skipped.
#   * Articles are labelled AI-assisted and list their reporting basis on the site.
# API key: environment variable ANTHROPIC_API_KEY, or the encrypted file made by scripts\set-api-key.ps1.
# ASCII only in this file on purpose (Windows PowerShell 5.1 reads BOM-less files as ANSI).
param([switch]$DryRun, [switch]$SelfTest, [string]$OutDir = '')

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = $root }

# ----- settings -----
$Model       = 'claude-opus-5-5'   # cheaper alternative: 'claude-haiku-5-5'
$MaxPerDay   = 60                  # hard cap on articles published per calendar day (UTC)
$KeepLast    = 80                  # generated articles kept on the site
$MaxAgeHours = 8                   # only write about stories published within this window
$statePath   = Join-Path $PSScriptRoot 'writer-state.json'
$logPath     = Join-Path $PSScriptRoot 'writer.log'
$inv         = [Globalization.CultureInfo]::InvariantCulture

if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 200KB) { Remove-Item $logPath -Force }
function Log([string]$m) { $l = '{0} {1}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss', $inv)), $m; Write-Host $l; Add-Content -Path $logPath -Value $l -Encoding UTF8 }

# ----- helpers (same approach as fetch-news.ps1) -----
function Get-Text([string]$html) {
  if (-not $html) { return '' }
  $t = [Net.WebUtility]::HtmlDecode($html); $t = [regex]::Replace($t, '<[^>]*>', ' '); $t = [Net.WebUtility]::HtmlDecode($t)
  return ([regex]::Replace($t, '\s+', ' ')).Trim()
}
function Node-Text($item, [string]$name) { $n = $item.SelectSingleNode("*[local-name()='$name']"); if ($n) { return $n.InnerText } else { return '' } }
function To-Millis([string]$s) {
  if (-not $s) { return 0 }
  $s = [regex]::Replace($s.Trim(), '([+-]\d\d)(\d\d)$', '$1:$2'); $dt = [DateTimeOffset]::MinValue
  if ([DateTimeOffset]::TryParse($s, $inv, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dt)) { return $dt.ToUnixTimeMilliseconds() }
  return 0
}
function Get-Id([string]$s) {
  $md5 = [Security.Cryptography.MD5]::Create(); $h = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
  return ('g-' + (($h[0..5] | ForEach-Object { $_.ToString('x2') }) -join ''))
}
$stop = 'the','and','for','with','that','this','from','after','over','into','will','have','has','says','said','new','its','are','was','were','but','not','their','than','more','about','amid','what','who','can','when','been','also','they','them','his','her'
function Get-Tokens([string]$s) { @(([regex]::Matches($s.ToLower(), '[a-z0-9]{4,}') | ForEach-Object { $_.Value }) | Where-Object { $stop -notcontains $_ } | Select-Object -Unique) }
function Get-Overlap($a, $b) { @($a | Where-Object { $b -contains $_ }).Count }
function Get-Words([string]$s) { @([regex]::Matches($s.ToLower(), "[a-z0-9']+") | ForEach-Object { $_.Value }) }

# ----- feeds used ONLY as fact notes -----
$Feeds = @(
  @('pakistan','Dawn','https://www.dawn.com/feeds/home'),
  @('pakistan','Google News','https://news.google.com/rss/headlines/section/geo/Pakistan?hl=en-PK&gl=PK&ceid=PK:en'),
  @('world','BBC News','https://feeds.bbci.co.uk/news/world/rss.xml'),
  @('politics','BBC News','https://feeds.bbci.co.uk/news/politics/rss.xml'),
  @('politics','The Guardian','https://www.theguardian.com/politics/rss'),
  @('business','BBC News','https://feeds.bbci.co.uk/news/business/rss.xml'),
  @('business','The Guardian','https://www.theguardian.com/business/rss'),
  @('technology','BBC News','https://feeds.bbci.co.uk/news/technology/rss.xml'),
  @('technology','The Guardian','https://www.theguardian.com/technology/rss'),
  @('climate','BBC News','https://feeds.bbci.co.uk/news/science_and_environment/rss.xml'),
  @('climate','The Guardian','https://www.theguardian.com/environment/rss'),
  @('sports','BBC Sport','https://feeds.bbci.co.uk/sport/rss.xml'),
  @('culture','BBC News','https://feeds.bbci.co.uk/news/entertainment_and_arts/rss.xml'),
  @('current-affairs','BBC News','https://feeds.bbci.co.uk/news/rss.xml')
)
$skipTopics = 'rape|sexual|sex abuse|child abuse|paedoph|pedoph|suicide|self-harm|porn|nude|abuse material|grooming|incest'
$skipFormat = '(^|\s)live(\s|:|$)|\blive\b.*[-:]|\|\s|podcast|quiz|crossword|horoscope|\bwatch:|in pictures'

function Get-Candidates {
  $cutoff = [DateTimeOffset]::UtcNow.AddHours(-$MaxAgeHours).ToUnixTimeMilliseconds()
  $out = @()
  foreach ($f in $Feeds) {
    try {
      $r = Invoke-WebRequest -Uri $f[2] -UseBasicParsing -TimeoutSec 20 -UserAgent 'Mozilla/5.0 (compatible; TheCurrentCanvasBot/1.0)'
      $ms = New-Object IO.MemoryStream; $r.RawContentStream.CopyTo($ms)
      $xml = New-Object Xml.XmlDocument; $xml.XmlResolver = $null
      $xml.LoadXml([Text.Encoding]::UTF8.GetString($ms.ToArray()).TrimStart([char]0xFEFF))
      foreach ($it in ($xml.SelectNodes('//*[local-name()="item"]') | Select-Object -First 25)) {
        $title = Get-Text (Node-Text $it 'title'); $sum = Get-Text (Node-Text $it 'description')
        if ($sum.Length -gt 600) { $sum = $sum.Substring(0, 600) }
        $pub = Node-Text $it 'pubDate'; if (-not $pub) { $pub = Node-Text $it 'date' }
        $t = To-Millis $pub; $link = (Node-Text $it 'link').Trim()
        if (-not $title -or $link -notmatch '^https?://' -or $t -lt $cutoff -or $sum.Length -lt 50) { continue }
        if (("$title $sum") -match $skipTopics -or $title -match $skipFormat) { continue }
        $out += [pscustomobject]@{ section = $f[0]; source = $f[1]; title = $title; summary = $sum; link = $link; time = $t; tok = (Get-Tokens $title) }
      }
    } catch { Log ("feed fail {0}: {1}" -f $f[1], $_.Exception.Message) }
  }
  return $out
}

# ----- state -----
$today = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
$state = @{ day = $today; count = 0; used = @() }
if (Test-Path $statePath) { try { $s = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json; $state = @{ day = $s.day; count = [int]$s.count; used = @($s.used) } } catch {} }
if ($state.day -ne $today) { $state.day = $today; $state.count = 0 }
if (-not $SelfTest -and -not $DryRun -and $state.count -ge $MaxPerDay) { Log "daily cap reached ($MaxPerDay); stopping"; exit 0 }

# ----- API key (not needed for -DryRun / -SelfTest) -----
$apiKey = $env:ANTHROPIC_API_KEY
if (-not $apiKey) {
  $kf = Join-Path $HOME '.current-canvas/anthropic.key'
  if (Test-Path $kf) { try { $apiKey = [Net.NetworkCredential]::new('', (Get-Content $kf | ConvertTo-SecureString)).Password } catch { Log 'could not read stored key' } }
}
if (-not $apiKey -and -not $DryRun -and -not $SelfTest) { Log 'no API key found; run scripts\set-api-key.ps1 once'; exit 0 }

# ----- existing titles (avoid duplicates) -----
$existing = @()
foreach ($f in 'originals.js', 'generated.js') { $p = Join-Path $root $f; if (Test-Path $p) { $existing += [regex]::Matches((Get-Content $p -Raw -Encoding UTF8), "title:\s*'((?:[^'\\]|\\.)*)'|`"title`":`"((?:[^`"\\]|\\.)*)`"") | ForEach-Object { $_.Groups[1].Value + $_.Groups[2].Value } } }
$existingTok = @($existing | ForEach-Object { , (Get-Tokens $_) })

# ----- choose a story -----
$seenTitles = @{}
$cands = @(Get-Candidates | Where-Object { $state.used -notcontains $_.link -and -not $seenTitles.ContainsKey($_.title) -and ($seenTitles[$_.title] = $true) })
if ($cands.Count -eq 0) { Log 'no fresh candidates'; exit 0 }
$cands = @($cands | Where-Object { $c = $_; -not ($existingTok | Where-Object { (Get-Overlap $c.tok $_) -ge 3 }) })
if ($cands.Count -eq 0) { Log 'all candidates already covered'; exit 0 }
$scored = foreach ($c in ($cands | Sort-Object time -Descending | Select-Object -First 30)) {
  $rel = @($cands | Where-Object { $_.link -ne $c.link -and $_.source -ne $c.source -and (Get-Overlap $c.tok $_.tok) -ge 3 } | Select-Object -First 2)
  [pscustomobject]@{ c = $c; rel = $rel; score = ([math]::Min($rel.Count, 2) * 1000000000000 + $c.time) }
}
$pick = $scored | Sort-Object score -Descending | Select-Object -First 1
$notes = @($pick.c) + @($pick.rel)
$noteText = ($notes | ForEach-Object { '[{0}] {1} | published {2:yyyy-MM-dd HH:mm} UTC' -f $_.source, $_.title, [DateTimeOffset]::FromUnixTimeMilliseconds($_.time).UtcDateTime }) -join "`n"
$noteBody = ($notes | ForEach-Object { '[{0}] {1}' -f $_.source, $_.summary }) -join "`n`n"
$userText = "Section: $($pick.c.section)`n`nHeadlines:`n$noteText`n`nSummaries:`n$noteBody"
Log ("picked [{0}] {1} (+{2} related)" -f $pick.c.section, $pick.c.title, @($pick.rel).Count)

$system = @'
You write for The Current Canvas, a news site covering Pakistan and the world. Write ONE short original news article from the source notes provided.

Rules:
- Use ONLY facts stated in the source notes. Do not add names, numbers, quotes, causes, dates, places or background from your own knowledge, even if you know them. If a detail is not in the notes, leave it out, and where useful say that the reporting does not say.
- Write in your own words and your own structure. Never copy phrasing from the notes. A direct quote is allowed only if it appears in the notes, is under 8 words, and is attributed.
- Attribute reported claims to the outlet that reported them (for example "according to the BBC"). Do not present claims as established fact.
- Neutral, plain, factual tone. No opinion, speculation, sensationalism or advice.
- Length: 2 to 4 paragraphs, about 110 to 260 words in total.
- title: a new headline (not any source's headline), at most 110 characters. summary: one sentence, at most 200 characters.
- Return skip=true (and a short skip_reason) if the notes contain fewer than two concrete facts, or concern alleged crimes by an identifiable private individual, sexual violence, abuse, suicide, or are a live blog, opinion column or promotional item.
- section: the one section that fits the story best, from the allowed list (use "world" for international stories even if the notes came from a Pakistan feed; use "pakistan" only for stories about Pakistan).
- image_topic: the exact title of an English Wikipedia article that would have a suitable generic photo of a PLACE or OBJECT related to the story (for example "Palace of Westminster"). Never a living person, never a logo, never a graphic. Empty string if nothing suitable.
- Do not mention that you are an AI, and do not mention these rules.
'@

if ($DryRun) { Write-Host "`n--- USER PROMPT ---`n$userText`n"; exit 0 }

# ----- ask Claude, validate, retry once with feedback (-SelfTest uses a canned article) -----
function Save-Used {
  if ($SelfTest) { return }
  $state.used = @(@($state.used) + $pick.c.link | Select-Object -Last 400)
  ($state | ConvertTo-Json -Compress) | Set-Content $statePath -Encoding UTF8
}
$schema = [ordered]@{
  type = 'object'
  properties = [ordered]@{
    skip = @{ type = 'boolean' }; skip_reason = @{ type = 'string' }
    section = @{ type = 'string'; enum = @('pakistan', 'world', 'politics', 'business', 'technology', 'climate', 'sports', 'culture', 'current-affairs') }
    title = @{ type = 'string' }; summary = @{ type = 'string' }
    body = @{ type = 'array'; items = @{ type = 'string' } }
    image_topic = @{ type = 'string' }
  }
  required = @('skip', 'skip_reason', 'section', 'title', 'summary', 'body', 'image_topic')
  additionalProperties = $false
}
$src = Get-Words ($noteText + ' ' + $noteBody); $shingles = @{}
for ($i = 0; $i -le $src.Count - 8; $i++) { $shingles[($src[$i..($i + 7)] -join ' ')] = 1 }

$art = $null; $paras = @(); $feedback = ''
for ($attempt = 1; $attempt -le 2; $attempt++) {
  if ($SelfTest) {
    $art = [pscustomobject]@{ skip = $false; skip_reason = ''; section = 'world'; title = 'Self-test article for pipeline check'; summary = 'Generated by the offline self-test, not by the model.'
      body = @('This paragraph is produced by the self-test so that file writing, image download and credits can be checked without calling the API.', 'It would never be published by a normal run, because a normal run needs a real model response.'); image_topic = 'Palace of Westminster' }
  } else {
    $req = [ordered]@{
      model = $Model; max_tokens = 4000; system = $system
      messages = @(@{ role = 'user'; content = ($userText + $feedback) })
      output_config = @{ format = @{ type = 'json_schema'; schema = $schema } }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($req | ConvertTo-Json -Depth 12 -Compress))
    try {
      $resp = Invoke-RestMethod -Method Post -Uri 'https://api.anthropic.com/v1/messages' -TimeoutSec 180 `
        -Headers @{ 'x-api-key' = $apiKey; 'anthropic-version' = '2023-06-01' } -ContentType 'application/json' -Body $bytes
    } catch {
      $msg = $_.Exception.Message; try { $msg += ' ' + (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
      Log ("API error: " + $msg.Substring(0, [Math]::Min(400, $msg.Length))); exit 1
    }
    try { Log ("attempt {0} tokens in/out: {1}/{2}" -f $attempt, $resp.usage.input_tokens, $resp.usage.output_tokens) } catch {}
    if ($resp.stop_reason -ne 'end_turn') { Log ("model stopped with: " + $resp.stop_reason + "; skipping story"); Save-Used; exit 0 }
    $txt = ($resp.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text
    try { $art = $txt | ConvertFrom-Json } catch { Log 'model output was not valid JSON; skipping story'; Save-Used; exit 0 }
  }

  if ($art.skip) { Log ("model skipped: " + $art.skip_reason); Save-Used; exit 0 }
  $paras = @($art.body | Where-Object { $_ -and $_.Trim().Length -gt 0 })
  $wc = (Get-Words ($paras -join ' ')).Count
  $problem = ''
  if (-not $SelfTest) {
    if (-not $art.title -or $art.title.Length -gt 130 -or $paras.Count -lt 2 -or $paras.Count -gt 6 -or $wc -lt 70 -or $wc -gt 450) { $problem = "bad shape (paragraphs=$($paras.Count), words=$wc; need 2-4 paragraphs and about 110-260 words, title under 110 characters)" }
    if (-not $problem) { foreach ($n in $notes) { if ($art.title.Trim().ToLower() -eq $n.title.Trim().ToLower()) { $problem = 'the title copies a source headline' } } }
    if (-not $problem) {
      $out = Get-Words ($art.title + ' ' + $art.summary + ' ' + ($paras -join ' '))
      for ($i = 0; $i -le $out.Count - 8; $i++) { $run = ($out[$i..($i + 7)] -join ' '); if ($shingles.ContainsKey($run)) { $problem = "it reuses this exact wording from the notes: '$run'"; break } }
    }
  }
  if (-not $problem) { break }
  Log ("attempt $attempt rejected: $problem")
  if ($attempt -eq 2) { Log 'giving up on this story'; Save-Used; exit 0 }
  $feedback = "`n`nA previous draft was rejected because $problem. Write the article again from scratch in clearly different wording and sentence structure. Keep every fact accurate and add none."
}

# ----- optional photo from Wikipedia/Commons (open licences only) -----
function Get-WikiPhoto([string]$topic, [string]$id, [string]$dir) {
  if (-not $topic) { return $null }
  $ua = 'TheCurrentCanvas/1.0 (site build)'; $api = 'https://en.wikipedia.org/w/api.php?format=json&formatversion=2&action=query'
  for ($try = 0; $try -lt 3; $try++) {
    try {
      $r = Invoke-RestMethod ("$api&redirects=1&prop=pageimages|categories&piprop=name&clcategories=" + [uri]::EscapeDataString('Category:Living people') + '&titles=' + [uri]::EscapeDataString($topic)) -UserAgent $ua -TimeoutSec 25
      Start-Sleep -Seconds 2
      $pg = $r.query.pages[0]
      if (-not $pg.pageimage -or ($pg.categories -and @($pg.categories).Count -gt 0)) { return $null }
      if ($pg.pageimage -match '(?i)\.svg$|logo|flag_of|coat_of_arms') { return $null }
      $i = Invoke-RestMethod ("$api&prop=imageinfo&iiprop=url|mime|extmetadata&iiurlwidth=1200&titles=File:" + [uri]::EscapeDataString($pg.pageimage)) -UserAgent $ua -TimeoutSec 25
      $ii = $i.query.pages[0].imageinfo[0]; $m = $ii.extmetadata; $lic = [string]$m.LicenseShortName.value
      if ($lic -notmatch '^(CC0|CC[ -]BY|Public domain|PD)') { return $null }
      if ($ii.mime -notin 'image/jpeg', 'image/png') { return $null }
      $srcUrl = if ($ii.thumburl) { $ii.thumburl } else { $ii.url }
      $ext = [IO.Path]::GetExtension(($srcUrl -split '\?')[0]).ToLower(); if ($ext -notin '.jpg', '.jpeg', '.png') { $ext = '.jpg' }
      $imgDir = Join-Path $dir 'images'
      New-Item -ItemType Directory -Force $imgDir | Out-Null
      Start-Sleep -Seconds 2
      Invoke-WebRequest $srcUrl -OutFile (Join-Path $imgDir ($id + $ext)) -UserAgent $ua -TimeoutSec 60
      $artist = (([regex]::Replace([string]$m.Artist.value, '<[^>]+>', '') -replace '\s+', ' ')).Trim()
      if (-not $artist) { $artist = 'Wikimedia Commons contributor' }
      return [ordered]@{ file = "images/$id$ext"; caption = "$topic. File photo."; artist = $artist; license = $lic; licenseUrl = [string]$m.LicenseUrl.value; page = 'https://en.wikipedia.org/wiki/File:' + $pg.pageimage }
    } catch { Start-Sleep -Seconds (4 * ($try + 1)) }
  }
  return $null
}

$id = Get-Id $pick.c.link
$img = Get-WikiPhoto ([string]$art.image_topic) $id $OutDir
if ($img) { Log ("photo: " + $img.file + " (" + $img.license + ")") } else { Log 'no photo' }

# ----- publish to generated.js -----
$genPath = Join-Path $OutDir 'generated.js'
$list = @()
if (Test-Path $genPath) {
  try { $raw = (Get-Content $genPath -Raw -Encoding UTF8) -replace '^\s*window\.TCC_GENERATED\s*=\s*', '' -replace ';\s*$', ''; $parsed = $raw | ConvertFrom-Json; if ($parsed) { $list = @($parsed) } } catch { Log 'could not parse existing generated.js; starting fresh' }
}
$entry = [ordered]@{
  id = $id; section = $(if ($art.section) { $art.section } else { $pick.c.section }); time = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
  basis = @($notes | ForEach-Object { $_.source } | Select-Object -Unique); asOf = [DateTime]::UtcNow.ToString('d MMMM yyyy', $inv)
  title = $art.title.Trim(); summary = $art.summary.Trim(); body = @($paras | ForEach-Object { $_.Trim() })
}
if ($img) { $entry['img'] = $img }
$list = @([pscustomobject]$entry) + $list
if ($list.Count -gt $KeepLast) {
  foreach ($old in $list[$KeepLast..($list.Count - 1)]) { if ($old.img -and $old.img.file) { Remove-Item (Join-Path $OutDir $old.img.file) -Force -ErrorAction SilentlyContinue } }
  $list = @($list[0..($KeepLast - 1)])
}
$json = ConvertTo-Json -InputObject @($list) -Depth 8 -Compress
[IO.File]::WriteAllText($genPath, "window.TCC_GENERATED=$json;", (New-Object Text.UTF8Encoding($false)))
Log ("published: [{0}] {1}" -f $entry.section, $entry.title)

if (-not $SelfTest) {
  $state.used = @(@($state.used) + $pick.c.link | Select-Object -Last 400); $state.count++
  ($state | ConvertTo-Json -Compress) | Set-Content $statePath -Encoding UTF8
}
