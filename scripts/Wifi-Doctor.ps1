#Requires -Version 5.1
<#
.SYNOPSIS
    Wi-Fi Doctor - проверка всех настроек Wi-Fi и сети Windows и устранение того,
    что мешает стабильной работе (стрим OBS, VTube Studio, онлайн-игры).

.DESCRIPTION
    Без ключей - только диагностика, ничего не меняется.
    -Fix     - применить безопасные исправления (перед каждым пишется бэкап).
    -Hard    - дополнительно тяжёлые сбросы (winsock/ip reset), нужна перезагрузка.
    -Restore - откатить изменения из файла бэкапа ('last' = последний).

.EXAMPLE
    .\Wifi-Doctor.ps1
    .\Wifi-Doctor.ps1 -Fix
    .\Wifi-Doctor.ps1 -Fix -Hard
    .\Wifi-Doctor.ps1 -Restore last
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$Hard,
    [string]$Restore,
    [switch]$NoRestartAdapter,
    [switch]$Menu
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$script:AppDir     = Join-Path $env:LOCALAPPDATA 'pc-optimizer-lite'
$script:Stamp      = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$script:Findings   = New-Object System.Collections.ArrayList
$script:Backup     = New-Object System.Collections.ArrayList
$script:LogLines   = New-Object System.Collections.ArrayList
$script:NeedReboot = $false
$script:NeedAdapterRestart = $false
$script:Wifi       = $null
$script:WlanInfo   = @{}

$script:NetClassKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'

# ---------------------------------------------------------------- вывод -----

function Say {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    $null = $script:LogLines.Add($Text)
}

function Say-Head {
    param([string]$Text)
    Say ''
    Say ("== " + $Text + " " + ('=' * [Math]::Max(3, 66 - $Text.Length))) 'Cyan'
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'BAD'  { 'Red' }
        default { 'DarkGray' }
    }
}

function Get-StatusMark {
    param([string]$Status)
    switch ($Status) {
        'OK'   { '[ OK ]' }
        'WARN' { '[ ?! ]' }
        'BAD'  { '[ !! ]' }
        default { '[ .. ]' }
    }
}

function Add-Finding {
    param(
        [string]$Id,
        [string]$Title,
        [ValidateSet('OK', 'WARN', 'BAD', 'INFO')][string]$Status,
        [string]$Detail = '',
        [string]$Advice = '',
        [string]$FixLabel = '',
        [scriptblock]$FixAction = $null,
        [switch]$HardOnly
    )
    $f = [pscustomobject]@{
        Id        = $Id
        Title     = $Title
        Status    = $Status
        Detail    = $Detail
        Advice    = $Advice
        FixLabel  = $FixLabel
        FixAction = $FixAction
        HardOnly  = [bool]$HardOnly
        FixResult = ''
    }
    $null = $script:Findings.Add($f)

    Say ("{0} {1}" -f (Get-StatusMark $Status), $Title) (Get-StatusColor $Status)
    if ($Detail) { foreach ($line in ($Detail -split "`n")) { Say ("        " + $line) 'Gray' } }
    if ($Advice) { foreach ($line in ($Advice -split "`n")) { Say ("        -> " + $line) 'DarkYellow' } }
}

# -------------------------------------------------------------- утилиты -----

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Invoke-Native {
    param([string]$File, [string[]]$Arguments = @())
    try {
        $out = & $File @Arguments 2>&1
        return @($out | ForEach-Object { [string]$_ })
    } catch {
        return @()
    }
}

# Разбирает вывод вида "  Метка  : значение" в хеш-таблицу.
function ConvertFrom-NetshPairs {
    param([string[]]$Lines)
    $h = @{}
    foreach ($l in $Lines) {
        if ($l -match '^\s*([^:]{1,60}?)\s*:\s*(.+?)\s*$') {
            $k = $matches[1].Trim()
            $v = $matches[2].Trim()
            if ($k -and -not $h.ContainsKey($k)) { $h[$k] = $v }
        }
    }
    return $h
}

# Ищет значение по нескольким вариантам названия (RU/EN локализации netsh).
function Get-PairValue {
    param([hashtable]$Pairs, [string[]]$Patterns)
    foreach ($p in $Patterns) {
        foreach ($k in $Pairs.Keys) {
            if ($k -match $p) { return $Pairs[$k] }
        }
    }
    return $null
}

function Add-BackupEntry {
    param([hashtable]$Entry)
    $null = $script:Backup.Add($Entry)
}

function Set-RegValueBacked {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )
    $old = $null
    $existed = $false
    if (Test-Path $Path) {
        $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($prop -and ($prop.PSObject.Properties.Name -contains $Name)) {
            $old = $prop.$Name
            $existed = $true
        }
    } else {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }
    Add-BackupEntry @{ kind = 'registry'; path = $Path; name = $Name; value = $old; existed = $existed; type = $Type }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($prop -and ($prop.PSObject.Properties.Name -contains $Name)) { return $prop.$Name }
    } catch {}
    return $null
}

function Get-WifiAdapter {
    $all = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    $wifi = @($all | Where-Object {
        $_.PhysicalMediaType -match '802\.11|Wireless' -or
        $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11' -or
        $_.Name -match 'Wi-?Fi|Беспровод'
    } | Where-Object { $_.InterfaceDescription -notmatch 'Direct|Virtual|Miniport|Bluetooth' })

    if (-not $wifi) { return $null }
    $up = @($wifi | Where-Object { $_.Status -eq 'Up' })
    if ($up.Count -gt 0) { return $up[0] }
    return $wifi[0]
}

function Get-WifiClassKey {
    param($Adapter)
    if (-not $Adapter) { return $null }
    $guid = [string]$Adapter.InterfaceGuid
    if (-not $guid) { return $null }
    try {
        foreach ($sub in (Get-ChildItem $script:NetClassKey -ErrorAction SilentlyContinue)) {
            if ($sub.PSChildName -notmatch '^\d{4}$') { continue }
            $id = Get-RegValue $sub.PSPath 'NetCfgInstanceId'
            if ($id -and ($id -eq $guid)) { return $sub.PSPath }
        }
    } catch {}
    return $null
}

function Test-HostReachable {
    param([string]$ComputerName, [int]$Port)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($ComputerName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(2500, $false)
        if ($ok) { try { $c.EndConnect($iar) } catch { $ok = $false } }
        $c.Close()
        return $ok
    } catch { return $false }
}

# ================================================================ ПРОВЕРКИ ===

function Check-Adapter {
    Say-Head 'Адаптер и драйвер'
    $ad = $script:Wifi
    if (-not $ad) {
        Add-Finding -Id 'adapter' -Title 'Wi-Fi адаптер не найден' -Status 'BAD' `
            -Detail 'Windows не видит ни одного беспроводного адаптера.' `
            -Advice 'Проверьте аппаратный переключатель / Fn-клавишу Wi-Fi и драйвер в Диспетчере устройств.'
        return
    }

    $drvDate = ''
    try { if ($ad.DriverDate) { $drvDate = ([datetime]$ad.DriverDate).ToString('dd.MM.yyyy') } } catch { $drvDate = [string]$ad.DriverDate }

    $detail = @(
        "Адаптер:   $($ad.Name) - $($ad.InterfaceDescription)"
        "Состояние: $($ad.Status), скорость линка: $($ad.LinkSpeed)"
        "MAC:       $($ad.MacAddress)"
        "Драйвер:   $($ad.DriverVersion) от $drvDate"
    ) -join "`n"

    if ($ad.Status -eq 'Disabled' -or $ad.AdminStatus -eq 'Down') {
        Add-Finding -Id 'adapter.disabled' -Title 'Wi-Fi адаптер выключен' -Status 'BAD' -Detail $detail `
            -FixLabel 'Включить адаптер' -FixAction { Enable-NetAdapter -Name $script:Wifi.Name -Confirm:$false -ErrorAction Stop }
    } elseif ($ad.Status -ne 'Up') {
        Add-Finding -Id 'adapter.down' -Title "Адаптер не подключён к сети (статус: $($ad.Status))" -Status 'WARN' -Detail $detail `
            -Advice 'Часть проверок будет пропущена. Подключитесь к своей сети и запустите ещё раз.'
    } else {
        Add-Finding -Id 'adapter' -Title 'Wi-Fi адаптер работает' -Status 'OK' -Detail $detail
    }

    try {
        if ($ad.DriverDate) {
            $age = (New-TimeSpan -Start ([datetime]$ad.DriverDate) -End (Get-Date)).Days
            if ($age -gt 1095) {
                Add-Finding -Id 'adapter.driver' -Title "Драйвер Wi-Fi старый (лет: $([math]::Round($age/365,1)))" -Status 'WARN' `
                    -Detail "Версия $($ad.DriverVersion) от $drvDate." `
                    -Advice 'Скачайте свежий драйвер с сайта производителя ноутбука или чипа (Intel/Realtek/MediaTek/Qualcomm). Драйвер из Windows Update часто старый и даёт обрывы.'
            }
        }
    } catch {}
}

function Check-PowerManagement {
    Say-Head 'Энергосбережение адаптера (главная причина обрывов)'
    $ad = $script:Wifi
    if (-not $ad) { return }

    $key = Get-WifiClassKey $ad
    if ($key) {
        $pnp = Get-RegValue $key 'PnPCapabilities'
        if ($null -eq $pnp) { $pnp = 0 }
        if (($pnp -band 0x18) -ne 0x18) {
            Add-Finding -Id 'power.pnp' -Title 'Windows разрешено отключать Wi-Fi адаптер для экономии энергии' -Status 'BAD' `
                -Detail "PnPCapabilities = $pnp (нужно 24). Из-за этого адаптер засыпает: пинг скачет, стрим рвётся, игра отваливается." `
                -FixLabel 'Запретить отключение адаптера для экономии энергии' `
                -FixAction {
                    $k = Get-WifiClassKey $script:Wifi
                    Set-RegValueBacked -Path $k -Name 'PnPCapabilities' -Value 24 -Type DWord
                    $script:NeedAdapterRestart = $true
                }
        } else {
            Add-Finding -Id 'power.pnp' -Title 'Отключение адаптера для экономии энергии запрещено' -Status 'OK'
        }
    } else {
        Add-Finding -Id 'power.pnp' -Title 'Не удалось найти ключ реестра адаптера' -Status 'INFO' `
            -Advice 'Проверьте вручную: Диспетчер устройств -> адаптер -> Управление электропитанием -> снять галочку "Разрешить отключение этого устройства".'
    }

    try {
        $pm = Get-NetAdapterPowerManagement -Name $ad.Name -ErrorAction Stop
        $bad = @()
        if ($pm.SelectiveSuspend -eq 'Enabled')         { $bad += 'SelectiveSuspend' }
        if ($pm.DeviceSleepOnDisconnect -eq 'Enabled')  { $bad += 'DeviceSleepOnDisconnect' }
        if ($bad.Count -gt 0) {
            Add-Finding -Id 'power.selective' -Title "Включён режим сна адаптера: $($bad -join ', ')" -Status 'WARN' `
                -FixLabel 'Отключить сон адаптера' `
                -FixAction {
                    $p = Get-NetAdapterPowerManagement -Name $script:Wifi.Name -ErrorAction Stop
                    Add-BackupEntry @{ kind = 'adapterPm'; name = $script:Wifi.Name
                                       selectiveSuspend = [string]$p.SelectiveSuspend
                                       deviceSleep = [string]$p.DeviceSleepOnDisconnect }
                    if ($p.SelectiveSuspend -eq 'Enabled')        { $p.SelectiveSuspend = 'Disabled' }
                    if ($p.DeviceSleepOnDisconnect -eq 'Enabled') { $p.DeviceSleepOnDisconnect = 'Disabled' }
                    Set-NetAdapterPowerManagement -InputObject $p -ErrorAction Stop
                }
        } else {
            Add-Finding -Id 'power.selective' -Title 'Режимы сна адаптера отключены' -Status 'OK'
        }
    } catch {
        Add-Finding -Id 'power.selective' -Title 'Драйвер не сообщает параметры сна адаптера' -Status 'INFO'
    }
}

function Check-PowerPlan {
    Say-Head 'Схема электропитания: режим энергосбережения Wi-Fi'
    $sub = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'   # Параметры адаптера беспроводной сети
    $set = '12bbebe6-58d6-4636-95bb-3217ef867c1a'   # Режим энергосбережения

    $out = Invoke-Native 'powercfg.exe' @('/query', 'SCHEME_CURRENT', $sub, $set)
    $hex = [regex]::Matches(($out -join "`n"), '0x[0-9a-fA-F]{8}')
    if ($hex.Count -lt 2) {
        Add-Finding -Id 'power.plan' -Title 'Не удалось прочитать параметр энергосбережения Wi-Fi в схеме питания' -Status 'INFO'
        return
    }
    $ac = [Convert]::ToInt32($hex[$hex.Count - 2].Value, 16)
    $dc = [Convert]::ToInt32($hex[$hex.Count - 1].Value, 16)
    $names = @('Максимальная производительность', 'Низкий уровень энергосбережения',
               'Средний уровень энергосбережения', 'Максимальное энергосбережение')
    $acName = if ($ac -lt $names.Count) { $names[$ac] } else { "режим $ac" }
    $dcName = if ($dc -lt $names.Count) { $names[$dc] } else { "режим $dc" }

    if ($ac -ne 0 -or $dc -ne 0) {
        $fixPlan = [scriptblock]::Create(@"
            Add-BackupEntry @{ kind = 'powercfg'; sub = '$sub'; setting = '$set'; ac = $ac; dc = $dc }
            Invoke-Native 'powercfg.exe' @('/setacvalueindex', 'SCHEME_CURRENT', '$sub', '$set', '0') | Out-Null
            Invoke-Native 'powercfg.exe' @('/setdcvalueindex', 'SCHEME_CURRENT', '$sub', '$set', '0') | Out-Null
            Invoke-Native 'powercfg.exe' @('/setactive', 'SCHEME_CURRENT') | Out-Null
"@)
        Add-Finding -Id 'power.plan' -Title 'Схема питания режет мощность Wi-Fi' -Status 'BAD' `
            -Detail "От сети: $acName`nОт батареи: $dcName`nИменно это даёт просадки скорости и лаги, когда ноутбук 'ничего не делает'." `
            -FixLabel 'Поставить максимальную производительность Wi-Fi' `
            -FixAction $fixPlan
    } else {
        Add-Finding -Id 'power.plan' -Title 'Wi-Fi в схеме питания: максимальная производительность' -Status 'OK'
    }
}

function Check-AdvancedProps {
    Say-Head 'Расширенные настройки драйвера Wi-Fi'
    $ad = $script:Wifi
    if (-not $ad) { return }

    $props = @(Get-NetAdapterAdvancedProperty -Name $ad.Name -ErrorAction SilentlyContinue)
    if ($props.Count -eq 0) {
        Add-Finding -Id 'adv' -Title 'Драйвер не отдаёт расширенные настройки' -Status 'INFO'
        return
    }

    # Возвращает RegistryValue, соответствующий первому DisplayValue по маске.
    $pick = {
        param($p, $pattern)
        if (-not $p.ValidDisplayValues) { return $null }
        for ($i = 0; $i -lt $p.ValidDisplayValues.Count; $i++) {
            if ($p.ValidDisplayValues[$i] -match $pattern) {
                if ($p.ValidRegistryValues -and $i -lt $p.ValidRegistryValues.Count) {
                    return @{ reg = $p.ValidRegistryValues[$i]; disp = $p.ValidDisplayValues[$i] }
                }
            }
        }
        return $null
    }

    $rules = @(
        @{ Id = 'adv.powersave'; Match = 'Power Save|Power Saving|Энергосбереж|PowerSave|Power Management'
           Want = 'Max(imum)? Performance|Disabled|Отключ|Максимальная производ|No Power Sav|Highest Performance'
           Bad  = '.*'; Status = 'BAD'
           Why  = 'Энергосбережение внутри драйвера - вторая по частоте причина обрывов и пинга "лесенкой".' }
        @{ Id = 'adv.roaming'; Match = 'Roaming|Роуминг'
           Want = 'Medium|Средн|3'
           Bad  = 'Highest|Aggressive|Высок|Агресс|5'; Status = 'WARN'
           Why  = 'Слишком агрессивный роуминг заставляет адаптер постоянно перескакивать между точками и рвать соединение.' }
        @{ Id = 'adv.ucoal'; Match = 'Packet Coalescing|Объединение пакетов'
           Want = 'Disabled|Отключ'
           Bad  = 'Enabled|Включ'; Status = 'WARN'
           Why  = 'Объединение пакетов экономит энергию ценой задержки - для игр и стрима вредно.' }
    )

    $found = $false
    foreach ($r in $rules) {
        foreach ($p in ($props | Where-Object { $_.DisplayName -match $r.Match })) {
            $found = $true
            $cur = [string]$p.DisplayValue
            if ($cur -notmatch $r.Want -and $cur -match $r.Bad) {
                $target = & $pick $p $r.Want
                if (-not $target) {
                    Add-Finding -Id $r.Id -Title "$($p.DisplayName): $cur" -Status $r.Status `
                        -Detail $r.Why -Advice 'Подходящего значения в списке драйвера нет - поменяйте вручную в свойствах адаптера.'
                    continue
                }
                $kw  = $p.RegistryKeyword
                $reg = $target.reg
                $oldReg = $p.RegistryValue
                $name = $ad.Name
                Add-Finding -Id $r.Id -Title "$($p.DisplayName) = '$cur'" -Status $r.Status `
                    -Detail $r.Why `
                    -FixLabel "Переключить '$($p.DisplayName)' на '$($target.disp)'" `
                    -FixAction ([scriptblock]::Create(@"
                        Add-BackupEntry @{ kind = 'advprop'; adapter = '$name'; keyword = '$kw'; value = @('$($oldReg -join "','")') }
                        Set-NetAdapterAdvancedProperty -Name '$name' -RegistryKeyword '$kw' -RegistryValue '$reg' -NoRestart -ErrorAction Stop
                        `$script:NeedAdapterRestart = `$true
"@))
            } else {
                Add-Finding -Id $r.Id -Title "$($p.DisplayName) = '$cur'" -Status 'OK'
            }
        }
    }

    # Предпочитаемый диапазон - трогаем только если 5 ГГц уже доказанно работает.
    $bandProp = @($props | Where-Object { $_.DisplayName -match 'Preferred Band|Band Preference|Предпочит.*диапазон' })[0]
    if ($bandProp) {
        $found = $true
        $onFive = ($script:WlanInfo.Band5 -eq $true)
        $cur = [string]$bandProp.DisplayValue
        if ($cur -match '2\.?4' -and $onFive) {
            $t = & $pick $bandProp '5'
            if ($t) {
                $kw = $bandProp.RegistryKeyword; $reg = $t.reg; $name = $ad.Name
                $oldReg = $bandProp.RegistryValue
                Add-Finding -Id 'adv.band' -Title "Драйвер предпочитает 2.4 ГГц, хотя вы сидите на 5 ГГц" -Status 'WARN' `
                    -Detail 'При каждом переподключении ноутбук будет сползать на медленный и забитый 2.4 ГГц.' `
                    -FixLabel "Предпочитать 5 ГГц" `
                    -FixAction ([scriptblock]::Create(@"
                        Add-BackupEntry @{ kind = 'advprop'; adapter = '$name'; keyword = '$kw'; value = @('$($oldReg -join "','")') }
                        Set-NetAdapterAdvancedProperty -Name '$name' -RegistryKeyword '$kw' -RegistryValue '$reg' -NoRestart -ErrorAction Stop
                        `$script:NeedAdapterRestart = `$true
"@))
            }
        } else {
            Add-Finding -Id 'adv.band' -Title "Предпочитаемый диапазон = '$cur'" -Status 'INFO'
        }
    }

    if (-not $found) {
        Add-Finding -Id 'adv' -Title 'Проблемных расширенных настроек драйвера не найдено' -Status 'OK'
    }
}

function Check-Services {
    Say-Head 'Службы, без которых Wi-Fi не работает'
    $svcs = @(
        @{ Name = 'WlanSvc';  Title = 'Автонастройка WLAN' }
        @{ Name = 'Dhcp';     Title = 'DHCP-клиент' }
        @{ Name = 'Dnscache'; Title = 'DNS-клиент' }
        @{ Name = 'NlaSvc';   Title = 'Сведения о сетевых подключениях' }
        @{ Name = 'WcmSvc';   Title = 'Диспетчер подключений Windows' }
    )
    $problem = $false
    foreach ($s in $svcs) {
        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        $st = (Get-CimInstance Win32_Service -Filter "Name='$($s.Name)'" -ErrorAction SilentlyContinue).StartMode
        if ($svc.Status -ne 'Running' -or $st -eq 'Disabled') {
            $problem = $true
            $n = $s.Name
            Add-Finding -Id "svc.$n" -Title "Служба '$($s.Title)' ($n): $($svc.Status), запуск: $st" -Status 'BAD' `
                -Detail 'Часто ломается "оптимизаторами", которые отключают службы пачками.' `
                -FixLabel "Запустить службу $n" `
                -FixAction ([scriptblock]::Create(@"
                    Add-BackupEntry @{ kind = 'service'; name = '$n'; startMode = '$st'; status = '$($svc.Status)' }
                    Set-Service -Name '$n' -StartupType Automatic -ErrorAction SilentlyContinue
                    Start-Service -Name '$n' -ErrorAction Stop
"@))
        }
    }
    if (-not $problem) {
        Add-Finding -Id 'svc' -Title 'Все сетевые службы запущены' -Status 'OK'
    }
}

function Check-WlanState {
    Say-Head 'Текущее подключение'
    $lines = Invoke-Native 'netsh.exe' @('wlan', 'show', 'interfaces')
    $pairs = ConvertFrom-NetshPairs $lines

    $ssid   = $null
    foreach ($k in $pairs.Keys) { if ($k -eq 'SSID') { $ssid = $pairs[$k] } }
    $radio  = Get-PairValue $pairs @('^Radio type', '^Тип радио')
    $chan   = Get-PairValue $pairs @('^Channel$', '^Канал$')
    $auth   = Get-PairValue $pairs @('Authentication', 'подлинност')
    $rx     = Get-PairValue $pairs @('Receive rate', 'Скорость приема', 'Скорость приёма')
    $tx     = Get-PairValue $pairs @('Transmit rate', 'Скорость передачи')

    $signal = $null
    foreach ($l in $lines) { if ($l -match ':\s*(\d{1,3})\s*%\s*$') { $signal = [int]$matches[1]; break } }

    $script:WlanInfo = @{ Ssid = $ssid; Channel = $chan; Signal = $signal; Radio = $radio }
    if ($chan -match '^\d+$') { $script:WlanInfo.Band5 = ([int]$chan -gt 14) }

    if (-not $ssid) {
        Add-Finding -Id 'wlan.state' -Title 'Нет активного Wi-Fi подключения' -Status 'WARN' `
            -Advice 'Подключитесь к своей сети и запустите проверку снова - часть проверок работает только на живом подключении.'
        return
    }

    $detail = @(
        "Сеть:     $ssid"
        "Канал:    $chan   Режим: $radio"
        "Сигнал:   $(if ($null -ne $signal) { "$signal%" } else { 'н/д' })"
        "Скорость: приём $rx / передача $tx"
        "Защита:   $auth"
    ) -join "`n"
    Add-Finding -Id 'wlan.state' -Title "Подключено к '$ssid'" -Status 'OK' -Detail $detail

    if ($null -ne $signal) {
        if ($signal -lt 40) {
            Add-Finding -Id 'wlan.signal' -Title "Слабый сигнал: $signal%" -Status 'BAD' `
                -Detail 'Ниже 40% начинаются потери пакетов, падение битрейта и обрывы стрима. Настройками это не лечится.' `
                -Advice 'Ближе к роутеру / убрать препятствия (стены, зеркала, микроволновка), либо 2.4 ГГц вместо 5 ГГц на дальней дистанции.'
        } elseif ($signal -lt 65) {
            Add-Finding -Id 'wlan.signal' -Title "Средний сигнал: $signal%" -Status 'WARN' `
                -Advice 'Для стабильного стрима лучше держать 70%+.'
        } else {
            Add-Finding -Id 'wlan.signal' -Title "Сигнал в норме: $signal%" -Status 'OK'
        }
    }

    if ($chan -match '^\d+$' -and [int]$chan -le 14) {
        Add-Finding -Id 'wlan.band' -Title "Вы на диапазоне 2.4 ГГц (канал $chan)" -Status 'WARN' `
            -Detail 'Это самый забитый диапазон: соседский Wi-Fi, Bluetooth, микроволновки. Для OBS и игр он даёт плавающий пинг.' `
            -Advice 'Если роутер двухдиапазонный - подключитесь к сети 5 ГГц (обычно SSID с суффиксом _5G).'
    }

    if ($radio -and $radio -match '802\.11(b|g)\b') {
        Add-Finding -Id 'wlan.radio' -Title "Соединение на древнем стандарте: $radio" -Status 'BAD' `
            -Advice 'Проверьте режим сети в роутере (должен быть минимум 802.11n), иначе скорость упрётся в десятки мегабит.'
    }

    # Загруженность эфира
    $nets = Invoke-Native 'netsh.exe' @('wlan', 'show', 'networks', 'mode=bssid')
    $ssidCount = @($nets | Where-Object { $_ -match '^\s*SSID\s+\d+\s*:' }).Count
    if ($ssidCount -gt 0) {
        $sameChan = 0
        if ($chan -match '^\d+$') {
            $sameChan = @($nets | Where-Object { $_ -match '(?:Channel|Канал)\s*:\s*' + [regex]::Escape($chan) + '\s*$' }).Count
        }
        $st = if ($sameChan -ge 4) { 'WARN' } else { 'INFO' }
        Add-Finding -Id 'wlan.air' -Title "В эфире видно сетей: $ssidCount, на вашем канале ($chan): $sameChan" -Status $st `
            -Advice $(if ($sameChan -ge 4) { 'Канал перегружен. В настройках роутера выберите свободный канал (для 2.4 ГГц - 1, 6 или 11).' } else { '' })
    }

    # История обрывов
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-WLAN-AutoConfig/Operational'
            StartTime = (Get-Date).AddDays(-7)
            Id        = 8003
        } -MaxEvents 400 -ErrorAction Stop)
        if ($ev.Count -ge 15) {
            Add-Finding -Id 'wlan.drops' -Title "Обрывов Wi-Fi за 7 дней: $($ev.Count)" -Status 'BAD' `
                -Detail 'Это много. Обычно виновато энергосбережение адаптера, агрессивный роуминг или старый драйвер - всё выше по списку.'
        } elseif ($ev.Count -gt 0) {
            Add-Finding -Id 'wlan.drops' -Title "Обрывов Wi-Fi за 7 дней: $($ev.Count)" -Status 'INFO'
        }
    } catch {}
}

function Check-Profiles {
    Say-Head 'Сохранённые сети (автоподключение к чужим/слабым точкам)'
    $tmpRoot = $env:TEMP
    if (-not $tmpRoot) { $tmpRoot = [IO.Path]::GetTempPath() }
    $tmp = Join-Path $tmpRoot ("wifidoctor-prof-" + $script:Stamp)
    try { New-Item -ItemType Directory -Path $tmp -Force -ErrorAction Stop | Out-Null }
    catch {
        Add-Finding -Id 'profiles' -Title 'Не удалось прочитать список сохранённых сетей' -Status 'INFO' `
            -Detail $_.Exception.Message
        return
    }

    Invoke-Native 'netsh.exe' @('wlan', 'export', 'profile', "folder=$tmp") | Out-Null
    $files = @(Get-ChildItem -Path $tmp -Filter '*.xml' -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        Add-Finding -Id 'profiles' -Title 'Сохранённых Wi-Fi профилей не найдено' -Status 'INFO'
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    $current = $script:WlanInfo.Ssid
    $autoOther = @()
    $openNets  = @()
    $currentManual = $false

    foreach ($f in $files) {
        try {
            [xml]$x = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction Stop
            $name = [string]$x.WLANProfile.name
            $mode = [string]$x.WLANProfile.connectionMode
            $auth = [string]$x.WLANProfile.MSM.security.authEncryption.authentication
            if ($name -eq $current) {
                if ($mode -ne 'auto') { $currentManual = $true }
            } elseif ($mode -eq 'auto') {
                $autoOther += $name
            }
            if ($auth -eq 'open' -and $mode -eq 'auto') { $openNets += $name }
        } catch {}
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

    Add-Finding -Id 'profiles.count' -Title "Сохранённых сетей: $($files.Count)" -Status 'INFO' `
        -Detail $(if ($current) { "Текущая: $current" } else { '' })

    if ($autoOther.Count -gt 0) {
        $list = ($autoOther | Select-Object -First 12) -join ', '
        if ($autoOther.Count -gt 12) { $list += " ... (+$($autoOther.Count - 12))" }
        $names = $autoOther -join '|~|'
        Add-Finding -Id 'profiles.auto' -Title "Автоподключение включено у $($autoOther.Count) посторонних сетей" -Status 'WARN' `
            -Detail "$list`nНоутбук может сам уйти с вашей сети на соседскую/гостевую/телефонную точку - для стрима это мгновенный разрыв." `
            -FixLabel 'Оставить автоподключение только для текущей сети' `
            -FixAction ([scriptblock]::Create(@"
                foreach (`$n in ('$names' -split '\|~\|')) {
                    Add-BackupEntry @{ kind = 'wlanProfileMode'; name = `$n; mode = 'auto' }
                    Invoke-Native 'netsh.exe' @('wlan','set','profileparameter',"name=`$n",'connectionmode=manual') | Out-Null
                }
"@))
    } else {
        Add-Finding -Id 'profiles.auto' -Title 'Лишних сетей с автоподключением нет' -Status 'OK'
    }

    if ($openNets.Count -gt 0) {
        Add-Finding -Id 'profiles.open' -Title "Открытых (незащищённых) сетей с автоподключением: $($openNets.Count)" -Status 'BAD' `
            -Detail (($openNets | Select-Object -First 10) -join ', ') `
            -Advice 'Такие профили лучше вообще удалить: netsh wlan delete profile name="ИМЯ"'
    }

    if ($currentManual -and $current) {
        $cn = $current
        Add-Finding -Id 'profiles.current' -Title "У текущей сети '$cn' выключено автоподключение" -Status 'WARN' `
            -Detail 'После сна/перезагрузки Wi-Fi не поднимется сам.' `
            -FixLabel 'Включить автоподключение для текущей сети' `
            -FixAction ([scriptblock]::Create(@"
                Add-BackupEntry @{ kind = 'wlanProfileMode'; name = '$cn'; mode = 'manual' }
                Invoke-Native 'netsh.exe' @('wlan','set','profileparameter',"name=$cn",'connectionmode=auto') | Out-Null
"@))
    }
}

function Check-MacRandomization {
    Say-Head 'Случайные MAC-адреса'
    $ad = $script:Wifi
    if (-not $ad) { return }
    $perm = [string]$ad.PermanentAddress
    $cur  = [string]$ad.MacAddress
    if ($perm -and $cur -and ($perm.Replace('-', '') -ne $cur.Replace('-', ''))) {
        $ssid = $script:WlanInfo.Ssid
        $fix = $null
        if ($ssid) {
            $fix = [scriptblock]::Create(@"
                Add-BackupEntry @{ kind = 'wlanProfileRandom'; name = '$ssid'; value = 'enable' }
                Invoke-Native 'netsh.exe' @('wlan','set','profileparameter',"name=$ssid",'randomization=disable') | Out-Null
"@)
        }
        Add-Finding -Id 'mac.random' -Title 'Включены случайные MAC-адреса' -Status 'WARN' `
            -Detail "Текущий MAC $cur, аппаратный $perm.`nЛомает привязку IP в роутере, родительский контроль, приоритет QoS и белые списки MAC - выглядит как 'интернет то есть, то нет'." `
            -FixLabel 'Отключить рандомизацию MAC для текущей сети' -FixAction $fix
    } else {
        Add-Finding -Id 'mac.random' -Title 'Используется настоящий MAC-адрес' -Status 'OK'
    }
}

function Check-Hotspots {
    Say-Head 'Автоподключение к открытым точкам'
    $path = 'HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config'
    $oem  = Get-RegValue $path 'AutoConnectAllowedOEM'
    if ($oem -eq 1) {
        Add-Finding -Id 'hotspot.oem' -Title 'Windows разрешено само цепляться к предложенным открытым точкам' -Status 'WARN' `
            -Detail 'Ноутбук может перескочить на бесплатный хотспот вместо вашей сети.' `
            -FixLabel 'Запретить автоподключение к открытым точкам' `
            -FixAction { Set-RegValueBacked -Path 'HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config' -Name 'AutoConnectAllowedOEM' -Value 0 -Type DWord }
    } else {
        Add-Finding -Id 'hotspot.oem' -Title 'Автоподключение к открытым точкам выключено' -Status 'OK'
    }
}

function Check-IpConfig {
    Say-Head 'IP-адрес и шлюз'
    $ad = $script:Wifi
    if (-not $ad -or $ad.Status -ne 'Up') { return }

    $cfg = Get-NetIPConfiguration -InterfaceIndex $ad.ifIndex -ErrorAction SilentlyContinue
    $ip  = $null
    if ($cfg -and $cfg.IPv4Address) { $ip = @($cfg.IPv4Address)[0].IPAddress }
    $gw  = $null
    if ($cfg -and $cfg.IPv4DefaultGateway) { $gw = @($cfg.IPv4DefaultGateway)[0].NextHop }

    if (-not $ip -or $ip -like '169.254.*') {
        Add-Finding -Id 'ip.apipa' -Title 'DHCP не выдал адрес (APIPA 169.254.x.x)' -Status 'BAD' `
            -Detail "Текущий IPv4: $ip. Интернета в таком состоянии не будет." `
            -FixLabel 'Перезапросить адрес у роутера' `
            -FixAction {
                Invoke-Native 'ipconfig.exe' @('/release') | Out-Null
                Invoke-Native 'ipconfig.exe' @('/renew') | Out-Null
            }
    } elseif (-not $gw) {
        Add-Finding -Id 'ip.gw' -Title 'Не задан основной шлюз' -Status 'BAD' `
            -Detail "IPv4: $ip, шлюза нет - трафик наружу не пойдёт." `
            -Advice 'Проверьте, не прописан ли вручную статический IP без шлюза (Параметры -> Сеть -> Wi-Fi -> Изменить параметры IP).'
    } else {
        Add-Finding -Id 'ip' -Title "IP-адрес получен: $ip (шлюз $gw)" -Status 'OK'
    }

    $ifi = Get-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ifi -and $ifi.Dhcp -eq 'Disabled') {
        Add-Finding -Id 'ip.static' -Title 'Адрес задан вручную (статический IP)' -Status 'WARN' `
            -Detail "IPv4: $ip. Если сеть/роутер сменились, такой адрес просто перестаёт работать." `
            -Advice 'Если делали это не намеренно - верните автоматическое получение IP и DNS.'
    }

    if ($gw) {
        $ok = Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue
        if (-not $ok) {
            Add-Finding -Id 'ip.gwping' -Title "Роутер ($gw) не отвечает на ping" -Status 'WARN' `
                -Detail 'Либо роутер блокирует ping, либо связь с ним действительно нестабильна.'
        }
    }
}

function Check-Dns {
    Say-Head 'DNS'
    $ad = $script:Wifi
    if (-not $ad -or $ad.Status -ne 'Up') { return }

    $servers = @((Get-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    if ($servers.Count -eq 0) {
        Add-Finding -Id 'dns.none' -Title 'DNS-серверы не заданы' -Status 'BAD' `
            -FixLabel 'Вернуть DNS от роутера' `
            -FixAction {
                Add-BackupEntry @{ kind = 'dns'; ifIndex = $script:Wifi.ifIndex; servers = @() }
                Set-DnsClientServerAddress -InterfaceIndex $script:Wifi.ifIndex -ResetServerAddresses -ErrorAction Stop
            }
        return
    }

    $alive = @()
    $dead  = @()
    foreach ($s in $servers) {
        $ok = $false
        try {
            $r = Resolve-DnsName -Name 'www.microsoft.com' -Server $s -Type A -QuickTimeout -DnsOnly -ErrorAction Stop
            if ($r) { $ok = $true }
        } catch { $ok = $false }
        if ($ok) { $alive += $s } else { $dead += $s }
    }

    $detail = "Прописаны: $($servers -join ', ')"
    if ($alive.Count -eq 0) {
        $bak = $servers -join ','
        Add-Finding -Id 'dns.dead' -Title 'Ни один DNS-сервер не отвечает' -Status 'BAD' `
            -Detail "$detail`nКлассика после удалённого VPN/античита: сайты не открываются, хотя 'интернет есть'." `
            -FixLabel 'Сбросить DNS на выдаваемый роутером' `
            -FixAction ([scriptblock]::Create(@"
                Add-BackupEntry @{ kind = 'dns'; ifIndex = $($ad.ifIndex); servers = @('$($servers -join "','")') }
                Set-DnsClientServerAddress -InterfaceIndex $($ad.ifIndex) -ResetServerAddresses -ErrorAction Stop
                Invoke-Native 'ipconfig.exe' @('/flushdns') | Out-Null
"@))
    } elseif ($dead.Count -gt 0) {
        Add-Finding -Id 'dns.partial' -Title "Часть DNS-серверов не отвечает: $($dead -join ', ')" -Status 'WARN' `
            -Detail "$detail`nПока Windows опрашивает мёртвый сервер, страницы открываются с задержкой в секунды."
    } else {
        Add-Finding -Id 'dns' -Title 'DNS-серверы отвечают' -Status 'OK' -Detail $detail
    }
}

function Check-Proxy {
    Say-Head 'Прокси (частая причина "интернет есть, а ничего не грузится")'
    $inet = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $enabled = Get-RegValue $inet 'ProxyEnable'
    $server  = [string](Get-RegValue $inet 'ProxyServer')
    $auto    = [string](Get-RegValue $inet 'AutoConfigURL')

    $problem = $false
    if ($enabled -eq 1 -and $server) {
        $h = $server; $p = 80
        if ($server -match '^(?:[^=;]*=)?(?:https?://)?([^:;/]+):(\d+)') { $h = $matches[1]; $p = [int]$matches[2] }
        $reachable = Test-HostReachable -ComputerName $h -Port $p
        if (-not $reachable) {
            $problem = $true
            Add-Finding -Id 'proxy.dead' -Title "Включён нерабочий прокси: $server" -Status 'BAD' `
                -Detail 'Прокси не отвечает - весь трафик браузеров и части приложений уходит в никуда. Обычно остаётся после VPN, "ускорителей" или вируса.' `
                -FixLabel 'Отключить прокси' `
                -FixAction {
                    Set-RegValueBacked -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name 'ProxyEnable' -Value 0 -Type DWord
                    Invoke-Native 'netsh.exe' @('winhttp', 'reset', 'proxy') | Out-Null
                }
        } else {
            Add-Finding -Id 'proxy' -Title "Прокси включён и отвечает: $server" -Status 'INFO' `
                -Advice 'Если вы его не настраивали осознанно - выключите: Параметры -> Сеть и Интернет -> Прокси.'
        }
    }

    if ($auto) {
        $problem = $true
        Add-Finding -Id 'proxy.pac' -Title "Задан скрипт автонастройки прокси: $auto" -Status 'WARN' `
            -Detail 'Если скрипт недоступен, каждое соединение ждёт таймаута - страницы открываются очень долго.' `
            -FixLabel 'Убрать скрипт автонастройки' `
            -FixAction {
                $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                $old = [string](Get-RegValue $k 'AutoConfigURL')
                Add-BackupEntry @{ kind = 'registry'; path = $k; name = 'AutoConfigURL'; value = $old; existed = $true; type = 'String' }
                Remove-ItemProperty -Path $k -Name 'AutoConfigURL' -ErrorAction Stop
            }
    }

    $wh = Invoke-Native 'netsh.exe' @('winhttp', 'show', 'proxy')
    $whLine = ($wh -join ' ')
    if ($whLine -match '([A-Za-z0-9\.\-]+):(\d{2,5})') {
        $whProxy = $matches[0]
        Add-Finding -Id 'proxy.winhttp' -Title "Системный (WinHTTP) прокси: $whProxy" -Status 'WARN' `
            -Detail 'Через него ходят обновления, магазин, часть лаунчеров.' `
            -FixLabel 'Сбросить системный прокси' `
            -FixAction ([scriptblock]::Create(@"
                Add-BackupEntry @{ kind = 'winhttpProxy'; value = '$whProxy' }
                Invoke-Native 'netsh.exe' @('winhttp', 'reset', 'proxy') | Out-Null
"@))
        $problem = $true
    }

    if (-not $problem -and $enabled -ne 1) {
        Add-Finding -Id 'proxy' -Title 'Прокси не используется' -Status 'OK'
    }
}

function Check-HostsFile {
    Say-Head 'Файл hosts'
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (-not (Test-Path $hostsPath)) { return }

    $lines = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue)
    $blocking = @()
    foreach ($l in $lines) {
        if ($l -match '^\s*#' -or $l -match '^\s*$') { continue }
        if ($l -match '^\s*(0\.0\.0\.0|127\.0\.0\.1|::1)\s+(\S+)') {
            $name = $matches[2]
            if ($name -notmatch '^(localhost|127\.0\.0\.1|::1)$') { $blocking += $l.Trim() }
        }
    }

    if ($blocking.Count -eq 0) {
        Add-Finding -Id 'hosts' -Title 'Файл hosts чистый' -Status 'OK'
        return
    }

    $sample = ($blocking | Select-Object -First 8) -join "`n"
    if ($blocking.Count -gt 50) {
        Add-Finding -Id 'hosts.many' -Title "В hosts заблокировано доменов: $($blocking.Count)" -Status 'WARN' `
            -Detail "$sample`n..." `
            -Advice 'Похоже на установленный список блокировки рекламы. Автоматически не трогаю - если он мешает (не логинятся лаунчеры, не грузится Twitch/OBS), запустите с ключом -Hard.' `
            -FixLabel "Закомментировать все блокирующие строки ($($blocking.Count) шт.)" -HardOnly `
            -FixAction { Clear-HostsBlocking }
    } else {
        Add-Finding -Id 'hosts.block' -Title "В hosts заблокировано доменов: $($blocking.Count)" -Status 'BAD' `
            -Detail "$sample`nТакие строки часто оставляют кряки и 'оптимизаторы': сайт или лаунчер молча не работает." `
            -FixLabel 'Закомментировать блокирующие строки (с бэкапом файла)' `
            -FixAction { Clear-HostsBlocking }
    }
}

function Clear-HostsBlocking {
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $backupCopy = Join-Path $script:AppDir ("hosts-backup-" + $script:Stamp + ".txt")
    Copy-Item -LiteralPath $hostsPath -Destination $backupCopy -Force -ErrorAction Stop
    Add-BackupEntry @{ kind = 'file'; path = $hostsPath; copy = $backupCopy }

    $out = New-Object System.Collections.ArrayList
    foreach ($l in (Get-Content -LiteralPath $hostsPath)) {
        if ($l -notmatch '^\s*#' -and $l -match '^\s*(0\.0\.0\.0|127\.0\.0\.1|::1)\s+(\S+)' -and
            $matches[2] -notmatch '^(localhost|127\.0\.0\.1|::1)$') {
            $null = $out.Add('# [wifi-doctor] ' + $l)
        } else {
            $null = $out.Add($l)
        }
    }
    Set-Content -LiteralPath $hostsPath -Value $out -Encoding ASCII -Force -ErrorAction Stop
    Invoke-Native 'ipconfig.exe' @('/flushdns') | Out-Null
}

function Check-Metrics {
    Say-Head 'Виртуальные адаптеры и приоритет маршрутов'
    $ad = $script:Wifi
    if (-not $ad) { return }

    $wifiIf = Get-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if (-not $wifiIf) { return }
    $wifiMetric = [int]$wifiIf.InterfaceMetric

    $junkPattern = 'TAP|VPN|Hamachi|Radmin|VirtualBox|VMware|Hyper-V|Npcap|Loopback|ZeroTier|Tailscale|NordLynx|Proton|OpenVPN|WireGuard|Cisco AnyConnect|Check Point|Pangolin|Astrill|Psiphon'
    $all = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match $junkPattern -or $_.Name -match $junkPattern })

    $hijackers = @()
    foreach ($v in $all) {
        $vi = Get-NetIPInterface -InterfaceIndex $v.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if (-not $vi) { continue }
        if ($v.Status -eq 'Up' -and [int]$vi.InterfaceMetric -le $wifiMetric) {
            $hijackers += [pscustomobject]@{ Name = $v.Name; Desc = $v.InterfaceDescription; Index = $v.ifIndex; Metric = [int]$vi.InterfaceMetric }
        }
    }

    if ($hijackers.Count -gt 0) {
        $d = ($hijackers | ForEach-Object { "$($_.Name) [$($_.Desc)] метрика $($_.Metric) <= Wi-Fi $wifiMetric" }) -join "`n"
        $pairs = ($hijackers | ForEach-Object { "$($_.Index):$($_.Metric)" }) -join ','
        $target = $wifiMetric + 50
        Add-Finding -Id 'route.hijack' -Title "Виртуальные адаптеры перехватывают трафик: $($hijackers.Count)" -Status 'BAD' `
            -Detail "$d`nWindows отправляет трафик в VPN/виртуальный адаптер вместо Wi-Fi. Симптом: интернет 'вроде есть', но игры и стрим не соединяются." `
            -FixLabel 'Понизить приоритет виртуальных адаптеров' `
            -FixAction ([scriptblock]::Create(@"
                foreach (`$pair in ('$pairs' -split ',')) {
                    `$parts = `$pair -split ':'
                    `$idx = [int]`$parts[0]
                    Add-BackupEntry @{ kind = 'metric'; ifIndex = `$idx; metric = [int]`$parts[1] }
                    Set-NetIPInterface -InterfaceIndex `$idx -AddressFamily IPv4 -InterfaceMetric $target -ErrorAction SilentlyContinue
                }
"@))
    } else {
        Add-Finding -Id 'route.hijack' -Title "Маршруты в порядке, приоритет Wi-Fi (метрика $wifiMetric)" -Status 'OK'
    }

    $dead = @($all | Where-Object { $_.Status -ne 'Up' })
    if ($dead.Count -gt 0) {
        Add-Finding -Id 'route.dead' -Title "Неиспользуемых виртуальных адаптеров: $($dead.Count)" -Status 'INFO' `
            -Detail (($dead | ForEach-Object { "$($_.Name) [$($_.InterfaceDescription)] - $($_.Status)" }) -join "`n") `
            -Advice 'Если соответствующим VPN/эмулятором не пользуетесь - отключите адаптер в "Сетевых подключениях", он всё равно участвует в выборе маршрута.'
    }
}

function Check-TcpStack {
    Say-Head 'Параметры TCP/IP'
    try {
        $t = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop
        if ($t.AutoTuningLevelLocal -ne 'Normal') {
            $old = [string]$t.AutoTuningLevelLocal
            Add-Finding -Id 'tcp.autotune' -Title "Автонастройка окна TCP = $old (должно быть Normal)" -Status 'BAD' `
                -Detail 'Типичный "твик из интернета". Режет реальную скорость закачки в разы, особенно на быстром канале.' `
                -FixLabel 'Вернуть автонастройку TCP в Normal' `
                -FixAction ([scriptblock]::Create(@"
                    Add-BackupEntry @{ kind = 'tcpAutotune'; value = '$old' }
                    Set-NetTCPSetting -SettingName Internet -AutoTuningLevelLocal Normal -ErrorAction Stop
"@))
        } else {
            Add-Finding -Id 'tcp.autotune' -Title 'Автонастройка окна TCP: Normal' -Status 'OK'
        }
        if ($t.EcnCapability -eq 'Enabled') {
            Add-Finding -Id 'tcp.ecn' -Title 'Включён ECN' -Status 'INFO' `
                -Advice 'Некоторые домашние роутеры из-за ECN теряют пакеты. Если бывают странные обрывы: netsh int tcp set global ecncapability=disabled'
        }
    } catch {
        Add-Finding -Id 'tcp' -Title 'Не удалось прочитать параметры TCP' -Status 'INFO'
    }

    try {
        $off = Get-NetOffloadGlobalSetting -ErrorAction Stop
        if ($off.ReceiveSideScaling -eq 'Disabled') {
            Add-Finding -Id 'tcp.rss' -Title 'Отключён RSS (масштабирование на стороне приёма)' -Status 'WARN' `
                -Detail 'Вся обработка сети падает на одно ядро - на стриме это лишние фризы.' `
                -FixLabel 'Включить RSS' `
                -FixAction {
                    Add-BackupEntry @{ kind = 'rss'; value = 'Disabled' }
                    Set-NetOffloadGlobalSetting -ReceiveSideScaling Enabled -ErrorAction Stop
                }
        }
    } catch {}
}

function Check-ReceivePath {
    Say-Head 'Приём данных (когда загрузка медленнее отдачи)'

    Add-Finding -Id 'rx.hint' -Title 'Признак проблемы: скорость отдачи заметно выше скорости загрузки' -Status 'INFO' `
        -Detail 'Отдачу ограничивает окно приёма сервера, а загрузку - окно приёма вашего компьютера. Поэтому зажатое окно, эвристики TCP и антивирусная проверка входящего трафика роняют только загрузку, оставляя отдачу целой.'

    # Эвристики масштабирования окна: молча возвращают приём к 64 КБ.
    $heur = $null
    try {
        $t = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop
        if ($t.PSObject.Properties.Name -contains 'ScalingHeuristics') { $heur = [string]$t.ScalingHeuristics }
    } catch {}
    if (-not $heur -or $heur -eq 'Default') {
        foreach ($l in (Invoke-Native 'netsh.exe' @('interface', 'tcp', 'show', 'heuristics'))) {
            if ($l -match '(?i)(heuristics|эвристик)[^:]*:\s*(\S+)') { $heur = $matches[2] }
        }
    }

    if ($heur -and $heur -match '(?i)enabled|включ') {
        Add-Finding -Id 'rx.heuristics' -Title 'Включены эвристики масштабирования окна TCP' -Status 'BAD' `
            -Detail "Windows сама решает, что канал 'подозрительный', и зажимает окно приёма до 64 КБ.`nПри пинге под нагрузкой это режет загрузку до нескольких десятков Мбит/с, отдачу не трогая вовсе." `
            -FixLabel 'Отключить эвристики масштабирования окна' `
            -FixAction ([scriptblock]::Create(@"
                Add-BackupEntry @{ kind = 'tcpHeuristics'; value = '$heur' }
                Invoke-Native 'netsh.exe' @('interface', 'tcp', 'set', 'heuristics', 'disabled') | Out-Null
"@))
    } elseif ($heur) {
        Add-Finding -Id 'rx.heuristics' -Title 'Эвристики масштабирования окна отключены' -Status 'OK'
    }

    # Автонастройку может переопределять групповая политика.
    try {
        $t2 = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop
        if ([string]$t2.AutoTuningLevelEffective -eq 'GroupPolicy' -and
            [string]$t2.AutoTuningLevelGroupPolicy -notmatch 'Normal|NotConfigured') {
            Add-Finding -Id 'rx.gpo' -Title "Автонастройку окна TCP переопределяет групповая политика: $($t2.AutoTuningLevelGroupPolicy)" -Status 'BAD' `
                -Detail 'Значение из политики сильнее локального, поэтому обычная правка автонастройки не подействует.' `
                -Advice 'Убрать политику: HKLM\SOFTWARE\Policies\Microsoft\Windows\Tcpip\Parameters, параметр EnableWsd/TcpAutotuning. Автоматически не трогаю - политику мог поставить администратор.'
        }
    } catch {}

    # Проверка входящего трафика сторонним антивирусом.
    try {
        $av = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop |
                Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' })
        if ($av.Count -gt 0) {
            Add-Finding -Id 'rx.av' -Title "Сторонний антивирус: $(($av | ForEach-Object { $_.displayName }) -join ', ')" -Status 'WARN' `
                -Detail 'Проверка HTTPS/веб-трафика прогоняет через себя всё входящее и часто срезает загрузку в 2-3 раза, не трогая отдачу.' `
                -Advice 'Временно выключите в антивирусе проверку веб-трафика (HTTPS scanning / Web Shield) и перезамерьте скорость. Если разница есть - держите её выключенной или добавьте исключения.'
        }
    } catch {}

    # Приёмные буферы адаптера.
    $ad = $script:Wifi
    if ($ad) {
        $rxb = @(Get-NetAdapterAdvancedProperty -Name $ad.Name -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -match 'Receive Buffers|Приемные буферы|Приёмные буферы' })
        foreach ($p in $rxb) {
            Add-Finding -Id 'rx.buffers' -Title "$($p.DisplayName) = $($p.DisplayValue)" -Status 'INFO' `
                -Advice 'Если загрузка проседает рывками - поднимите это значение до максимума в свойствах адаптера.'
        }
    }
}

function Check-Mtu {
    Say-Head 'MTU'
    $ad = $script:Wifi
    if (-not $ad) { return }
    $ifi = Get-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if (-not $ifi) { return }
    $mtu = [int]$ifi.NlMtu
    if ($mtu -lt 1400 -or $mtu -gt 1500) {
        $idx = $ad.ifIndex
        Add-Finding -Id 'mtu' -Title "Нестандартный MTU: $mtu" -Status 'BAD' `
            -Detail 'Из-за этого часть пакетов режется: сайты открываются наполовину, загрузки обрываются, голос в дискорде заикается.' `
            -FixLabel 'Вернуть MTU 1500' `
            -FixAction ([scriptblock]::Create(@"
                Add-BackupEntry @{ kind = 'mtu'; ifIndex = $idx; value = $mtu }
                Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -NlMtuBytes 1500 -ErrorAction Stop
"@))
    } elseif ($mtu -ne 1500) {
        Add-Finding -Id 'mtu' -Title "MTU = $mtu" -Status 'INFO' -Detail 'Нормально для PPPoE-подключений.'
    } else {
        Add-Finding -Id 'mtu' -Title 'MTU = 1500 (норма)' -Status 'OK'
    }
}

function Check-Qos {
    Say-Head 'Ограничения полосы (QoS)'
    $psched = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched'
    $limit = Get-RegValue $psched 'NonBestEffortLimit'
    if ($null -ne $limit -and [int]$limit -ne 0) {
        Add-Finding -Id 'qos.psched' -Title "Политика резервирует $limit% полосы" -Status 'BAD' `
            -FixLabel 'Снять резервирование полосы' `
            -FixAction { Set-RegValueBacked -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' -Name 'NonBestEffortLimit' -Value 0 -Type DWord }
    } else {
        Add-Finding -Id 'qos.psched' -Title 'Резервирование полосы не задано' -Status 'OK'
    }

    try {
        $pol = @(Get-NetQosPolicy -ErrorAction Stop | Where-Object { $_.ThrottleRateActionBitsPerSecond -gt 0 })
        if ($pol.Count -gt 0) {
            Add-Finding -Id 'qos.policy' -Title "Политики QoS с ограничением скорости: $($pol.Count)" -Status 'WARN' `
                -Detail (($pol | ForEach-Object { "$($_.Name): $([math]::Round($_.ThrottleRateActionBitsPerSecond/1MB,2)) Мбит/с" }) -join "`n") `
                -Advice 'Удалить: Remove-NetQosPolicy -Name "ИМЯ". Автоматически не трогаю - политика может быть нужна.'
        }
    } catch {}
}

function Check-DeliveryOptimization {
    Say-Head 'Раздача обновлений Windows в фон (ест аплоад)'
    $paths = @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config'
    )
    $mode = $null
    foreach ($p in $paths) {
        $v = Get-RegValue $p 'DODownloadMode'
        if ($null -ne $v) { $mode = [int]$v; break }
    }
    if ($null -eq $mode) { $mode = 1 }

    if ($mode -ne 0 -and $mode -ne 99) {
        Add-Finding -Id 'do.mode' -Title "Delivery Optimization включён (режим $mode)" -Status 'WARN' `
            -Detail 'Windows раздаёт обновления другим компьютерам, забивая исходящий канал. Для стрима в OBS это прямой обрыв битрейта на ровном месте.' `
            -FixLabel 'Запретить раздачу обновлений' `
            -FixAction { Set-RegValueBacked -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -Name 'DODownloadMode' -Value 0 -Type DWord }
    } else {
        Add-Finding -Id 'do.mode' -Title 'Раздача обновлений выключена' -Status 'OK'
    }
}

function Check-Metered {
    Say-Head 'Лимитное подключение'
    $cost = $null
    try {
        $prof = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]::GetInternetConnectionProfile()
        if ($prof) { $cost = [string]$prof.GetConnectionCost().NetworkCostType }
    } catch {}

    if ($cost -and $cost -ne 'Unrestricted') {
        $ssid = $script:WlanInfo.Ssid
        $fix = $null
        if ($ssid) {
            $fix = [scriptblock]::Create(@"
                Add-BackupEntry @{ kind = 'wlanProfileCost'; name = '$ssid'; value = '$cost' }
                Invoke-Native 'netsh.exe' @('wlan','set','profileparameter',"name=$ssid",'cost=unrestricted') | Out-Null
"@)
        }
        Add-Finding -Id 'metered' -Title "Сеть помечена как лимитная ($cost)" -Status 'WARN' `
            -Detail 'Windows и часть приложений режут себе трафик, откладывают загрузки и синхронизацию.' `
            -FixLabel 'Снять отметку лимитного подключения' -FixAction $fix
    } elseif ($cost) {
        Add-Finding -Id 'metered' -Title 'Подключение не лимитное' -Status 'OK'
    }
}

function Check-NetworkProfile {
    Say-Head 'Тип сети и брандмауэр'
    $ad = $script:Wifi
    if ($ad) {
        $p = Get-NetConnectionProfile -InterfaceIndex $ad.ifIndex -ErrorAction SilentlyContinue
        if ($p) {
            if ($p.NetworkCategory -eq 'Public') {
                Add-Finding -Id 'netprofile' -Title "Сеть '$($p.Name)' определена как Общедоступная" -Status 'WARN' `
                    -Detail 'В этом режиме блокируется обнаружение устройств: не работают NDI для OBS, стрим на телевизор, локальная связь с телефоном/второй машиной.' `
                    -Advice "Если это ваша домашняя сеть: Set-NetConnectionProfile -InterfaceIndex $($ad.ifIndex) -NetworkCategory Private"
            } else {
                Add-Finding -Id 'netprofile' -Title "Тип сети: $($p.NetworkCategory)" -Status 'OK'
            }
            if ($p.IPv4Connectivity -notin @('Internet', 'LocalNetwork')) {
                Add-Finding -Id 'netprofile.conn' -Title "Windows считает, что интернета нет (IPv4: $($p.IPv4Connectivity))" -Status 'WARN' `
                    -Detail 'Из-за этого Store, Xbox-сервисы и часть лаунчеров отказываются работать, даже когда сайты открываются.'
            }
        }
    }

    try {
        $blocked = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { $_.DefaultOutboundAction -eq 'Block' })
        if ($blocked.Count -gt 0) {
            $names = ($blocked | ForEach-Object { $_.Name }) -join ','
            Add-Finding -Id 'fw.outbound' -Title "Брандмауэр блокирует исходящие по умолчанию: $names" -Status 'BAD' `
                -Detail 'Всё, что не внесено в правила вручную, просто не выходит в интернет.' `
                -FixLabel 'Разрешить исходящие соединения по умолчанию' `
                -FixAction ([scriptblock]::Create(@"
                    foreach (`$n in ('$names' -split ',')) {
                        Add-BackupEntry @{ kind = 'fwOutbound'; name = `$n; value = 'Block' }
                        Set-NetFirewallProfile -Name `$n -DefaultOutboundAction Allow -ErrorAction SilentlyContinue
                    }
"@))
        } else {
            Add-Finding -Id 'fw.outbound' -Title 'Брандмауэр не блокирует исходящие по умолчанию' -Status 'OK'
        }
    } catch {}
}

function Check-Bindings {
    Say-Head 'Сторонние компоненты на адаптере'
    $ad = $script:Wifi
    if (-not $ad) { return }
    $known = @('ms_msclient', 'ms_pacer', 'ms_server', 'ms_tcpip6', 'ms_tcpip', 'ms_lltdio', 'ms_rspndr',
               'ms_lldp', 'ms_implat', 'ms_ndisuio', 'ms_wfplwfs', 'ms_netbios', 'ms_netbt', 'ms_bridge')
    try {
        $extra = @(Get-NetAdapterBinding -Name $ad.Name -ErrorAction Stop |
                   Where-Object { $_.Enabled -and ($known -notcontains $_.ComponentID) })
        if ($extra.Count -gt 0) {
            Add-Finding -Id 'bindings' -Title "Сторонних сетевых фильтров на адаптере: $($extra.Count)" -Status 'WARN' `
                -Detail (($extra | ForEach-Object { "$($_.DisplayName)  [$($_.ComponentID)]" }) -join "`n") `
                -Advice 'Фильтры от VPN, антивирусов, VirtualBox, Killer и "ускорителей интернета" пропускают через себя весь трафик и добавляют задержку. Ненужные снимите галочкой в свойствах адаптера.'
        } else {
            Add-Finding -Id 'bindings' -Title 'Посторонних сетевых фильтров нет' -Status 'OK'
        }
    } catch {}

    $killer = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Killer|Rivet|SmartByte|cFos|NetLimiter|Speedify|Bandwidth' })
    if ($killer.Count -gt 0) {
        Add-Finding -Id 'bindings.shapers' -Title 'Найдены программы-приоритизаторы трафика' -Status 'WARN' `
            -Detail (($killer | ForEach-Object { "$($_.DisplayName) - $($_.Status)" }) -join "`n") `
            -Advice 'Killer Control Center, SmartByte, NetLimiter и подобные регулярно режут скорость сами. Проще удалить, оставив только драйвер адаптера.'
    }
}

# ============================================================== ИСПРАВЛЕНИЯ ===

function Get-FixableFindings {
    $script:Findings | Where-Object {
        $_.FixAction -ne $null -and (-not $_.HardOnly -or $Hard)
    }
}

function Invoke-Fixes {
    Say-Head 'Применение исправлений'
    $fixable = @(Get-FixableFindings)
    if ($fixable.Count -eq 0) {
        Say 'Нечего исправлять - все проверки пройдены.' 'Green'
        return
    }

    foreach ($f in $fixable) {
        Say ("  -> " + $f.FixLabel) 'White'
        try {
            & $f.FixAction | Out-Null
            $f.FixResult = 'OK'
            Say '     готово' 'Green'
        } catch {
            $f.FixResult = "ОШИБКА: $($_.Exception.Message)"
            Say ("     не получилось: " + $_.Exception.Message) 'Red'
        }
    }

    Invoke-Native 'ipconfig.exe' @('/flushdns') | Out-Null
    Say '  -> кэш DNS очищен' 'Green'
}

function Invoke-HardReset {
    Say-Head 'Жёсткий сброс сетевого стека (-Hard)'
    Say 'Сбрасываю Winsock, стек IP и таблицу ARP. Потребуется перезагрузка.' 'Yellow'
    Invoke-Native 'netsh.exe' @('winsock', 'reset') | Out-Null
    Invoke-Native 'netsh.exe' @('int', 'ip', 'reset') | Out-Null
    Invoke-Native 'netsh.exe' @('int', 'ipv6', 'reset') | Out-Null
    Invoke-Native 'arp.exe' @('-d', '*') | Out-Null
    Invoke-Native 'ipconfig.exe' @('/flushdns') | Out-Null
    Invoke-Native 'ipconfig.exe' @('/registerdns') | Out-Null
    $script:NeedReboot = $true
    Say 'Сброс выполнен.' 'Green'
}

function Save-Backup {
    if ($script:Backup.Count -eq 0) { return $null }
    if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
    $path = Join-Path $script:AppDir ("wifi-backup-" + $script:Stamp + ".json")
    $script:Backup | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Restore-Backup {
    param([string]$Path)

    if (-not $Path -or $Path -in @('last', 'latest', 'последний')) {
        $files = @(Get-ChildItem -Path $script:AppDir -Filter 'wifi-backup-*.json' -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending)
        if ($files.Count -eq 0) {
            Say 'Файлов бэкапа не найдено - откатывать нечего.' 'Yellow'
            return
        }
        $Path = $files[0].FullName
    }
    if (-not (Test-Path $Path)) {
        Say "Файл бэкапа не найден: $Path" 'Red'
        return
    }

    Say-Head "Откат изменений из $Path"
    $entries = @(Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    [array]::Reverse($entries)

    foreach ($e in $entries) {
        try {
            switch ($e.kind) {
                'registry' {
                    if ($e.existed) {
                        New-ItemProperty -Path $e.path -Name $e.name -Value $e.value -PropertyType $e.type -Force -ErrorAction Stop | Out-Null
                    } else {
                        Remove-ItemProperty -Path $e.path -Name $e.name -ErrorAction SilentlyContinue
                    }
                    Say "  реестр: $($e.path)\$($e.name)" 'Gray'
                }
                'powercfg' {
                    Invoke-Native 'powercfg.exe' @('/setacvalueindex', 'SCHEME_CURRENT', $e.sub, $e.setting, [string]$e.ac) | Out-Null
                    Invoke-Native 'powercfg.exe' @('/setdcvalueindex', 'SCHEME_CURRENT', $e.sub, $e.setting, [string]$e.dc) | Out-Null
                    Invoke-Native 'powercfg.exe' @('/setactive', 'SCHEME_CURRENT') | Out-Null
                    Say '  схема питания: энергосбережение Wi-Fi возвращено' 'Gray'
                }
                'service' {
                    if ($e.startMode -and $e.startMode -ne 'Auto') {
                        $map = @{ 'Manual' = 'Manual'; 'Disabled' = 'Disabled'; 'Auto' = 'Automatic' }
                        if ($map.ContainsKey([string]$e.startMode)) {
                            Set-Service -Name $e.name -StartupType $map[[string]$e.startMode] -ErrorAction SilentlyContinue
                        }
                    }
                    if ($e.status -ne 'Running') { Stop-Service -Name $e.name -Force -ErrorAction SilentlyContinue }
                    Say "  служба $($e.name)" 'Gray'
                }
                'adapterPm' {
                    $p = Get-NetAdapterPowerManagement -Name $e.name -ErrorAction Stop
                    $p.SelectiveSuspend = $e.selectiveSuspend
                    $p.DeviceSleepOnDisconnect = $e.deviceSleep
                    Set-NetAdapterPowerManagement -InputObject $p -ErrorAction SilentlyContinue
                    Say "  энергосбережение адаптера $($e.name)" 'Gray'
                }
                'advprop' {
                    Set-NetAdapterAdvancedProperty -Name $e.adapter -RegistryKeyword $e.keyword -RegistryValue $e.value -NoRestart -ErrorAction SilentlyContinue
                    Say "  настройка драйвера $($e.keyword)" 'Gray'
                }
                'wlanProfileMode' {
                    Invoke-Native 'netsh.exe' @('wlan', 'set', 'profileparameter', "name=$($e.name)", "connectionmode=$($e.mode)") | Out-Null
                    Say "  профиль '$($e.name)': режим подключения $($e.mode)" 'Gray'
                }
                'wlanProfileRandom' {
                    Invoke-Native 'netsh.exe' @('wlan', 'set', 'profileparameter', "name=$($e.name)", "randomization=$($e.value)") | Out-Null
                    Say "  профиль '$($e.name)': рандомизация MAC" 'Gray'
                }
                'wlanProfileCost' {
                    $c = if ([string]$e.value -match 'Variable') { 'variable' } else { 'fixed' }
                    Invoke-Native 'netsh.exe' @('wlan', 'set', 'profileparameter', "name=$($e.name)", "cost=$c") | Out-Null
                    Say "  профиль '$($e.name)': лимитное подключение ($c)" 'Gray'
                }
                'dns' {
                    if ($e.servers -and @($e.servers).Count -gt 0) {
                        Set-DnsClientServerAddress -InterfaceIndex $e.ifIndex -ServerAddresses @($e.servers) -ErrorAction SilentlyContinue
                    } else {
                        Set-DnsClientServerAddress -InterfaceIndex $e.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
                    }
                    Say '  DNS-серверы' 'Gray'
                }
                'metric' {
                    Set-NetIPInterface -InterfaceIndex $e.ifIndex -AddressFamily IPv4 -InterfaceMetric $e.metric -ErrorAction SilentlyContinue
                    Say "  метрика интерфейса $($e.ifIndex)" 'Gray'
                }
                'mtu' {
                    Set-NetIPInterface -InterfaceIndex $e.ifIndex -AddressFamily IPv4 -NlMtuBytes $e.value -ErrorAction SilentlyContinue
                    Say "  MTU интерфейса $($e.ifIndex)" 'Gray'
                }
                'tcpAutotune' {
                    Set-NetTCPSetting -SettingName Internet -AutoTuningLevelLocal $e.value -ErrorAction SilentlyContinue
                    Say '  автонастройка TCP' 'Gray'
                }
                'tcpHeuristics' {
                    $h = if ([string]$e.value -match '(?i)enabled|включ') { 'enabled' } else { 'disabled' }
                    Invoke-Native 'netsh.exe' @('interface', 'tcp', 'set', 'heuristics', $h) | Out-Null
                    Say "  эвристики масштабирования окна TCP: $h" 'Gray'
                }
                'rss' {
                    Set-NetOffloadGlobalSetting -ReceiveSideScaling Disabled -ErrorAction SilentlyContinue
                    Say '  RSS' 'Gray'
                }
                'fwOutbound' {
                    Set-NetFirewallProfile -Name $e.name -DefaultOutboundAction Block -ErrorAction SilentlyContinue
                    Say "  брандмауэр: профиль $($e.name)" 'Gray'
                }
                'winhttpProxy' {
                    if ($e.value -and [string]$e.value -match ':\d+') {
                        Invoke-Native 'netsh.exe' @('winhttp', 'set', 'proxy', [string]$e.value) | Out-Null
                        Say "  системный прокси возвращён: $($e.value)" 'Gray'
                    } else {
                        Say '  системный прокси: прежнее значение не сохранено' 'Yellow'
                    }
                }
                'file' {
                    if (Test-Path $e.copy) {
                        Copy-Item -LiteralPath $e.copy -Destination $e.path -Force -ErrorAction Stop
                        Say "  файл $($e.path)" 'Gray'
                    }
                }
                default { Say "  пропущено: $($e.kind)" 'DarkGray' }
            }
        } catch {
            Say "  не удалось откатить $($e.kind): $($_.Exception.Message)" 'Red'
        }
    }
    Say ''
    Say 'Откат завершён. Перезагрузите ноутбук, чтобы настройки адаптера применились.' 'Yellow'
}

function Show-Summary {
    Say-Head 'Итог'
    $bad  = @($script:Findings | Where-Object { $_.Status -eq 'BAD' })
    $warn = @($script:Findings | Where-Object { $_.Status -eq 'WARN' })
    $ok   = @($script:Findings | Where-Object { $_.Status -eq 'OK' })

    Say ("Серьёзных проблем: {0}   предупреждений: {1}   в порядке: {2}" -f $bad.Count, $warn.Count, $ok.Count) 'White'

    if ($bad.Count -gt 0) {
        Say ''
        Say 'Мешает работе:' 'Red'
        foreach ($f in $bad) { Say ("  - " + $f.Title) 'Red' }
    }
    if ($warn.Count -gt 0) {
        Say ''
        Say 'Стоит поправить:' 'Yellow'
        foreach ($f in $warn) { Say ("  - " + $f.Title) 'Yellow' }
    }

    $fixable = @(Get-FixableFindings)
    $hardOnly = @($script:Findings | Where-Object { $_.FixAction -ne $null -and $_.HardOnly -and -not $Hard })

    if (-not $Fix) {
        Say ''
        if ($fixable.Count -gt 0) {
            Say "Могу исправить автоматически ($($fixable.Count)):" 'Cyan'
            foreach ($f in $fixable) { Say ("  * " + $f.FixLabel) 'Cyan' }
            Say ''
            Say 'Запустите с ключом -Fix (от имени администратора), чтобы применить.' 'White'
            Say 'Все изменения записываются в бэкап, откат: -Restore last' 'DarkGray'
        } else {
            Say 'Автоматически исправлять нечего.' 'Green'
        }
    } else {
        $done   = @($script:Findings | Where-Object { $_.FixResult -eq 'OK' })
        $failed = @($script:Findings | Where-Object { $_.FixResult -and $_.FixResult -ne 'OK' })
        Say ''
        Say "Применено исправлений: $($done.Count)" 'Green'
        if ($failed.Count -gt 0) {
            Say "Не удалось: $($failed.Count)" 'Red'
            foreach ($f in $failed) { Say ("  - $($f.FixLabel): $($f.FixResult)") 'Red' }
        }
    }

    if ($hardOnly.Count -gt 0) {
        Say ''
        Say "Ещё $($hardOnly.Count) пункт(ов) требуют ключа -Hard (сброс стека, чистка hosts)." 'DarkYellow'
    }
}

# ==================================================================== MAIN ===

function Main {
    Say ''
    Say '  Wi-Fi Doctor - pc-optimizer-lite' 'White'
    Say '  проверка настроек Wi-Fi и устранение помех' 'DarkGray'
    Say ("  " + (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')) 'DarkGray'

    $admin = Test-Admin
    if (-not (Test-Path $script:AppDir)) {
        New-Item -ItemType Directory -Path $script:AppDir -Force -ErrorAction SilentlyContinue | Out-Null
    }

    if ($Restore) {
        if (-not $admin) {
            Say ''
            Say 'Для отката нужны права администратора. Запустите от имени администратора.' 'Red'
            return
        }
        Restore-Backup -Path $Restore
        return
    }

    if (-not $admin) {
        Say ''
        Say '  ВНИМАНИЕ: запущено без прав администратора.' 'Yellow'
        Say '  Часть проверок будет пропущена, исправления недоступны.' 'Yellow'
        if ($Fix) {
            Say '  Ключ -Fix без прав администратора работать не будет. Перезапустите от имени администратора.' 'Red'
            return
        }
    }

    $script:Wifi = Get-WifiAdapter

    Check-Adapter
    Check-WlanState
    Check-PowerManagement
    Check-PowerPlan
    Check-AdvancedProps
    Check-Services
    Check-Profiles
    Check-MacRandomization
    Check-Hotspots
    Check-IpConfig
    Check-Dns
    Check-Proxy
    Check-HostsFile
    Check-Metrics
    Check-TcpStack
    Check-ReceivePath
    Check-Mtu
    Check-Qos
    Check-DeliveryOptimization
    Check-Metered
    Check-NetworkProfile
    Check-Bindings

    if ($Fix) {
        Invoke-Fixes
        if ($Hard) { Invoke-HardReset }

        $bak = Save-Backup
        if ($bak) {
            Say ''
            Say "Бэкап прежних настроек: $bak" 'DarkGray'
            Say 'Откатить всё: .\Wifi-Doctor.ps1 -Restore last' 'DarkGray'
        }

        if ($script:NeedAdapterRestart -and -not $NoRestartAdapter) {
            Say ''
            Say 'Перезапускаю Wi-Fi адаптер, чтобы настройки применились (связь пропадёт на несколько секунд)...' 'Yellow'
            try {
                Restart-NetAdapter -Name $script:Wifi.Name -Confirm:$false -ErrorAction Stop
                Start-Sleep -Seconds 6
                Say 'Адаптер перезапущен.' 'Green'
            } catch {
                Say "Не удалось перезапустить адаптер: $($_.Exception.Message)" 'Red'
                $script:NeedReboot = $true
            }
        }
    }

    Show-Summary

    if ($script:NeedReboot) {
        Say ''
        Say 'Нужна перезагрузка, чтобы изменения вступили в силу.' 'Yellow'
    }

    try {
        $logPath = Join-Path $script:AppDir ("wifi-report-" + $script:Stamp + ".txt")
        $script:LogLines | Set-Content -LiteralPath $logPath -Encoding UTF8
        Say ''
        Say "Отчёт сохранён: $logPath" 'DarkGray'
    } catch {}
    Say ''
}

function Show-Menu {
    Say ''
    Say '  Wi-Fi Doctor - pc-optimizer-lite' 'White'
    Say ''
    Say '   1 - Проверить настройки Wi-Fi (ничего не менять)' 'Gray'
    Say '   2 - Проверить и убрать всё, что мешает' 'Gray'
    Say '   3 - То же + жёсткий сброс сетевого стека (нужна перезагрузка)' 'Gray'
    Say '   4 - Откатить последние изменения' 'Gray'
    Say '   0 - Выход' 'Gray'
    Say ''
    $c = Read-Host '  Ваш выбор'
    switch ($c.Trim()) {
        '1' { return $true }
        '2' { $script:Fix = $true; return $true }
        '3' { $script:Fix = $true; $script:Hard = $true; return $true }
        '4' { $script:Restore = 'last'; return $true }
        '0' { return $false }
        default {
            Say '  Не понял выбор - делаю обычную проверку.' 'Yellow'
            return $true
        }
    }
}

if ($Menu) {
    if (-not (Show-Menu)) { return }
}

Main
