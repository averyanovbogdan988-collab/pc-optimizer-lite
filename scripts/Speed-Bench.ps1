#Requires -Version 5.1
<#
.SYNOPSIS
    Speed Bench - воспроизводимый замер скорости с журналом и сравнением до/после.

.DESCRIPTION
    Один прогон Speedtest по Wi-Fi ничего не доказывает: разброс между
    замерами бывает кратным. Этот скрипт делает несколько прогонов, пишет
    их в журнал с меткой и сравнивает метки между собой по медиане.

    Отдельно меряет скорость в один поток и в несколько. Разрыв между ними
    сам по себе диагноз:
      - один поток сильно медленнее многопоточного -> упирается в окно TCP
        и задержку, канал ни при чём;
      - оба одинаково низкие -> упирается сам канал (радио, роутер, провайдер).

.EXAMPLE
    .\Speed-Bench.ps1 -Label "до правок"
    .\Speed-Bench.ps1 -Label "после правок"
    .\Speed-Bench.ps1 -Compare
#>
[CmdletBinding()]
param(
    [string]$Label = 'замер',
    [int]$Runs = 3,
    [int]$Streams = 4,
    [int]$SizeMB = 20,
    [switch]$Compare,
    [switch]$NoUpload
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$script:AppDir  = Join-Path $env:LOCALAPPDATA 'pc-optimizer-lite'
$script:CsvPath = Join-Path $script:AppDir 'speed-log.csv'
# Несколько источников: если один недоступен, берём следующий.
$script:DownUrls = @(
    'https://speed.cloudflare.com/__down?bytes={0}'
    'https://speed.hetzner.de/100MB.bin'
    'http://proof.ovh.net/files/100Mb.dat'
)
$script:UpUrl   = 'https://speed.cloudflare.com/__up'
$script:DownUrl = $script:DownUrls[0]

function Say { param([string]$T = '', [string]$C = 'Gray') Write-Host $T -ForegroundColor $C }

function Say-Head {
    param([string]$T)
    Say ''
    Say ("== " + $T + " " + ('=' * [Math]::Max(3, 60 - $T.Length))) 'Cyan'
}

# Качает URL в никуда, возвращает число принятых байт.
$script:Worker = {
    param([string]$Url, [int]$TimeoutSec)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.AllowAutoRedirect = $true
        $resp = $req.GetResponse()
        $stream = $resp.GetResponseStream()
        $buf = New-Object byte[] 262144
        $total = 0L
        while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $total += $n }
        $stream.Close(); $resp.Close()
        return @{ b = $total; e = '' }
    } catch {
        return @{ b = 0L; e = $_.Exception.Message }
    }
}

# Заливает случайные данные, возвращает число отправленных байт.
$script:Uploader = {
    param([string]$Url, [int]$Bytes, [int]$TimeoutSec)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Method = 'POST'
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.ContentType = 'application/octet-stream'
        $req.ContentLength = $Bytes
        $req.AllowWriteStreamBuffering = $false
        $chunk = New-Object byte[] 262144
        (New-Object Random).NextBytes($chunk)
        $out = $req.GetRequestStream()
        $sent = 0L
        while ($sent -lt $Bytes) {
            $n = [Math]::Min($chunk.Length, $Bytes - $sent)
            $out.Write($chunk, 0, $n)
            $sent += $n
        }
        $out.Close()
        $resp = $req.GetResponse(); $resp.Close()
        return @{ b = $sent; e = '' }
    } catch {
        return @{ b = 0L; e = $_.Exception.Message }
    }
}

function Invoke-Parallel {
    param([scriptblock]$Script, [object[]]$Arguments, [int]$Count)

    $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, $Count))
    $pool.Open()
    $jobs = @()
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $Count; $i++) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            $null = $ps.AddScript($Script)
            foreach ($a in $Arguments) { $null = $ps.AddArgument($a) }
            $jobs += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
        }
        $total = 0L
        $err = ''
        foreach ($j in $jobs) {
            try {
                $r = @($j.PS.EndInvoke($j.Handle)) | Select-Object -Last 1
                if ($r) {
                    $total += [int64]$r.b
                    if (-not $err -and $r.e) { $err = [string]$r.e }
                }
            } catch { if (-not $err) { $err = $_.Exception.Message } }
            $j.PS.Dispose()
        }
        $sw.Stop()
        return [pscustomobject]@{ Bytes = $total; Seconds = $sw.Elapsed.TotalSeconds; Error = $err }
    } finally {
        $pool.Close(); $pool.Dispose()
    }
}

function Get-Mbps {
    param([int64]$Bytes, [double]$Seconds)
    if ($Seconds -le 0 -or $Bytes -le 0) { return 0 }
    return [math]::Round(($Bytes * 8) / $Seconds / 1MB, 2)
}

function Get-Latency {
    param([string]$Target = '1.1.1.1', [int]$Count = 5)
    try {
        $p = New-Object System.Net.NetworkInformation.Ping
        $vals = @()
        for ($i = 0; $i -lt $Count; $i++) {
            $r = $p.Send($Target, 2000)
            if ($r.Status -eq 'Success') { $vals += [int]$r.RoundtripTime }
            Start-Sleep -Milliseconds 120
        }
        if ($vals.Count -eq 0) { return $null }
        return [int](($vals | Measure-Object -Average).Average)
    } catch { return $null }
}

function Get-WifiSnapshot {
    $out = [ordered]@{ Ssid = ''; Channel = ''; Signal = ''; Radio = ''; LinkMbps = '' }
    try {
        $ad = Get-NetAdapter -ErrorAction SilentlyContinue |
              Where-Object { $_.Status -eq 'Up' -and ($_.PhysicalMediaType -match '802\.11|Wireless' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN') } |
              Select-Object -First 1
        if ($ad) { $out.LinkMbps = [string]$ad.LinkSpeed }
    } catch {}

    $lines = @()
    $f = $null
    try {
        $f = [IO.Path]::GetTempFileName()
        & cmd.exe /d /c "netsh wlan show interfaces > `"$f`" 2>&1" | Out-Null
        $lines = @(Get-Content -LiteralPath $f -Encoding Oem -ErrorAction SilentlyContinue)
    } catch {} finally { if ($f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }

    foreach ($l in $lines) {
        if ($l -match '^\s*SSID\s*:\s*(.+?)\s*$')      { $out.Ssid = $matches[1] }
        if ($l -match ':\s*(\d{1,3})\s*%\s*$')          { $out.Signal = $matches[1] }
        if ($l -match ':\s*(802\.11\S*)\s*$')           { $out.Radio = $matches[1] }
    }
    # канал - первое целочисленное поле вывода, не зависит от языка
    $ints = @()
    foreach ($l in $lines) { if ($l -match '^\s*[^:]{1,60}:\s*(\d{1,6})\s*$') { $ints += $matches[1] } }
    if ($ints.Count -ge 1) { $out.Channel = $ints[0] }
    return $out
}

function Show-Comparison {
    if (-not (Test-Path $script:CsvPath)) {
        Say 'Журнал замеров пуст - сначала сделайте хотя бы один замер.' 'Yellow'
        return
    }
    $rows = @(Import-Csv -LiteralPath $script:CsvPath -Encoding UTF8)
    if ($rows.Count -eq 0) { Say 'Журнал пуст.' 'Yellow'; return }

    Say-Head 'Сравнение замеров (медиана по каждой метке)'
    $groups = $rows | Group-Object Label
    $fmt = "{0,-22} {1,6} {2,10} {3,10} {4,10} {5,8} {6,8}"
    Say ($fmt -f 'Метка', 'Замеров', 'Загр.1поток', 'Загр.много', 'Отдача', 'Пинг', 'Поднагр') 'White'
    Say ('-' * 84) 'DarkGray'

    foreach ($g in $groups) {
        $med = {
            param($name)
            $v = @($g.Group | ForEach-Object { [double]$_.$name } | Where-Object { $_ -gt 0 } | Sort-Object)
            if ($v.Count -eq 0) { return 0 }
            return [math]::Round($v[[int][math]::Floor($v.Count / 2)], 1)
        }
        Say ($fmt -f $g.Name, $g.Count, (& $med 'DownSingleMbps'), (& $med 'DownMultiMbps'),
                    (& $med 'UpMbps'), (& $med 'PingIdleMs'), (& $med 'PingLoadedMs')) 'Gray'
    }

    Say ''
    Say 'Как читать:' 'White'
    Say '  один поток сильно ниже многопоточного -> упирается в окно TCP и задержку' 'Gray'
    Say '  оба низкие -> упирается сам канал: радио, роутер или провайдер' 'Gray'
    Say '  пинг под нагрузкой много выше обычного -> переполнение буферов на линии' 'Gray'
}

function Main {
    if (-not (Test-Path $script:AppDir)) {
        New-Item -ItemType Directory -Path $script:AppDir -Force -ErrorAction SilentlyContinue | Out-Null
    }

    if ($Compare) { Show-Comparison; return }

    Say ''
    Say '  Speed Bench - pc-optimizer-lite' 'White'
    Say ("  метка: $Label,  прогонов: $Runs,  потоков: $Streams,  объём: $SizeMB МБ") 'DarkGray'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::DefaultConnectionLimit = 64
    [Net.ServicePointManager]::Expect100Continue = $false

    $wifi = Get-WifiSnapshot
    Say ''
    Say ("  Wi-Fi: $($wifi.Ssid)  канал $($wifi.Channel)  сигнал $($wifi.Signal)%  $($wifi.Radio)  линк $($wifi.LinkMbps)") 'DarkGray'

    $bytes = $SizeMB * 1MB

    # Проверяем, какой источник доступен, и честно говорим, если ни один.
    $probe = $null
    foreach ($u in $script:DownUrls) {
        $try = $u -f 1048576
        $res = Invoke-Parallel -Script $script:Worker -Arguments @($try, 20) -Count 1
        if ($res.Bytes -gt 0) { $script:DownUrl = $u; $probe = $u; break }
        Say ("  источник недоступен: " + ($u -replace '\?.*','') + " (" + $res.Error + ")") 'DarkYellow'
    }
    if (-not $probe) {
        Say ''
        Say '  Ни один тестовый сервер недоступен - замер невозможен.' 'Red'
        Say '  Проверьте интернет, прокси или брандмауэр и повторите.' 'Red'
        return
    }
    Say ("  тестовый сервер: " + ($probe -replace '\?.*','')) 'DarkGray'

    $results = @()

    for ($r = 1; $r -le $Runs; $r++) {
        Say-Head "Прогон $r из $Runs"

        $pingIdle = Get-Latency
        Say ("  пинг в покое:      {0} мс" -f $(if ($null -ne $pingIdle) { $pingIdle } else { 'н/д' })) 'Gray'

        $one = Invoke-Parallel -Script $script:Worker -Arguments @(($script:DownUrl -f $bytes), 60) -Count 1
        $oneMbps = Get-Mbps $one.Bytes $one.Seconds
        Say ("  загрузка 1 поток:  {0} Мбит/с" -f $oneMbps) 'White'
        if ($one.Error) { Say ("    ошибка: " + $one.Error) 'Red' }

        # многопоточная загрузка с одновременным замером задержки
        $pingJob = [powershell]::Create()
        $null = $pingJob.AddScript({
            param($Target)
            $p = New-Object System.Net.NetworkInformation.Ping
            $v = @()
            for ($i = 0; $i -lt 12; $i++) {
                $x = $p.Send($Target, 2000)
                if ($x.Status -eq 'Success') { $v += [int]$x.RoundtripTime }
                Start-Sleep -Milliseconds 250
            }
            if ($v.Count -eq 0) { return 0 }
            return [int](($v | Measure-Object -Average).Average)
        }).AddArgument('1.1.1.1')
        $pingHandle = $pingJob.BeginInvoke()

        $many = Invoke-Parallel -Script $script:Worker -Arguments @(($script:DownUrl -f $bytes), 60) -Count $Streams
        $manyMbps = Get-Mbps $many.Bytes $many.Seconds
        Say ("  загрузка $Streams потока: {0} Мбит/с" -f $manyMbps) 'White'
        if ($many.Error) { Say ("    ошибка: " + $many.Error) 'Red' }

        $pingLoaded = 0
        try { $pingLoaded = [int](@($pingJob.EndInvoke($pingHandle)) | Select-Object -Last 1) } catch {}
        $pingJob.Dispose()
        Say ("  пинг под нагрузкой: {0} мс" -f $pingLoaded) 'Gray'

        $upMbps = 0
        if (-not $NoUpload) {
            $up = Invoke-Parallel -Script $script:Uploader -Arguments @($script:UpUrl, $bytes, 60) -Count $Streams
            $upMbps = Get-Mbps $up.Bytes $up.Seconds
            Say ("  отдача $Streams потока:   {0} Мбит/с" -f $upMbps) 'White'
            if ($up.Error) { Say ("    ошибка отдачи: " + $up.Error) 'Red' }
        }

        $results += [pscustomobject]@{
            Time           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Label          = $Label
            DownSingleMbps = $oneMbps
            DownMultiMbps  = $manyMbps
            UpMbps         = $upMbps
            PingIdleMs     = $(if ($null -ne $pingIdle) { $pingIdle } else { 0 })
            PingLoadedMs   = $pingLoaded
            Ssid           = $wifi.Ssid
            Channel        = $wifi.Channel
            Signal         = $wifi.Signal
            Radio          = $wifi.Radio
            Link           = $wifi.LinkMbps
        }
    }

    if (Test-Path $script:CsvPath) {
        $results | Export-Csv -LiteralPath $script:CsvPath -NoTypeInformation -Encoding UTF8 -Append
    } else {
        $results | Export-Csv -LiteralPath $script:CsvPath -NoTypeInformation -Encoding UTF8
    }

    Say-Head 'Итог прогонов'
    $dm = [math]::Round((@($results.DownMultiMbps) | Measure-Object -Maximum).Maximum, 1)
    $ds = [math]::Round((@($results.DownSingleMbps) | Measure-Object -Maximum).Maximum, 1)
    $um = [math]::Round((@($results.UpMbps) | Measure-Object -Maximum).Maximum, 1)
    Say ("  лучшая загрузка: $ds Мбит/с в один поток, $dm Мбит/с в $Streams потока") 'White'
    Say ("  лучшая отдача:   $um Мбит/с") 'White'

    if ($ds -gt 0 -and $dm -gt ($ds * 2.5)) {
        Say ''
        Say '  Один поток втрое медленнее многопоточного: упирается в окно TCP и задержку,' 'Yellow'
        Say '  а не в скорость канала.' 'Yellow'
    } elseif ($dm -gt 0 -and $um -gt ($dm * 1.8)) {
        Say ''
        Say '  Отдача заметно выше загрузки: проблема в приёмном тракте, а не в канале.' 'Yellow'
    }

    Say ''
    Say "  Журнал: $($script:CsvPath)" 'DarkGray'
    Say '  Сравнить метки между собой: .\Speed-Bench.ps1 -Compare' 'DarkGray'
    Say ''
}

Main
