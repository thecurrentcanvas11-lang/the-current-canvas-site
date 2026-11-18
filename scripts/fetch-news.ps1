# Fetches all RSS feeds directly (no rss2json) and writes news.json + news.js next to index.html.
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\fetch-news.ps1
# Works in Windows PowerShell 5.1 and PowerShell 7 (pwsh). No dependencies.
# Schedule it every 5-15 minutes (Task Scheduler, cron, or the included GitHub Action).

$ErrorActionPreference = 'Continue'
# $true = publish only our own content: skip third-party news feeds and any data brief whose credit needs a link.
# Set to $false to also pull headline cards from the RSS feeds below.
$OwnOnly = $true
$root = Split-Path -Parent $PSScriptRoot
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Keep in sync with SECTIONS in app.js
$Sections = [ordered]@{
  'pakistan'        = @(@('Dawn','https://www.dawn.com/feeds/home'), @('Google News','https://news.google.com/rss/headlines/section/geo/Pakistan?hl=en-PK&gl=PK&ceid=PK:en'))
  'world'           = @(@('BBC News','https://feeds.bbci.co.uk/news/world/rss.xml'), @('Al Jazeera','https://www.aljazeera.com/xml/rss/all.xml'))
  'politics'        = @(@('BBC News','https://feeds.bbci.co.uk/news/politics/rss.xml'), @('Guardian','https://www.theguardian.com/politics/rss'))
  'business'        = @(@('BBC News','https://feeds.bbci.co.uk/news/business/rss.xml'), @('Guardian','https://www.theguardian.com/business/rss'))
  'technology'      = @(@('BBC News','https://feeds.bbci.co.uk/news/technology/rss.xml'), @('Guardian','https://www.theguardian.com/technology/rss'), @('NASA','https://www.nasa.gov/feed/','full'))
  'climate'         = @(@('BBC News','https://feeds.bbci.co.uk/news/science_and_environment/rss.xml'), @('Guardian','https://www.theguardian.com/environment/rss'), @('NASA','https://www.nasa.gov/feed/','full'))
  'sports'          = @(@('BBC Sport','https://feeds.bbci.co.uk/sport/rss.xml'), @('Guardian','https://www.theguardian.com/sport/rss'))
  'culture'         = @(@('BBC News','https://feeds.bbci.co.uk/news/entertainment_and_arts/rss.xml'), @('Guardian','https://www.theguardian.com/culture/rss'))
  'current-affairs' = @(@('Al Jazeera','https://www.aljazeera.com/xml/rss/all.xml'), @('BBC News','https://feeds.bbci.co.uk/news/rss.xml'))
  'opinion'         = @(@('Guardian','https://www.theguardian.com/commentisfree/rss'), @('Dawn','https://www.dawn.com/feeds/opinion'))
  'fact-check'      = @(,@('Google News','https://news.google.com/rss/search?q=fact+check&hl=en-PK&gl=PK&ceid=PK:en'))
}

function Get-Text([string]$html) {
  if (-not $html) { return '' }
  $t = [Net.WebUtility]::HtmlDecode($html)
  $t = [regex]::Replace($t, '<[^>]*>', ' ')
  $t = [Net.WebUtility]::HtmlDecode($t)
  return ([regex]::Replace($t, '\s+', ' ')).Trim()
}
function Node-Text($item, [string]$name) {
  $n = $item.SelectSingleNode("*[local-name()='$name']")
  if ($n) { return $n.InnerText } else { return '' }
}
function Node-Attr($item, [string]$name, [string]$attr) {
  $n = $item.SelectSingleNode("*[local-name()='$name']/@$attr")
  if ($n) { return $n.Value } else { return '' }
}
function To-Millis([string]$s) {
  if (-not $s) { return 0 }
  $s = [regex]::Replace($s.Trim(), '([+-]\d\d)(\d\d)$', '$1:$2')
  $dt = [DateTimeOffset]::MinValue
  if ([DateTimeOffset]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dt)) {
    return $dt.ToUnixTimeMilliseconds()
  }
  return 0
}

function Get-Paras([string]$html) {
  if (-not $html) { return @() }
  $t = [Net.WebUtility]::HtmlDecode($html)
  $t = [regex]::Replace($t, '</(p|h\d|li|div)>|<br\s*/?>', "`n")
  $t = [regex]::Replace($t, '<[^>]*>', ' ')
  $t = [Net.WebUtility]::HtmlDecode($t)
  return @($t -split "`n" | ForEach-Object { ([regex]::Replace($_, '\s+', ' ')).Trim() } |
    Where-Object { $_.Length -gt 40 -and $_ -notmatch 'appeared first on|^Share |^Credits?:|^Image credit' } | Select-Object -First 14)
}
function Get-Id([string]$s) {
  $md5 = [Security.Cryptography.MD5]::Create()
  $h = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
  return ('a' + (($h[0..5] | ForEach-Object { $_.ToString('x2') }) -join ''))
}

function Get-Feed($source, $url, $full) {
  try {
    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -UserAgent 'Mozilla/5.0 (compatible; TheCurrentCanvasBot/1.0)'
    $ms = New-Object IO.MemoryStream
    $r.RawContentStream.CopyTo($ms)
    $xml = New-Object Xml.XmlDocument
    $xml.XmlResolver = $null
    $xml.LoadXml([Text.Encoding]::UTF8.GetString($ms.ToArray()).TrimStart([char]0xFEFF))
    $out = @()
    foreach ($it in ($xml.SelectNodes('//*[local-name()="item"]') | Select-Object -First 20)) {
      $desc = Node-Text $it 'description'
      $img = Node-Attr $it 'thumbnail' 'url'
      if (-not $img) { $img = Node-Attr $it 'content' 'url' }
      if (-not $img -and (Node-Attr $it 'enclosure' 'type') -like 'image*') { $img = Node-Attr $it 'enclosure' 'url' }
      if (-not $img) {
        $m = [regex]::Match([Net.WebUtility]::HtmlDecode($desc), '<img[^>]+src=["'']([^"'']+)')
        if ($m.Success) { $img = $m.Groups[1].Value }
      }
      $summary = Get-Text $desc
      if ($summary.Length -gt 400) { $summary = $summary.Substring(0, 400).TrimEnd() + '...' }
      $kind = 'excerpt'; $body = @()
      if ($full) {
        # openly licensed / public-domain source: keep the full text for an in-site story page
        $enc = Node-Text $it 'encoded'
        $body = @(Get-Paras $enc)
        if (-not $img) { $m2 = [regex]::Match([Net.WebUtility]::HtmlDecode($enc), '<img[^>]+src=["'']([^"'']+)'); if ($m2.Success) { $img = $m2.Groups[1].Value } }
        if ($body.Count -ge 2) { $kind = 'licensed'; $summary = $body[0]; if ($summary.Length -gt 300) { $summary = $summary.Substring(0, 300).TrimEnd() + '...' } }
      }
      $pub = Node-Text $it 'pubDate'; if (-not $pub) { $pub = Node-Text $it 'date' }
      $lnk = (Node-Text $it 'link').Trim()
      $out += [pscustomobject]@{
        id      = Get-Id $lnk
        title   = Get-Text (Node-Text $it 'title')
        link    = $lnk
        summary = $summary
        body    = $body
        kind    = $kind
        time    = To-Millis $pub
        img     = $img
        source  = $source
      }
    }
    Write-Host ("  ok   {0} ({1})" -f $source, $out.Count)
    return $out
  } catch {
    Write-Warning ("  FAIL {0}: {1}  {2}" -f $source, $_.Exception.Message, $url)
    return @()
  }
}

# ---------------------------------------------------------------------------
# Original data briefs: short stories written by this script from open data
# (USGS, NASA EONET, Open-Meteo, ExchangeRate-API, CoinGecko, TheSportsDB).
# They have no outbound article link; the site shows them on its own story pages.
# ---------------------------------------------------------------------------
$inv = [Globalization.CultureInfo]::InvariantCulture
$deg = [string][char]0x00B0
$briefs = @{}
foreach ($k in $Sections.Keys) { $briefs[$k] = @() }

function Add-Brief($section, $id, $title, $summary, $body, [long]$ms, $credit, $creditUrl = '') {
  $script:briefs[$section] += [pscustomobject]@{
    id = $id; title = $title; summary = $summary; body = @($body); time = $ms
    source = 'Data brief'; credit = $credit; creditUrl = $creditUrl; original = $true; link = ''; img = ''
  }
}
function Format-Pkt([long]$ms) {
  [DateTimeOffset]::FromUnixTimeMilliseconds($ms).UtcDateTime.AddHours(5).ToString('d MMM yyyy, h:mm tt', $inv) + ' PKT'
}
function Get-Api($url) {
  try { return Invoke-RestMethod -Uri $url -TimeoutSec 25 -UserAgent 'Mozilla/5.0 (compatible; TheCurrentCanvasBot/1.0)' }
  catch { Write-Warning ("  API FAIL: {0}  {1}" -f $_.Exception.Message, $url); return $null }
}
function Get-QuakeText([double]$m) {
  if ($m -lt 4) { 'Earthquakes of this size are usually felt by people close to the epicentre, and significant damage is unlikely.' }
  elseif ($m -lt 5) { 'Shaking of this strength is noticeable indoors, with rattling objects, but significant damage is unlikely.' }
  elseif ($m -lt 6) { 'Earthquakes in this range can cause major damage to poorly constructed buildings over small areas.' }
  elseif ($m -lt 7) { 'Earthquakes in this range can be destructive in areas up to about 160 kilometres from the epicentre.' }
  else { 'Earthquakes of this size can cause serious damage over very large areas.' }
}
function Add-QuakeBriefs($section, $url, $max, $placeFilter = '') {
  $q = Get-Api $url
  if (-not $q) { return }
  foreach ($f in @($q.features | Where-Object { -not $placeFilter -or $_.properties.place -match $placeFilter } | Select-Object -First $max)) {
    $p = $f.properties; $m = [math]::Round([double]$p.mag, 1); $depth = [math]::Round([double]$f.geometry.coordinates[2], 0)
    $tsu = if ($p.tsunami -eq 1) { ' A tsunami advisory flag was set in the data for this event.' } else { '' }
    Add-Brief $section ('quake-' + $f.id) ("Magnitude $m earthquake: " + $p.place) `
      ("A magnitude $m earthquake was recorded $($p.place) at a depth of about $depth km.") `
      @("A magnitude $m earthquake struck $($p.place) at $(Format-Pkt $p.time), according to data from the United States Geological Survey (USGS). The quake was recorded at a depth of about $depth kilometres.",
        (Get-QuakeText $m) + $tsu,
        "Magnitudes and locations are often revised in the hours after an earthquake as more seismic stations report. This brief is generated automatically from the latest USGS data.") `
      $p.time 'US Geological Survey (USGS)'
  }
}

# Pakistan region + significant world quakes
$start = [DateTime]::UtcNow.AddDays(-7).ToString('yyyy-MM-dd')
Add-QuakeBriefs 'pakistan' "https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson&minlatitude=23&maxlatitude=37.5&minlongitude=60&maxlongitude=78&minmagnitude=3.5&limit=50&orderby=time&starttime=$start" 3 'Pakistan'
Add-QuakeBriefs 'world' 'https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/significant_week.geojson' 3

# Pakistan weather (Open-Meteo, CC BY 4.0)
$w = Get-Api 'https://api.open-meteo.com/v1/forecast?latitude=24.86,31.55,33.69,34.01,30.20&longitude=67.01,74.34,73.05,71.58,71.47&current=temperature_2m,wind_speed_10m&daily=temperature_2m_max,temperature_2m_min,precipitation_sum&timezone=Asia%2FKarachi&forecast_days=1'
if ($w) {
  $names = 'Karachi', 'Lahore', 'Islamabad', 'Peshawar', 'Multan'
  $rows = @(); $i = 0
  foreach ($c in @($w)) {
    $rows += [pscustomobject]@{ n = $names[$i]; now = [math]::Round($c.current.temperature_2m); hi = [math]::Round($c.daily.temperature_2m_max[0]); lo = [math]::Round($c.daily.temperature_2m_min[0]); rain = [double]$c.daily.precipitation_sum[0]; wind = [math]::Round($c.current.wind_speed_10m) }
    $i++
  }
  if ($rows.Count -gt 0) {
    $hot = $rows | Sort-Object now -Descending | Select-Object -First 1
    $cold = $rows | Sort-Object now | Select-Object -First 1
    $wet = @($rows | Where-Object { $_.rain -ge 1 })
    $body = @("Across Pakistan's major cities this hour, $($hot.n) is the warmest at $($hot.now)$($deg)C, while $($cold.n) is the coolest at $($cold.now)$($deg)C.")
    $body += ($rows | ForEach-Object { "$($_.n): $($_.now)$($deg)C now, with a forecast high of $($_.hi)$($deg)C and a low of $($_.lo)$($deg)C; wind $($_.wind) km/h." })
    $body += $(if ($wet.Count) { 'Rain is forecast today in ' + (($wet | ForEach-Object { "$($_.n) ($($_.rain) mm)" }) -join ', ') + '.' } else { 'No significant rainfall is forecast today in these five cities.' })
    $body += 'This brief is generated automatically from weather model data and refreshes with each update.'
    Add-Brief 'pakistan' 'weather-pakistan' "Pakistan weather today: $($hot.n) warmest at $($hot.now)$($deg)C" `
      (($rows | ForEach-Object { "$($_.n) $($_.now)$($deg)C" }) -join ' | ') $body ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) 'Open-Meteo.com (CC BY 4.0)' 'https://open-meteo.com/'
  }
}

# NASA EONET: natural events being tracked now
$e = Get-Api 'https://eonet.gsfc.nasa.gov/api/v3/events?status=open&limit=500'
if ($e -and $e.events) {
  $ev = @($e.events)
  $groups = $ev | Group-Object { $_.categories[0].title } | Sort-Object Count -Descending
  $top = @($groups | Select-Object -First 3 | ForEach-Object { "$($_.Count) $($_.Name.ToLower())" })
  $latest = @($ev | Sort-Object { [DateTime]$_.geometry[-1].date } -Descending | Select-Object -First 3)
  $cnt = if ($ev.Count -ge 500) { 'more than 500' } else { "$($ev.Count)" }
  $body = @("NASA's Earth Observatory Natural Event Tracker currently lists $cnt open natural events around the world, led by $($top -join ', ').")
  $body += ($latest | ForEach-Object { "Recent entry: $($_.title) ($($_.categories[0].title.ToLower()))." })
  $body += 'Events remain on the list until they are closed in the tracker. This brief is generated automatically from NASA data.'
  Add-Brief 'climate' 'eonet-summary' "Satellites are tracking $cnt open natural events worldwide" `
    "Leading categories: $($top -join ', ')." $body ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) 'NASA EONET'
}

# Rupee and major currencies (ExchangeRate-API; attribution required) + crypto (CoinGecko)
$prevMeta = $null; $np = Join-Path $root 'news.json'
if (Test-Path $np) { try { $prevMeta = (Get-Content $np -Raw -Encoding UTF8 | ConvertFrom-Json).meta } catch {} }
$today = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
$fxMeta = @{ date = $today; last = @{}; prev = @{} }
if ($prevMeta -and $prevMeta.fx) { $fxMeta.prev = $(if ($prevMeta.fx.date -eq $today) { $prevMeta.fx.prev } else { $prevMeta.fx.last }) }
$fx = Get-Api 'https://open.er-api.com/v6/latest/USD'
if ($fx -and $fx.rates -and $fx.rates.PKR) {
  $r = $fx.rates; $pkr = [math]::Round([double]$r.PKR, 2)
  $fxMeta.last = @{ PKR = $pkr }
  $prev = $fxMeta.prev.PKR; $dir = ''; $pct = 0
  if ($prev) { $pct = [math]::Round(($pkr - $prev) / $prev * 100, 2); $dir = if ([math]::Abs($pct) -lt 0.05) { 'steady' } elseif ($pct -gt 0) { 'weaker' } else { 'stronger' } }
  $title = switch ($dir) { 'weaker' { "Rupee weakens to Rs $pkr against the US dollar" } 'stronger' { "Rupee strengthens to Rs $pkr against the US dollar" } 'steady' { "Rupee steady near Rs $pkr against the US dollar" } default { "US dollar buys Rs $pkr in global currency markets" } }
  $body = @("One US dollar buys about Rs $pkr, based on mid-market reference rates published today.")
  if ($dir) { $body += "That is $(if ($dir -eq 'steady') { 'little changed' } else { "a $([math]::Abs($pct))% move toward a $dir rupee" }) compared with the previous day's reading in this site's records." }
  $body += "Other reference rates per US dollar: $([math]::Round($r.EUR,4)) euro, $([math]::Round($r.GBP,4)) pound sterling, $([math]::Round($r.AED,4)) UAE dirham, $([math]::Round($r.SAR,4)) Saudi riyal and $([math]::Round($r.CNY,4)) Chinese yuan."
  $body += "At these rates, one pound sterling is worth about Rs $([math]::Round($pkr / $r.GBP, 2)) and one UAE dirham about Rs $([math]::Round($pkr / $r.AED, 2))."
  $body += 'These are mid-market reference rates and can differ from rates offered by banks and exchange companies. This brief is generated automatically.'
  Add-Brief 'business' 'fx-pkr' $title "US dollar at Rs $pkr; euro $([math]::Round($r.EUR,4)), pound $([math]::Round($r.GBP,4)) per dollar." $body ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) 'Rates by Exchange Rate API' 'https://www.exchangerate-api.com'
}
$cg = Get-Api 'https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd&include_24hr_change=true'
if ($cg -and $cg.bitcoin) {
  $b = $cg.bitcoin; $et = $cg.ethereum; $bc = [math]::Round($b.usd_24h_change, 2)
  $word = if ($bc -ge 0) { 'gains' } else { 'falls' }
  $body = @("Bitcoin traded at about `$$('{0:N0}' -f $b.usd), $(if ($bc -ge 0) { 'up' } else { 'down' }) $([math]::Abs($bc))% over the past 24 hours.")
  if ($et) { $body += "Ethereum was at about `$$('{0:N0}' -f $et.usd), a 24-hour change of $([math]::Round($et.usd_24h_change, 2))%." }
  $body += 'Cryptocurrency prices are volatile and this brief is not investment advice. It is generated automatically from market data.'
  Add-Brief 'business' 'crypto-snapshot' "Bitcoin $word $([math]::Abs($bc))% in 24 hours to `$$('{0:N0}' -f $b.usd)" "Bitcoin `$$('{0:N0}' -f $b.usd); 24-hour change $bc%." $body ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) 'Data by CoinGecko' 'https://www.coingecko.com/en/api'
}

# Football results (TheSportsDB)
$sp = Get-Api 'https://www.thesportsdb.com/api/v1/json/123/eventspastleague.php?id=4328'
if ($sp -and $sp.events) {
  foreach ($m in @($sp.events | Where-Object { $_.intHomeScore -ne $null -and $_.intHomeScore -ne '' } | Select-Object -Last 4)) {
    $h = [int]$m.intHomeScore; $a = [int]$m.intAwayScore
    $res = if ($h -gt $a) { "$($m.strHomeTeam) beat $($m.strAwayTeam)" } elseif ($a -gt $h) { "$($m.strAwayTeam) won away at $($m.strHomeTeam)" } else { "$($m.strHomeTeam) and $($m.strAwayTeam) drew" }
    $ms = 0
    $dto = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$m.strTimestamp, $inv, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dto)) { $ms = $dto.ToUnixTimeMilliseconds() }
    $body = @("$res in the $($m.strLeague), the final score finishing $($m.strHomeTeam) $h, $($m.strAwayTeam) $a.")
    if ($m.strVenue) { $body += "The match was played at $($m.strVenue)." }
    $body += 'Results are generated automatically from match data.'
    Add-Brief 'sports' ('match-' + $m.idEvent) "$($m.strHomeTeam) $h-$a $($m.strAwayTeam): $($m.strLeague) result" "$res ($h-$a) in the $($m.strLeague)." $body $ms 'TheSportsDB'
  }
}

$result = [ordered]@{ updated = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); meta = @{ fx = $fxMeta }; sections = [ordered]@{} }
$total = 0
foreach ($id in $Sections.Keys) {
  Write-Host $id
  $seen = @{}
  $items = @()
  if (-not $OwnOnly) { foreach ($f in $Sections[$id]) { $items += Get-Feed $f[0] $f[1] ($f.Count -gt 2 -and $f[2] -eq 'full') } }
  $items = $items | Where-Object {
    $_.title -and $_.link -match '^https?://' -and -not $seen.ContainsKey($_.title) -and ($seen[$_.title] = $true)
  } | Sort-Object time -Descending | Select-Object -First 18
  $own = @(@($briefs[$id]) | Where-Object { $_ -and (-not $OwnOnly -or -not $_.creditUrl) })
  $items = @(@($own) + @($items)) | Where-Object { $_ } | Sort-Object time -Descending
  $result.sections[$id] = @($items)
  $total += @($items).Count
}

if ($total -eq 0) { Write-Error 'No items fetched; keeping previous files.'; exit 1 }

$json = $result | ConvertTo-Json -Depth 6 -Compress
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $root 'news.json'), $json, $utf8)
[IO.File]::WriteAllText((Join-Path $root 'news.js'), "window.TCC_NEWS=$json;", $utf8)
Write-Host "Wrote $total items to news.json and news.js"
