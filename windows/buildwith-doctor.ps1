<#
.SYNOPSIS
    BuildWith Doctor (Windows) - le stethoscope numerique de votre PC.
    Auscultation - Diagnostic - Ordonnance - Traitement - Contre-visite.

    by BuildWith

.DESCRIPTION
    Inspecte Windows 10/11 en profondeur (stockage, memoire, services, mises a jour,
    securite, reseau, journaux d'evenements, materiel, integrite...), calcule un
    indice de sante /100, puis repare ce qui peut l'etre automatiquement.

.PARAMETER Mode      Scan (diagnostic seul) | Heal (soins avec confirmation) | Auto (soins sans question)
.PARAMETER DryRun    Simule les soins sans rien modifier
.PARAMETER Yes       Repond oui aux soins critiques/importants
.PARAMETER Full      Avec -Yes : inclut aussi les soins optionnels
.PARAMETER Deep      Auscultation approfondie (DISM ScanHealth, SFC, mises a jour en attente)
.PARAMETER Quick     Auscultation rapide
.PARAMETER Only      Modules a ausculter, ex: -Only disk,security
.PARAMETER Skip      Modules a ignorer
.PARAMETER List      Liste les modules
.PARAMETER Demo      Affiche seulement l'ecran d'accueil
.PARAMETER NoReboot  Ne propose jamais de redemarrage
.PARAMETER NoAnim    Pas d'animation

.EXAMPLE
    .\buildwith-doctor.ps1                       # menu interactif
    .\buildwith-doctor.ps1 -Mode Scan -Deep      # diagnostic approfondi
    .\buildwith-doctor.ps1 -Mode Heal -DryRun    # simulation des soins
    .\buildwith-doctor.ps1 -Mode Auto            # soins sans question

    Codes de sortie : 0 = en bonne sante, 1 = avertissements, 2 = critique
    Journaux : C:\ProgramData\BuildWithDoctor\
#>
[CmdletBinding()]
param(
    [ValidateSet('Scan', 'Heal', 'Auto')][string]$Mode,
    [switch]$DryRun, [switch]$Yes, [switch]$Full, [switch]$Deep, [switch]$Quick,
    [string]$Only = '', [string]$Skip = '',
    [switch]$List, [switch]$Demo, [switch]$NoReboot, [switch]$NoAnim, [switch]$Elevated
)

$script:Version = '2.0.0'
$script:App = 'BuildWith Doctor'
$script:Dry = [bool]$DryRun
$script:AutoYes = [bool]$Yes
$script:FullMode = [bool]$Full
$script:DeepMode = [bool]$Deep
$script:QuickMode = [bool]$Quick
$script:Anim = -not [bool]$NoAnim
$script:Action = ''
if ($Mode -eq 'Scan') { $script:Action = 'scan' }
if ($Mode -eq 'Heal') { $script:Action = 'heal' }
if ($Mode -eq 'Auto') { $script:Action = 'heal'; $script:AutoYes = $true }

$script:Findings = New-Object System.Collections.ArrayList
$script:PassCount = 0
$script:Quiet = $false
$script:Score = 100
$script:NC = 0; $script:NW = 0; $script:NI = 0
$script:RebootReasons = New-Object System.Collections.ArrayList
$script:FixResults = New-Object System.Collections.ArrayList
$script:RootPct = 0
$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:LogDir = Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { [IO.Path]::GetTempPath() }) 'BuildWithDoctor'
$script:BackupDir = Join-Path $script:LogDir ("sauvegardes\" + $script:Stamp)
$script:ActionLog = ''
$script:ReportTxt = ''; $script:ReportJson = ''

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:Cols = 80
try { $script:Cols = [int]$Host.UI.RawUI.WindowSize.Width } catch { }
if ($script:Cols -lt 60) { $script:Cols = 60 }
if ($script:Cols -gt 100) { $script:Cols = 100 }

# =============================================================================
#  UTILITAIRES
# =============================================================================
function Test-Admin {
    try {
        $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
function Get-Gio([double]$bytes) { return ('{0:N2} Gio' -f ($bytes / 1GB)) }
function Cut-To([string]$s, [int]$n) { if ($n -lt 10) { $n = 10 }; if ($s.Length -gt $n) { return $s.Substring(0, $n - 1) + '…' }; return $s }
function Join-Short($items, [int]$max = 6) {
    $a = @($items); if ($a.Count -le $max) { return ($a -join ', ') }
    return (($a | Select-Object -First $max) -join ', ') + " (+$($a.Count - $max))"
}
function Write-Log([string]$msg) {
    if (-not $script:ActionLog) { return }
    try { Add-Content -Path $script:ActionLog -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch { }
}
function Test-Ping([string]$target, [int]$ms = 2000) {
    try { return ((New-Object Net.NetworkInformation.Ping).Send($target, $ms).Status -eq 'Success') } catch { return $false }
}
function Invoke-Timeout([scriptblock]$Block, [int]$Sec = 20) {
    $j = Start-Job -ScriptBlock $Block
    if (Wait-Job $j -Timeout $Sec) { $r = Receive-Job $j; Remove-Job $j -Force; return $r }
    Stop-Job $j; Remove-Job $j -Force; return $null
}
function Get-EventsSafe([hashtable]$Filter, [int]$Max = 500) {
    try { return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction SilentlyContinue) } catch { return @() }
}
function Get-FolderBytes([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    $m = Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    if ($m.Sum) { return [double]$m.Sum } else { return 0 }
}

# --- affichage ---
function Pass([string]$t) { $script:PassCount++; if ($script:Quiet) { return }; Write-Host '  ' -NoNewline; Write-Host '✔' -ForegroundColor Green -NoNewline; Write-Host " $t" }
function Note([string]$t) { if ($script:Quiet) { return }; Write-Host '  • ' -ForegroundColor DarkGray -NoNewline; Write-Host $t -ForegroundColor DarkGray }
function Say-Info([string]$t) { Write-Host '[i] ' -ForegroundColor Blue -NoNewline; Write-Host $t }
function Say-Ok([string]$t) { Write-Host '[✔] ' -ForegroundColor Green -NoNewline; Write-Host $t }
function Say-Warn([string]$t) { Write-Host '[!] ' -ForegroundColor Yellow -NoNewline; Write-Host $t }
function Say-Err([string]$t) { Write-Host '[✘] ' -ForegroundColor Red -NoNewline; Write-Host $t }
function Say-Act([string]$t) { Write-Host '    ↳ ' -ForegroundColor Cyan -NoNewline; Write-Host $t }
function Say-Title([string]$t) { Write-Host ''; Write-Host "━━ $t ━━" -ForegroundColor Cyan }

function Add-Finding {
    param([string]$Sev, [string]$Mod, [string]$Title, [string]$Detail = '', [string]$Fix = '', [string]$FixDesc = '')
    [void]$script:Findings.Add([pscustomobject]@{ Sev = $Sev; Mod = $Mod; Title = $Title; Detail = $Detail; Fix = $Fix; FixDesc = $FixDesc })
    if ($script:Quiet) { return }
    $ic = 'ℹ'; $col = 'Blue'
    if ($Sev -eq 'crit') { $ic = '✘'; $col = 'Red' } elseif ($Sev -eq 'warn') { $ic = '▲'; $col = 'Yellow' }
    Write-Host "  $ic " -ForegroundColor $col -NoNewline
    Write-Host $Title -ForegroundColor White -NoNewline
    if ($Detail) { Write-Host (' — ' + (Cut-To $Detail ($script:Cols - $Title.Length - 10))) -ForegroundColor DarkGray } else { Write-Host '' }
}

# --- execution / simulation ---
function Do-It {
    param([string]$Desc, [scriptblock]$Block)
    if ($script:Dry) { Write-Host '    [simulation] ' -ForegroundColor Yellow -NoNewline; Write-Host $Desc; Write-Log "SIMULATION: $Desc"; return $true }
    Write-Log "EXEC: $Desc"
    try {
        & { $ErrorActionPreference = 'Stop'; & $Block } | Out-Null
        return $true
    } catch {
        Say-Warn ("$Desc : " + $_.Exception.Message); Write-Log ("ECHEC: $Desc : " + $_.Exception.Message); return $false
    }
}
function Backup-Reg([string]$key) {
    if ($script:Dry) { return }
    try {
        New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null
        $f = Join-Path $script:BackupDir (($key -replace '[\\/:*?"<>|]', '_') + '.reg')
        & reg.exe export $key $f /y 2>&1 | Out-Null
        Write-Log "SAUVEGARDE REG: $key -> $f"
    } catch { }
}
function Confirm-Action([string]$q) {
    if ($script:AutoYes) { return $true }
    try { $r = Read-Host "$q [o/N]" } catch { return $false }
    return ($r -match '^(o|oui|y|yes)$')
}

# =============================================================================
#  ECRAN D'ACCUEIL : stethoscope + electrocardiogramme + signature
# =============================================================================
$script:Art = @(
    '  ▄███▄                           ▄███▄',
    '  █████                           █████',
    '   ▀█▀                             ▀█▀',
    '    ║                               ║',
    '    ║                               ║',
    '    ╚═══╗                       ╔═══╝',
    '        ╚═══╗               ╔═══╝',
    '            ╚═══╗       ╔═══╝',
    '                ╚═══╦═══╝',
    '                    ║',
    '                    ║',
    '           ▄▄▄▄▄▄▄▄▄█▄▄▄▄▄▄▄▄▄',
    '          ▄█▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀█▄',
    '         █▀ ╭───────────────╮ ▀█',
    '         █▀ │  ♥ ─╱╲─╱╲╱╲─  │ ▀█',
    '         █▀ ╰───────────────╯ ▀█',
    '          ▀█▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄█▀',
    '            ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀'
)
function Get-Pad([int]$w) { $p = [int](($script:Cols - $w) / 2); if ($p -lt 0) { $p = 0 }; return (' ' * $p) }

function Show-Splash {
    if ($script:Anim) { try { Clear-Host } catch { } }
    $pad = Get-Pad 41
    Write-Host ''
    for ($i = 0; $i -lt $script:Art.Count; $i++) {
        $line = $script:Art[$i]
        $col = 'Cyan'
        if ($i -le 2) { $col = 'White' } elseif ($i -le 10) { $col = 'DarkGray' }
        Write-Host $pad -NoNewline
        $parts = $line -split '♥'
        for ($k = 0; $k -lt $parts.Count; $k++) {
            Write-Host $parts[$k] -ForegroundColor $col -NoNewline
            if ($k -lt $parts.Count - 1) { Write-Host '♥' -ForegroundColor Red -NoNewline }
        }
        Write-Host ''
        if ($script:Anim) { Start-Sleep -Milliseconds 30 }
    }
    Show-Ecg
    Write-Host ''
    Show-Banner
}
function Show-Ecg {
    $wave = @('▁', '▁', '▁', '▁', '▁', '▁', '▂', '▅', '█', '▇', '▃', '▁', '▄', '▁', '▁', '▁', '▁', '▁', '▁', '▁')
    $n = $wave.Count; $width = $script:Cols - 8
    $frames = 1; if ($script:Anim) { $frames = 44 }
    for ($f = 0; $f -lt $frames; $f++) {
        $sb = New-Object System.Text.StringBuilder
        for ($x = 0; $x -lt $width; $x++) { [void]$sb.Append($wave[($x + $f) % $n]) }
        Write-Host ("`r    " + $sb.ToString()) -ForegroundColor Green -NoNewline
        if ($script:Anim) { Start-Sleep -Milliseconds 35 }
    }
    Write-Host ''
}
function Write-BoxRow([string]$text, [string]$color, [int]$bw, [string]$pad) {
    $left = [int](($bw - $text.Length) / 2); $right = $bw - $text.Length - $left
    Write-Host $pad -NoNewline
    Write-Host '║' -ForegroundColor Cyan -NoNewline
    Write-Host ((' ' * $left) + $text + (' ' * $right)) -ForegroundColor $color -NoNewline
    Write-Host '║' -ForegroundColor Cyan
}
function Show-Banner {
    $bw = 48; $pad = Get-Pad ($bw + 2); $hl = '═' * $bw
    Write-Host ($pad + '╔' + $hl + '╗') -ForegroundColor Cyan
    Write-BoxRow 'B U I L D W I T H   ·   D O C T O R' 'White' $bw $pad
    Write-BoxRow 'Le stéthoscope numérique de votre PC Windows' 'Cyan' $bw $pad
    Write-BoxRow ("v$($script:Version)  ·  ausculte · diagnostique · soigne") 'DarkGray' $bw $pad
    Write-Host ($pad + '╠' + $hl + '╣') -ForegroundColor Cyan
    Write-BoxRow '— by BuildWith —' 'Green' $bw $pad
    Write-Host ($pad + '╚' + $hl + '╝') -ForegroundColor Cyan
}
function Show-Signature { Write-Host ''; Write-Host ((Get-Pad 16) + '— by BuildWith —') -ForegroundColor Green }

function Show-ModuleHeader([int]$i, [int]$n, [string]$label) {
    $w = 16; $f = [int]($i * $w / $n)
    $bar = ('█' * $f) + ('░' * ($w - $f))
    Write-Host ''
    Write-Host '♥ ' -ForegroundColor Red -NoNewline
    Write-Host "Auscultation : $label " -ForegroundColor White -NoNewline
    Write-Host $bar -ForegroundColor Cyan -NoNewline
    Write-Host " ($i/$n)" -ForegroundColor DarkGray
}

# =============================================================================
#  MODULES D'AUSCULTATION
# =============================================================================
function Get-PendingReboot {
    $r = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $r += 'Mise à jour des composants Windows (CBS)' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $r += 'Windows Update' }
    $pf = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pf) { $r += 'Renommages de fichiers en attente (installation/désinstallation)' }
    return $r
}

# ---------- 1. Identite ----------
function Mod-System {
    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {
        Add-Finding 'crit' 'system' 'WMI inaccessible' 'Le référentiel WMI est endommagé : beaucoup d''outils Windows échoueront' 'Fix-Wmi' 'Réparer le référentiel WMI (winmgmt /salvagerepository)'
        return
    }
    $cs = Get-CimInstance Win32_ComputerSystem
    Note "Système : $($os.Caption) — build $($os.BuildNumber) ($($os.OSArchitecture))"
    Note "Machine : $($cs.Manufacturer) $($cs.Model) — hôte $env:COMPUTERNAME"
    $days = [int]((Get-Date) - $os.LastBootUpTime).TotalDays
    if ($days -gt 30) { Add-Finding 'info' 'system' "Aucun vrai redémarrage depuis $days jours" 'Le démarrage rapide masque les redémarrages : utilisez « Redémarrer » (pas « Arrêter »)' }
    else { Pass "Dernier démarrage il y a $days j" }
    $pr = @(Get-PendingReboot)
    if ($pr.Count -gt 0) {
        Add-Finding 'warn' 'system' 'Redémarrage en attente' ($pr -join ' ; ')
        [void]$script:RebootReasons.Add('Redémarrage en attente : ' + ($pr -join ', '))
    } else { Pass 'Aucun redémarrage en attente' }
    try { if (Confirm-SecureBootUEFI) { Pass 'Secure Boot actif' } else { Add-Finding 'info' 'system' 'Secure Boot désactivé' 'Windows 11 le recommande (BIOS/UEFI)' } } catch { Note 'Secure Boot : non applicable (BIOS Legacy ou droits insuffisants)' }
    try {
        $t = Get-Tpm
        if ($t.TpmPresent -and -not $t.TpmReady) { Add-Finding 'warn' 'system' 'Le TPM est présent mais non prêt' 'Initialisez-le dans tpm.msc' }
        elseif (-not $t.TpmPresent) { Note 'TPM : absent' } else { Pass 'TPM prêt' }
    } catch { }
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" | Select-Object -First 1
    if ($lic -and $lic.LicenseStatus -ne 1) { Add-Finding 'info' 'system' 'Windows n''est pas activé' 'Certaines fonctions de personnalisation sont limitées' }
}

# ---------- 2. Processeur ----------
function Mod-Cpu {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Note "Processeur : $($cpu.Name.Trim()) — $($cpu.NumberOfCores) cœurs / $($cpu.NumberOfLogicalProcessors) threads"
    $samples = @()
    for ($i = 0; $i -lt 3; $i++) {
        $p = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
        if ($p) { $samples += [int]$p.PercentProcessorTime }
        Start-Sleep -Milliseconds 700
    }
    if ($samples.Count -gt 0) {
        $avg = [int](($samples | Measure-Object -Average).Average)
        Note "Utilisation CPU instantanée : $avg %"
        if ($avg -ge 95) { Add-Finding 'warn' 'cpu' "Processeur saturé ($avg %)" 'Un processus consomme tout le CPU (voir ci-dessous)' }
        elseif ($avg -ge 85) { Add-Finding 'info' 'cpu' "Processeur très sollicité ($avg %)" '' }
        else { Pass "Charge CPU normale ($avg %)" }
    }
    $top = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object { $_.Name -notin '_Total', 'Idle' } | Sort-Object PercentProcessorTime -Descending | Select-Object -First 3
    if ($top) { Note ('Top CPU : ' + (($top | ForEach-Object { "$($_.Name)($($_.PercentProcessorTime)%)" }) -join ' ')) }
    $d = @()
    for ($i = 0; $i -lt 3; $i++) {
        $x = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
        if ($x) { $d += [int]$x.PercentDiskTime }
        Start-Sleep -Milliseconds 500
    }
    if ($d.Count -gt 0 -and (($d | Measure-Object -Minimum).Minimum -ge 90)) {
        Add-Finding 'warn' 'cpu' 'Disque à 100 % d''activité' 'Cause fréquente de lenteurs : indexation, antivirus, mises à jour, disque défaillant ou HDD saturé'
    }
}

# ---------- 3. Memoire ----------
function Mod-Memory {
    $os = Get-CimInstance Win32_OperatingSystem
    $total = [double]$os.TotalVisibleMemorySize * 1KB; $free = [double]$os.FreePhysicalMemory * 1KB
    if ($total -le 0) { Note 'Mémoire illisible'; return }
    $ap = [int]($free * 100 / $total)
    Note "RAM $(Get-Gio $total) — disponible $(Get-Gio $free) ($ap %)"
    if ($ap -lt 8) { Add-Finding 'crit' 'memory' 'RAM presque saturée' "Seulement $ap % disponible : fermez des applications, vérifiez les processus gourmands" }
    elseif ($ap -lt 15) { Add-Finding 'warn' 'memory' 'RAM faible' "$ap % disponible" }
    else { Pass "Mémoire disponible : $ap %" }

    $commit = 0
    if ($os.TotalVirtualMemorySize -gt 0) { $commit = [int](100 - ([double]$os.FreeVirtualMemory * 100 / [double]$os.TotalVirtualMemorySize)) }
    if ($commit -gt 90) { Add-Finding 'warn' 'memory' "Mémoire virtuelle (commit) à $commit %" 'Risque d''erreurs « mémoire insuffisante » : agrandissez le fichier d''échange' 'Fix-Pagefile' 'Remettre le fichier d''échange en gestion automatique par Windows' }
    $pf = @(Get-CimInstance Win32_PageFileUsage)
    $auto = (Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile
    if ($pf.Count -eq 0) {
        Add-Finding 'warn' 'memory' 'Aucun fichier d''échange (pagefile)' 'Les plantages d''applications gourmandes et l''absence de vidage mémoire deviennent probables' 'Fix-Pagefile' 'Remettre le fichier d''échange en gestion automatique par Windows'
    } elseif (-not $auto) { Note "Fichier d'échange en taille manuelle : $($pf[0].AllocatedBaseSize) Mio" }
    else { Pass 'Fichier d''échange géré automatiquement' }
    $big = Get-Process | Where-Object { $_.WorkingSet64 -gt 2GB } | Sort-Object WorkingSet64 -Descending | Select-Object -First 3
    if ($big) { Add-Finding 'info' 'memory' 'Processus utilisant plus de 2 Gio' (($big | ForEach-Object { "$($_.ProcessName) ($([int]($_.WorkingSet64/1MB)) Mio)" }) -join ', ') }
    $t3 = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 3
    Note ('Top mémoire : ' + (($t3 | ForEach-Object { "$($_.ProcessName)($([int]($_.WorkingSet64/1MB)) Mio)" }) -join ' '))
}

# ---------- 4. Stockage ----------
function Get-DiskHogs {
    $items = @(
        @{ N = 'Temp utilisateur'; P = $env:TEMP },
        @{ N = 'Temp Windows'; P = "$env:windir\Temp" },
        @{ N = 'Cache Windows Update'; P = "$env:windir\SoftwareDistribution\Download" },
        @{ N = 'Windows.old'; P = "$env:SystemDrive\Windows.old" },
        @{ N = 'Vidages mémoire'; P = "$env:windir\Minidump" },
        @{ N = 'Rapports d''erreurs'; P = "$env:ProgramData\Microsoft\Windows\WER" },
        @{ N = 'Téléchargements'; P = "$env:USERPROFILE\Downloads" }
    )
    $out = @()
    foreach ($i in $items) { $b = Get-FolderBytes $i.P; if ($b -gt 200MB) { $out += [pscustomobject]@{ N = $i.N; B = $b } } }
    return ($out | Sort-Object B -Descending)
}
function Mod-Disk {
    $vols = @(Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.Size -gt 0 })
    $bad = $false
    foreach ($v in $vols) {
        $used = [int](100 - ($v.SizeRemaining * 100 / $v.Size)); $l = "$($v.DriveLetter):"
        if ($l -eq "$env:SystemDrive") { $script:RootPct = $used }
        $detail = "$($v.FileSystem), $(Get-Gio $v.SizeRemaining) libres sur $(Get-Gio $v.Size)"
        if ($used -ge 85 -and $l -eq "$env:SystemDrive" -and -not $script:QuickMode) {
            $h = @(Get-DiskHogs); if ($h.Count -gt 0) { $detail += ' — Gros dossiers : ' + (($h | Select-Object -First 4 | ForEach-Object { "$($_.N) $(Get-Gio $_.B)" }) -join ', ') }
        }
        if ($used -ge 95) { Add-Finding 'crit' 'disk' "Disque $l plein à $used %" $detail 'Fix-DiskClean' 'Nettoyer fichiers temporaires, cache Windows Update, corbeille, vidages mémoire, composants obsolètes'; $bad = $true }
        elseif ($used -ge 85) { Add-Finding 'warn' 'disk' "Disque $l à $used %" $detail 'Fix-DiskClean' 'Nettoyer fichiers temporaires, cache Windows Update, corbeille, vidages mémoire, composants obsolètes'; $bad = $true }
        elseif ($v.SizeRemaining -lt 10GB) { Add-Finding 'warn' 'disk' "Moins de 10 Gio libres sur $l" $detail 'Fix-DiskClean' 'Nettoyer fichiers temporaires, cache Windows Update, corbeille, vidages mémoire, composants obsolètes'; $bad = $true }
        else { Note "$l : $used % utilisé ($(Get-Gio $v.SizeRemaining) libres)" }
    }
    if (-not $bad) { Pass 'Espace disque suffisant sur tous les volumes' }

    $dirty = @(Get-CimInstance Win32_Volume | Where-Object { $_.DriveType -eq 3 -and $_.DriveLetter -and $_.DirtyBitSet })
    if ($dirty.Count -gt 0) {
        Add-Finding 'crit' 'disk' ('Volume(s) marqué(s) « sale » : ' + (($dirty | ForEach-Object { $_.DriveLetter }) -join ' ')) 'Le système de fichiers n''a pas été fermé proprement : une vérification est nécessaire' 'Fix-Chkdsk' 'Programmer chkdsk /f au prochain démarrage'
        [void]$script:RebootReasons.Add('Une vérification de disque (chkdsk) est programmée.')
    } else { Pass 'Aucun volume marqué comme sale' }

    $pd = @(Get-PhysicalDisk)
    $okDisk = $true
    foreach ($d in $pd) {
        $name = "$($d.FriendlyName) ($($d.MediaType), $(Get-Gio $d.Size))"
        if ("$($d.HealthStatus)" -ne 'Healthy') { Add-Finding 'crit' 'disk' "Disque $name : santé « $($d.HealthStatus) »" 'Sauvegardez immédiatement vos données et remplacez ce disque'; $okDisk = $false }
        elseif ("$($d.OperationalStatus)" -ne 'OK') { Add-Finding 'warn' 'disk' "Disque $name : état « $($d.OperationalStatus) »" ''; $okDisk = $false }
        $rc = $d | Get-StorageReliabilityCounter
        if ($rc) {
            if ($rc.Temperature -gt 65) { Add-Finding 'warn' 'disk' "Disque $($d.FriendlyName) chaud : $($rc.Temperature) °C" '' ; $okDisk = $false }
            if ($rc.Wear -gt 90) { Add-Finding 'warn' 'disk' "SSD $($d.FriendlyName) usé à $($rc.Wear) %" 'Fin de vie proche : prévoyez le remplacement'; $okDisk = $false }
            if ($rc.ReadErrorsUncorrected -gt 0) { Add-Finding 'warn' 'disk' "Disque $($d.FriendlyName) : $($rc.ReadErrorsUncorrected) erreurs de lecture non corrigées" 'Sauvegardez vos données'; $okDisk = $false }
        }
    }
    $pf = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus | Where-Object { $_.PredictFailure })
    if ($pf.Count -gt 0) { Add-Finding 'crit' 'disk' 'SMART : une panne de disque est prédite' 'Sauvegardez immédiatement vos données et remplacez le disque'; $okDisk = $false }
    if ($pd.Count -gt 0 -and $okDisk) { Pass 'Disques physiques en bonne santé (SMART)' }

    $ev = @(Get-EventsSafe @{ LogName = 'System'; ProviderName = 'disk'; Id = 7, 11, 51, 153; StartTime = (Get-Date).AddDays(-30) } 200)
    $ev += @(Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Ntfs'; Id = 55; StartTime = (Get-Date).AddDays(-30) } 50)
    if ($ev.Count -ge 3) { Add-Finding 'crit' 'disk' "$($ev.Count) erreurs d'E/S disque en 30 jours" 'Bloc défectueux, câble ou disque défaillant : sauvegardez vos données' }
    elseif ($ev.Count -gt 0) { Add-Finding 'warn' 'disk' "$($ev.Count) erreur(s) d'E/S disque en 30 jours" 'À surveiller' }
    else { Pass 'Journal : aucune erreur d''E/S disque (30 j)' }

    $m = (& fsutil.exe behavior query DisableDeleteNotify 2>$null) -join ' '
    if ($m -match 'DisableDeleteNotify\s*=\s*(\d)' -and $Matches[1] -eq '1' -and @($pd | Where-Object { "$($_.MediaType)" -eq 'SSD' }).Count -gt 0) {
        Add-Finding 'info' 'disk' 'TRIM désactivé alors qu''un SSD est présent' '' 'Fix-Trim' 'Activer TRIM et lancer une optimisation'
    }
}

# ---------- 5. Services & demarrage ----------
function Mod-Services {
    $crit = [ordered]@{
        'EventLog' = 'Journal d''événements'; 'RpcSs' = 'Appel de procédure distante (RPC)'; 'DcomLaunch' = 'DCOM'; 'Winmgmt' = 'WMI'
        'Schedule' = 'Planificateur de tâches'; 'CryptSvc' = 'Services de chiffrement'; 'Dhcp' = 'Client DHCP'; 'Dnscache' = 'Client DNS'
        'BFE' = 'Moteur de filtrage'; 'mpssvc' = 'Pare-feu Windows'; 'Audiosrv' = 'Audio Windows'; 'LanmanWorkstation' = 'Station de travail'
        'ProfSvc' = 'Profils utilisateur'; 'UserManager' = 'Gestionnaire d''utilisateurs'; 'PlugPlay' = 'Plug-and-Play'; 'Themes' = 'Thèmes'
    }
    $toStart = @(); $toEnable = @()
    foreach ($k in $crit.Keys) {
        $s = Get-Service -Name $k -ErrorAction SilentlyContinue
        if (-not $s) { continue }
        if ("$($s.StartType)" -eq 'Disabled') { $toEnable += $k }
        elseif ($s.Status -ne 'Running') { $toStart += $k }
    }
    foreach ($k in 'wuauserv', 'BITS') { $s = Get-Service -Name $k -ErrorAction SilentlyContinue; if ($s -and "$($s.StartType)" -eq 'Disabled') { $toEnable += $k } }
    if ($toEnable.Count -gt 0) { Add-Finding 'warn' 'services' 'Service(s) essentiel(s) désactivé(s)' ($toEnable -join ', ') 'Fix-CriticalServices' 'Réactiver et démarrer les services essentiels' }
    if ($toStart.Count -gt 0) { Add-Finding 'warn' 'services' 'Service(s) essentiel(s) arrêté(s)' ($toStart -join ', ') 'Fix-CriticalServices' 'Réactiver et démarrer les services essentiels' }
    if ($toEnable.Count -eq 0 -and $toStart.Count -eq 0) { Pass 'Services essentiels de Windows : tous actifs' }

    $failed = @(Get-CimInstance Win32_Service | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and $_.ExitCode -notin 0, 1077, 1641, 3010 })
    if ($failed.Count -gt 0) { Add-Finding 'warn' 'services' "$($failed.Count) service(s) automatique(s) en échec" (Join-Short ($failed | ForEach-Object { "$($_.Name)[$($_.ExitCode)]" }) 8) 'Fix-FailedServices' 'Redémarrer les services automatiques en échec' }
    else { Pass 'Aucun service automatique en échec' }

    $boots = @(Get-EventsSafe @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } 5)
    $times = @()
    foreach ($e in $boots) { try { $x = [xml]$e.ToXml(); $bt = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' }).'#text'; if ($bt) { $times += [double]$bt / 1000 } } catch { } }
    if ($times.Count -gt 0) {
        $avg = [int](($times | Measure-Object -Average).Average)
        Note "Temps de démarrage moyen : $avg s"
        if ($avg -gt 120) { Add-Finding 'info' 'services' "Démarrage lent ($avg s en moyenne)" 'Réduisez les programmes au démarrage (Gestionnaire des tâches > Démarrage)' }
    }
    $su = @(Get-CimInstance Win32_StartupCommand)
    if ($su.Count -gt 25) { Add-Finding 'info' 'services' "$($su.Count) programmes au démarrage" 'Beaucoup ralentissent le démarrage' } else { Note "Programmes au démarrage : $($su.Count)" }
}

# ---------- 6. Mises a jour ----------
function Mod-Updates {
    $hf = Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($hf) {
        $age = [int]((Get-Date) - $hf.InstalledOn).TotalDays
        Note "Dernier correctif installé : $($hf.HotFixID) il y a $age j"
        if ($age -gt 120) { Add-Finding 'crit' 'updates' "Aucune mise à jour depuis $age jours" 'Failles de sécurité non corrigées' 'Fix-InstallUpdates' 'Télécharger et installer les mises à jour Windows' }
        elseif ($age -gt 60) { Add-Finding 'warn' 'updates' "Aucune mise à jour depuis $age jours" '' 'Fix-InstallUpdates' 'Télécharger et installer les mises à jour Windows' }
        else { Pass "Système à jour récemment ($age j)" }
    } else { Note 'Historique des correctifs indisponible' }

    $wu = Get-Service wuauserv -ErrorAction SilentlyContinue
    if ($wu -and "$($wu.StartType)" -eq 'Disabled') { Add-Finding 'warn' 'updates' 'Le service Windows Update est désactivé' '' 'Fix-CriticalServices' 'Réactiver et démarrer les services essentiels' }

    $fails = @(Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 20; StartTime = (Get-Date).AddDays(-14) } 100)
    if ($fails.Count -gt 3) { Add-Finding 'warn' 'updates' "$($fails.Count) échecs d'installation de mises à jour (14 j)" 'Cache Windows Update probablement corrompu' 'Fix-WuReset' 'Réinitialiser les composants Windows Update' }
    else { Pass 'Aucun échec répété de Windows Update' }

    if (-not $script:QuickMode) {
        Note 'Recherche des mises à jour en attente (peut prendre une minute)…'
        $res = Invoke-Timeout {
            try {
                $s = New-Object -ComObject Microsoft.Update.Session
                $r = $s.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
                $sec = 0; foreach ($u in $r.Updates) { foreach ($c in $u.Categories) { if ($c.Name -match 'Security') { $sec++; break } } }
                [pscustomobject]@{ Count = $r.Updates.Count; Sec = $sec }
            } catch { $null }
        } 75
        if ($res -and $res.Count -gt 0) {
            $sev = 'info'; if ($res.Sec -gt 0) { $sev = 'warn' }
            Add-Finding $sev 'updates' "$($res.Count) mise(s) à jour en attente" "dont $($res.Sec) de sécurité" 'Fix-InstallUpdates' 'Télécharger et installer les mises à jour Windows'
        } elseif ($res) { Pass 'Aucune mise à jour en attente' } else { Note 'Recherche impossible (hors ligne ou délai dépassé)' }
    }
}

# ---------- 7. Securite ----------
function Mod-Security {
    $av = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct)
    $avOn = @($av | Where-Object { ($_.productState -band 0xF000) -eq 0x1000 })
    if ($av.Count -gt 0) { Note ('Antivirus déclaré(s) : ' + (($av | ForEach-Object { $_.displayName }) -join ', ')) }
    if ($av.Count -gt 0 -and $avOn.Count -eq 0) { Add-Finding 'crit' 'security' 'Aucun antivirus actif' 'Le PC n''est pas protégé' 'Fix-Defender' 'Réactiver Microsoft Defender et mettre à jour ses signatures' }
    elseif ($avOn.Count -gt 0) { Pass ('Antivirus actif : ' + (($avOn | ForEach-Object { $_.displayName }) -join ', ')) }
    $mp = $null; try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { }
    if ($mp -and $mp.AMServiceEnabled) {
        if (-not $mp.RealTimeProtectionEnabled -and ($avOn | Where-Object { $_.displayName -match 'Defender' })) { Add-Finding 'warn' 'security' 'Protection en temps réel de Defender désactivée' '' 'Fix-Defender' 'Réactiver Microsoft Defender et mettre à jour ses signatures' }
        if ($mp.AntivirusSignatureAge -gt 7) { Add-Finding 'warn' 'security' "Signatures antivirus vieilles de $($mp.AntivirusSignatureAge) jours" '' 'Fix-Defender' 'Réactiver Microsoft Defender et mettre à jour ses signatures' }
        else { Pass "Signatures Defender à jour ($($mp.AntivirusSignatureAge) j)" }
        $thr = @(Get-MpThreat | Where-Object { $_.IsActive })
        if ($thr.Count -gt 0) { Add-Finding 'crit' 'security' "$($thr.Count) menace(s) ACTIVE(S) détectée(s)" (($thr | ForEach-Object { $_.ThreatName }) -join ', ') 'Fix-DefenderThreats' 'Supprimer les menaces et lancer une analyse rapide' }
        else { Pass 'Aucune menace active détectée par Defender' }
    }

    $thirdFw = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct | Where-Object { $_.displayName -notmatch 'Windows' })
    $off = @(Get-NetFirewallProfile | Where-Object { "$($_.Enabled)" -eq 'False' } | ForEach-Object { $_.Name })
    if ($off.Count -gt 0 -and $thirdFw.Count -eq 0) { Add-Finding 'crit' 'security' ('Pare-feu désactivé : profil(s) ' + ($off -join ', ')) 'Le PC est exposé sur le réseau' 'Fix-Firewall' 'Réactiver le Pare-feu Windows sur tous les profils' }
    else { Pass 'Pare-feu actif' }

    $sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $lua = (Get-ItemProperty $sys -Name EnableLUA -ErrorAction SilentlyContinue).EnableLUA
    if ($null -ne $lua -and $lua -eq 0) { Add-Finding 'crit' 'security' 'Contrôle de compte d''utilisateur (UAC) désactivé' '' 'Fix-Uac' 'Réactiver UAC (redémarrage requis)' } else { Pass 'UAC actif' }

    $smb1 = (Get-SmbServerConfiguration -ErrorAction SilentlyContinue).EnableSMB1Protocol
    if ($smb1) { Add-Finding 'warn' 'security' 'Protocole SMBv1 activé' 'Obsolète et vulnérable (WannaCry)' 'Fix-Smb1' 'Désactiver SMBv1' } else { Pass 'SMBv1 désactivé' }

    $ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $deny = (Get-ItemProperty $ts -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
    if ($null -ne $deny -and $deny -eq 0) {
        $nla = (Get-ItemProperty "$ts\WinStations\RDP-Tcp" -Name UserAuthentication -ErrorAction SilentlyContinue).UserAuthentication
        if ($nla -eq 0) { Add-Finding 'warn' 'security' 'Bureau à distance (RDP) actif sans NLA' 'Exposition aux attaques par force brute' 'Fix-RdpNla' 'Exiger l''authentification au niveau du réseau (NLA)' }
        else { Note 'Bureau à distance (RDP) activé avec NLA' }
    } else { Pass 'Bureau à distance désactivé' }

    try {
        $g = Get-LocalUser -Name 'Guest', 'Invité' -ErrorAction SilentlyContinue | Where-Object { $_.Enabled }
        if ($g) { Add-Finding 'warn' 'security' 'Compte Invité activé' '' 'Fix-Guest' 'Désactiver le compte Invité' } else { Pass 'Compte Invité désactivé' }
        $nopw = @(Get-LocalUser | Where-Object { $_.Enabled -and -not $_.PasswordRequired })
        if ($nopw.Count -gt 0) { Add-Finding 'warn' 'security' 'Compte(s) sans mot de passe obligatoire' (($nopw | ForEach-Object { $_.Name }) -join ', ') }
        $adm = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue)
        if ($adm.Count -gt 3) { Add-Finding 'info' 'security' "$($adm.Count) comptes administrateurs" (($adm | ForEach-Object { $_.Name }) -join ', ') }
    } catch { }

    $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    if ($wl -and $wl.DefaultPassword) { Add-Finding 'warn' 'security' 'Mot de passe de connexion automatique stocké en clair dans le registre' 'Winlogon\DefaultPassword : supprimez-le (netplwiz)' }

    try {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ("$($bl.ProtectionStatus)" -eq 'Off' -and (Get-CimInstance Win32_Battery)) { Add-Finding 'info' 'security' 'Disque système non chiffré (BitLocker)' 'Conseillé sur un portable (vol/perte)' }
    } catch { }

    $fail = @(Get-EventsSafe @{ LogName = 'Security'; Id = 4625; StartTime = (Get-Date).AddHours(-24) } 300)
    if ($fail.Count -gt 50) { Add-Finding 'warn' 'security' "$($fail.Count) échecs de connexion en 24 h" 'Tentatives de force brute possibles (RDP/SMB exposés ?)' }
    $lst = @(Get-NetTCPConnection -State Listen | Where-Object { $_.LocalAddress -notin '127.0.0.1', '::1' } | Select-Object -ExpandProperty LocalPort -Unique)
    if ($lst.Count -gt 0) { Note ("Ports TCP à l'écoute (hors boucle locale) : " + (Join-Short ($lst | Sort-Object) 12)) }
}

# ---------- 8. Reseau ----------
function Mod-Network {
    $up = @(Get-NetAdapter | Where-Object { "$($_.Status)" -eq 'Up' })
    Note ('Cartes actives : ' + $(if ($up.Count) { ($up | ForEach-Object { $_.Name }) -join ', ' } else { 'aucune' }))
    $apipa = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '169.254.*' })
    if ($apipa.Count -gt 0) { Add-Finding 'warn' 'network' 'Adresse APIPA (169.254.x.x) : le DHCP ne répond pas' '' 'Fix-NetRenew' 'Renouveler le bail DHCP et vider le cache DNS' }
    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop
    if (-not $gw -or $gw -eq '0.0.0.0') {
        if ($up.Count -gt 0) { Add-Finding 'warn' 'network' 'Aucune passerelle par défaut' 'Réseau non configuré ou déconnecté' 'Fix-NetRenew' 'Renouveler le bail DHCP et vider le cache DNS' } else { Note 'Hors ligne' }
    } else {
        if (Test-Ping $gw) { Pass "Passerelle $gw joignable" } else { Add-Finding 'warn' 'network' "Passerelle $gw injoignable" '' 'Fix-NetRenew' 'Renouveler le bail DHCP et vider le cache DNS' }
    }
    $net = (Test-Ping '1.1.1.1' 3000) -or (Test-Ping '9.9.9.9' 3000)
    if ($net) { Pass 'Accès Internet (IP) : OK' } else { Note 'Accès Internet (IP) indisponible ou ICMP filtré' }
    $dnsOk = $false; try { $r = Resolve-DnsName -Name 'example.com' -DnsOnly -QuickTimeout -ErrorAction Stop; if ($r) { $dnsOk = $true } } catch { }
    if ($dnsOk) { Pass 'Résolution DNS : OK' }
    elseif ($net) { Add-Finding 'crit' 'network' 'Résolution DNS défaillante' 'Internet fonctionne par IP mais pas par nom de domaine' 'Fix-Dns' 'Vider le cache DNS, rétablir les DNS automatiques puis, si besoin, DNS publics de secours' }
    else { Note 'Résolution DNS indisponible (hors ligne ?)' }

    $px = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($px -and $px.ProxyEnable -eq 1) { Add-Finding 'info' 'network' 'Un proxy est configuré' "$($px.ProxyServer) — vérifiez qu'il est légitime (certains logiciels malveillants en installent un)" }

    $w32 = Get-Service W32Time -ErrorAction SilentlyContinue
    if ($w32 -and $w32.Status -ne 'Running') { Add-Finding 'warn' 'network' 'Service d''heure Windows (W32Time) arrêté' 'Une heure fausse casse HTTPS, mises à jour et certificats' 'Fix-TimeSync' 'Démarrer W32Time et resynchroniser l''horloge' }
    elseif ($net) {
        $o = Invoke-Timeout { (& w32tm.exe /stripchart /computer:time.windows.com /samples:1 /dataonly 2>$null) -join ' ' } 15
        if ($o -and $o -match '([+-]\d+[.,]\d+)s') {
            $off = [math]::Abs([double]($Matches[1] -replace ',', '.'))
            if ($off -gt 30) { Add-Finding 'warn' 'network' ("Horloge décalée de " + [int]$off + ' s') 'Risque d''échec HTTPS et des mises à jour' 'Fix-TimeSync' 'Démarrer W32Time et resynchroniser l''horloge' }
            elseif ($off -gt 5) { Add-Finding 'info' 'network' ("Horloge décalée de " + [int]$off + ' s') '' 'Fix-TimeSync' 'Démarrer W32Time et resynchroniser l''horloge' }
            else { Pass 'Horloge synchronisée' }
        }
    }
}

# ---------- 9. Journaux d'evenements ----------
function Mod-Logs {
    $bc = @(Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = (Get-Date).AddDays(-30) } 50)
    if ($bc.Count -gt 0) {
        $codes = @(); foreach ($e in $bc) { try { $codes += ("$($e.Properties[0].Value)" -split ' ')[0] } catch { } }
        $sev = 'warn'; if ($bc.Count -ge 2) { $sev = 'crit' }
        Add-Finding $sev 'logs' "$($bc.Count) écran(s) bleu (BSOD) en 30 jours" ('Codes : ' + (Join-Short ($codes | Select-Object -Unique) 5) + ' — pilote, RAM ou disque défaillant ?')
    } else { Pass 'Aucun écran bleu en 30 jours' }
    $kp = @(Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = (Get-Date).AddDays(-30) } 50)
    if ($kp.Count -gt 0) { Add-Finding 'warn' 'logs' "$($kp.Count) arrêt(s) inattendu(s) en 30 jours" 'Coupure, surchauffe, alimentation ou plantage' } else { Pass 'Aucun arrêt inattendu en 30 jours' }
    $wh = @(Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = (Get-Date).AddDays(-30) } 50)
    if ($wh.Count -gt 0) { $sev = 'warn'; if ($wh.Count -gt 5) { $sev = 'crit' }; Add-Finding $sev 'logs' "$($wh.Count) erreur(s) matérielle(s) (WHEA)" 'Processeur, RAM, PCIe ou disque : surveillez, testez la RAM (mdsched)' } else { Pass 'Aucune erreur matérielle WHEA' }
    $rx = @(Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Detector'; Id = 2004; StartTime = (Get-Date).AddDays(-30) } 20)
    if ($rx.Count -gt 0) { Add-Finding 'warn' 'logs' "Windows a manqué de mémoire virtuelle $($rx.Count) fois" 'Agrandissez le fichier d''échange ou ajoutez de la RAM' 'Fix-Pagefile' 'Remettre le fichier d''échange en gestion automatique par Windows' }

    $crash = @(Get-EventsSafe @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = (Get-Date).AddDays(-7) } 300)
    if ($crash.Count -gt 10) {
        $apps = $crash | ForEach-Object { try { $_.Properties[0].Value } catch { } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 3
        Add-Finding 'info' 'logs' "$($crash.Count) plantages d'applications en 7 jours" (($apps | ForEach-Object { "$($_.Name)($($_.Count))" }) -join ', ')
    }
    $sc = @(Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7031, 7034; StartTime = (Get-Date).AddDays(-7) } 200)
    if ($sc.Count -gt 3) {
        $sv = $sc | ForEach-Object { try { $_.Properties[0].Value } catch { } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 3
        Add-Finding 'info' 'logs' "$($sc.Count) plantages de services en 7 jours" (($sv | ForEach-Object { "$($_.Name)($($_.Count))" }) -join ', ')
    }
    $er = @(Get-EventsSafe @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddHours(-24) } 1000)
    if ($er.Count -gt 200) { $tp = $er | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 3; Add-Finding 'warn' 'logs' "$($er.Count) erreurs système en 24 h" (($tp | ForEach-Object { "$($_.Name)($($_.Count))" }) -join ', ') }
    elseif ($er.Count -gt 50) { Add-Finding 'info' 'logs' "$($er.Count) erreurs système en 24 h" '' }
    else { Pass "Journal système : $($er.Count) erreur(s) en 24 h" }
    $dm = @(Get-ChildItem "$env:windir\Minidump" -ErrorAction SilentlyContinue).Count
    if ($dm -gt 0) { Note "Vidages mémoire (Minidump) : $dm" }
}

# ---------- 10. Materiel ----------
function Mod-Hardware {
    $bat = @(Get-CimInstance Win32_Battery)
    if ($bat.Count -gt 0) {
        Note "Batterie : $($bat[0].EstimatedChargeRemaining) %"
        $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity | Select-Object -First 1).FullChargedCapacity
        $des = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData | Select-Object -First 1).DesignedCapacity
        if ($full -and $des -gt 0) {
            $h = [int]($full * 100 / $des)
            if ($h -lt 50) { Add-Finding 'warn' 'hardware' "Batterie usée : $h % de sa capacité d'origine" 'Remplacement conseillé' }
            elseif ($h -lt 70) { Add-Finding 'info' 'hardware' "Batterie vieillissante : $h % de sa capacité d'origine" '' }
            else { Pass "Santé de la batterie : $h %" }
        }
    }
    $tz = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature)
    if ($tz.Count -gt 0) {
        $max = [int](($tz | ForEach-Object { $_.CurrentTemperature / 10 - 273.15 } | Measure-Object -Maximum).Maximum)
        Note "Température ACPI max : $max °C"
        if ($max -ge 95) { Add-Finding 'crit' 'hardware' "Surchauffe critique : $max °C" 'Nettoyez les ventilateurs, vérifiez la pâte thermique' }
        elseif ($max -ge 85) { Add-Finding 'warn' 'hardware' "Température élevée : $max °C" '' }
        else { Pass "Températures normales ($max °C)" }
    } else { Note 'Capteurs thermiques ACPI indisponibles' }
    $bad = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22 -and $_.Name })
    if ($bad.Count -gt 0) { Add-Finding 'warn' 'hardware' "$($bad.Count) périphérique(s) en erreur" (Join-Short ($bad | ForEach-Object { "$($_.Name)[code $($_.ConfigManagerErrorCode)]" }) 4) 'Fix-Pnp' 'Relancer la détection du matériel (pnputil /scan-devices)' }
    else { Pass 'Gestionnaire de périphériques : aucune erreur' }
    $pw = (& powercfg.exe /getactivescheme 2>$null) -join ' '
    if ($pw -match 'a1841308-3541-4fab-bc81-f71556f20b4a') { Add-Finding 'info' 'hardware' 'Mode « Économie d''énergie » actif' 'Les performances sont volontairement réduites' 'Fix-PowerPlan' 'Passer au mode Utilisation normale (Équilibré)' }
}

# ---------- 11. Processus ----------
function Mod-Processes {
    $hung = @(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and -not $_.Responding })
    if ($hung.Count -gt 0) { Add-Finding 'warn' 'processes' "$($hung.Count) application(s) ne répond(ent) plus" (($hung | ForEach-Object { $_.ProcessName }) -join ', ') }
    else { Pass 'Toutes les applications répondent' }
    $hd = @(Get-Process | Where-Object { $_.Handles -gt 30000 } | Sort-Object Handles -Descending | Select-Object -First 3)
    if ($hd.Count -gt 0) { Add-Finding 'info' 'processes' 'Fuite de handles probable' (($hd | ForEach-Object { "$($_.ProcessName)($($_.Handles))" }) -join ', ') }
    Note ("Processus en cours : " + @(Get-Process).Count)
}

# ---------- 12. Integrite ----------
function Mod-Integrity {
    if ($script:QuickMode) { Note 'Mode rapide : contrôle d''intégrité ignoré'; return }
    $state = $null
    try { $state = (Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop).ImageHealthState } catch { }
    if ($state) {
        if ("$state" -eq 'Healthy') { Pass 'Magasin de composants Windows sain (DISM)' }
        else { Add-Finding 'crit' 'integrity' "Magasin de composants Windows : « $state »" 'Fichiers système endommagés' 'Fix-RepairImage' 'DISM /RestoreHealth puis sfc /scannow' }
    } else { Note 'DISM CheckHealth indisponible' }
    if ($script:DeepMode) {
        Note 'Analyse approfondie DISM (plusieurs minutes)…'
        try {
            $st = (Repair-WindowsImage -Online -ScanHealth -ErrorAction Stop).ImageHealthState
            if ("$st" -ne 'Healthy' -and "$state" -eq 'Healthy') { Add-Finding 'crit' 'integrity' "Analyse DISM approfondie : « $st »" '' 'Fix-RepairImage' 'DISM /RestoreHealth puis sfc /scannow' }
            elseif ("$st" -eq 'Healthy') { Pass 'DISM ScanHealth : aucune corruption' }
        } catch { }
        Note 'Vérification des fichiers système (sfc /verifyonly, plusieurs minutes)…'
        $t0 = Get-Date
        & sfc.exe /verifyonly 2>&1 | Out-Null
        $cbs = "$env:windir\Logs\CBS\CBS.log"
        $cannot = 0
        if (Test-Path $cbs) {
            foreach ($l in (Get-Content $cbs -Tail 6000 -ErrorAction SilentlyContinue)) {
                if ($l -match '\[SR\] Cannot repair' -and $l.Length -gt 19) {
                    try { if ([datetime]::ParseExact($l.Substring(0, 19), 'yyyy-MM-dd HH:mm:ss', $null) -ge $t0.AddMinutes(-1)) { $cannot++ } } catch { }
                }
            }
        }
        if ($cannot -gt 0) { Add-Finding 'warn' 'integrity' "SFC : $cannot fichier(s) système corrompu(s)" 'Détails : %windir%\Logs\CBS\CBS.log' 'Fix-RepairImage' 'DISM /RestoreHealth puis sfc /scannow' }
        else { Pass 'SFC : fichiers système intègres' }
    } else { Note 'Mode -Deep : active DISM ScanHealth et sfc /verifyonly' }
}

# Registre : id|libelle|fonction
$script:Modules = @(
    @('system', 'Identité & système', 'Mod-System'),
    @('cpu', 'Processeur & activité disque', 'Mod-Cpu'),
    @('memory', 'Mémoire & fichier d''échange', 'Mod-Memory'),
    @('disk', 'Stockage & santé des disques', 'Mod-Disk'),
    @('services', 'Services & démarrage', 'Mod-Services'),
    @('updates', 'Mises à jour Windows', 'Mod-Updates'),
    @('security', 'Sécurité', 'Mod-Security'),
    @('network', 'Réseau & horloge', 'Mod-Network'),
    @('logs', 'Journaux d''événements', 'Mod-Logs'),
    @('hardware', 'Matériel : batterie, températures, pilotes', 'Mod-Hardware'),
    @('processes', 'Processus & ressources', 'Mod-Processes'),
    @('integrity', 'Intégrité de Windows (DISM / SFC)', 'Mod-Integrity')
)

# =============================================================================
#  SOINS (reparations)
# =============================================================================
function Fix-Wmi { $ok = Do-It 'winmgmt /salvagerepository' { & winmgmt.exe /salvagerepository }; [void]$script:RebootReasons.Add('Le référentiel WMI a été réparé.'); return $ok }

function Fix-DiskClean {
    $drv = $env:SystemDrive.TrimEnd(':')
    $before = (Get-Volume -DriveLetter $drv).SizeRemaining
    $limit = (Get-Date).AddDays(-3)
    Do-It 'Temp utilisateur (fichiers > 3 jours)' { Get-ChildItem $env:TEMP -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue } | Out-Null
    Do-It 'Temp Windows (fichiers > 3 jours)' { Get-ChildItem "$env:windir\Temp" -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue } | Out-Null
    Do-It 'Corbeille' { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } | Out-Null
    Do-It 'Cache de téléchargement Windows Update' {
        Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
        Get-ChildItem "$env:windir\SoftwareDistribution\Download" -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service bits, wuauserv -ErrorAction SilentlyContinue
    } | Out-Null
    Do-It 'Vidages mémoire et rapports d''erreurs (> 7 jours)' {
        $l7 = (Get-Date).AddDays(-7)
        Get-ChildItem "$env:windir\Minidump", "$env:windir\LiveKernelReports", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue", "$env:ProgramData\Microsoft\Windows\WER\ReportArchive" -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $l7 } | Remove-Item -Force -ErrorAction SilentlyContinue
    } | Out-Null
    Do-It 'Cache Delivery Optimization' { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue } | Out-Null
    Do-It 'Composants Windows obsolètes (DISM StartComponentCleanup)' { & dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet } | Out-Null
    if (Get-Command docker -ErrorAction SilentlyContinue) { Do-It 'Docker : images dangling' { & docker image prune -f } | Out-Null }
    Say-Act 'Fichiers temporaires, corbeille, cache Windows Update, vidages mémoire, composants obsolètes nettoyés'
    if (Test-Path "$env:SystemDrive\Windows.old") { Say-Warn 'Windows.old est présent : supprimez-le via Paramètres > Stockage > Fichiers temporaires (action manuelle).' }
    $after = (Get-Volume -DriveLetter $drv).SizeRemaining
    $gain = [math]::Max(0, $after - $before)
    Say-Ok ("Espace récupéré sur $($env:SystemDrive) : " + (Get-Gio $gain))
    return $true
}
function Fix-Chkdsk {
    $ok = $true
    foreach ($v in @(Get-CimInstance Win32_Volume | Where-Object { $_.DriveType -eq 3 -and $_.DriveLetter -and $_.DirtyBitSet })) {
        $l = $v.DriveLetter
        $r = Do-It "chkdsk $l /f (au prochain démarrage)" { 'Y' | & cmd.exe /c "chkdsk $l /f" }
        if (-not $r) { $ok = $false }
    }
    return $ok
}
function Fix-Trim {
    $a = Do-It 'fsutil behavior set DisableDeleteNotify 0' { & fsutil.exe behavior set DisableDeleteNotify 0 }
    $b = Do-It 'Optimize-Volume -ReTrim' { Optimize-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') -ReTrim }
    return ($a -and $b)
}
function Fix-CriticalServices {
    $ok = $true
    foreach ($n in 'EventLog', 'RpcSs', 'DcomLaunch', 'Winmgmt', 'Schedule', 'CryptSvc', 'Dhcp', 'Dnscache', 'BFE', 'mpssvc', 'Audiosrv', 'LanmanWorkstation', 'ProfSvc', 'UserManager', 'PlugPlay', 'Themes', 'wuauserv', 'BITS') {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue; if (-not $s) { continue }
        if ("$($s.StartType)" -eq 'Disabled') {
            $t = 'Automatic'; if ($n -in 'wuauserv', 'BITS') { $t = 'Manual' }
            $r = Do-It "Réactiver le service $n ($t)" { Set-Service -Name $n -StartupType $t }
            if ($r) { Say-Act "$n réactivé" } else { $ok = $false }
        }
        if ($n -notin 'wuauserv', 'BITS' -and (Get-Service $n).Status -ne 'Running') {
            $r = Do-It "Démarrer le service $n" { Start-Service -Name $n }
            if ($r) { Say-Act "$n démarré" } else { $ok = $false }
        }
    }
    return $ok
}
function Fix-FailedServices {
    $ok = $true
    $list = @(Get-CimInstance Win32_Service | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and $_.ExitCode -notin 0, 1077, 1641, 3010 })
    foreach ($s in $list) {
        $n = $s.Name
        $r = Do-It "Démarrer $n" { Start-Service -Name $n }
        if ($script:Dry) { continue }
        Start-Sleep -Seconds 2
        if ($r -and (Get-Service $n).Status -eq 'Running') { Say-Act "$n redémarré et stable" }
        else { Say-Warn "$n ne démarre pas. Si ce service est inutile : Set-Service $n -StartupType Disabled"; $ok = $false }
    }
    return $ok
}
function Fix-Pagefile {
    return (Do-It 'Fichier d''échange géré par Windows' {
            $cs = Get-CimInstance Win32_ComputerSystem
            if (-not $cs.AutomaticManagedPagefile) { Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } }
            [void]$script:RebootReasons.Add('Le fichier d''échange a été remis en gestion automatique.')
        })
}
function Fix-RepairImage {
    $a = Do-It 'DISM /RestoreHealth (peut durer 10 à 30 min, nécessite Internet)' { Repair-WindowsImage -Online -RestoreHealth }
    $b = Do-It 'sfc /scannow' { & sfc.exe /scannow }
    return ($a -and $b)
}
function Fix-WuReset {
    return (Do-It 'Réinitialisation des composants Windows Update' {
            Stop-Service wuauserv, bits, cryptsvc -Force
            $s = "$env:windir\SoftwareDistribution"; $c = "$env:windir\System32\catroot2"
            if (Test-Path "$s.bak") { Remove-Item "$s.bak" -Recurse -Force }
            if (Test-Path "$c.bak") { Remove-Item "$c.bak" -Recurse -Force }
            if (Test-Path $s) { Rename-Item $s "$s.bak" }
            if (Test-Path $c) { Rename-Item $c "$c.bak" }
            Start-Service cryptsvc, bits, wuauserv
        })
}
function Fix-InstallUpdates {
    return (Do-It 'Téléchargement et installation des mises à jour Windows' {
            $s = New-Object -ComObject Microsoft.Update.Session
            $u = $s.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'").Updates
            $coll = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($x in $u) { if (-not $x.InstallationBehavior.CanRequestUserInput) { [void]$coll.Add($x) } }
            if ($coll.Count -eq 0) { return }
            $d = $s.CreateUpdateDownloader(); $d.Updates = $coll; [void]$d.Download()
            $i = $s.CreateUpdateInstaller(); $i.Updates = $coll; $r = $i.Install()
            if ($r.RebootRequired) { [void]$script:RebootReasons.Add('Des mises à jour viennent d''être installées : redémarrage requis.') }
        })
}
function Fix-Defender {
    $a = Do-It 'Réactiver la protection en temps réel de Defender' { Set-MpPreference -DisableRealtimeMonitoring $false }
    $b = Do-It 'Mettre à jour les signatures Defender' { Update-MpSignature }
    return ($a -and $b)
}
function Fix-DefenderThreats {
    $a = Do-It 'Supprimer les menaces détectées' { Remove-MpThreat }
    $b = Do-It 'Analyse rapide Defender' { Start-MpScan -ScanType QuickScan }
    return ($a -and $b)
}
function Fix-Firewall { return (Do-It 'Activer le Pare-feu Windows (tous les profils)' { Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled True }) }
function Fix-Uac {
    $k = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Backup-Reg $k
    $r = Do-It 'Réactiver UAC (EnableLUA=1)' { Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -Value 1 }
    [void]$script:RebootReasons.Add('UAC réactivé : redémarrage requis.')
    return $r
}
function Fix-Smb1 { return (Do-It 'Désactiver SMBv1' { Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force }) }
function Fix-RdpNla {
    Backup-Reg 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    return (Do-It 'Exiger NLA pour le Bureau à distance' { Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1 })
}
function Fix-Guest { return (Do-It 'Désactiver le compte Invité' { Get-LocalUser -Name 'Guest', 'Invité' -ErrorAction SilentlyContinue | Disable-LocalUser }) }
function Fix-NetRenew {
    $a = Do-It 'ipconfig /flushdns' { & ipconfig.exe /flushdns }
    $b = Do-It 'ipconfig /release puis /renew' { & ipconfig.exe /release; Start-Sleep 2; & ipconfig.exe /renew }
    return ($a -and $b)
}
function Fix-Dns {
    Do-It 'ipconfig /flushdns' { & ipconfig.exe /flushdns } | Out-Null
    Do-It 'Rétablir les DNS automatiques (DHCP)' { Get-NetAdapter | Where-Object { "$($_.Status)" -eq 'Up' } | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses } } | Out-Null
    if ($script:Dry) { return $true }
    Start-Sleep 3
    $ok = $false; try { if (Resolve-DnsName example.com -DnsOnly -QuickTimeout -ErrorAction Stop) { $ok = $true } } catch { }
    if (-not $ok) {
        Say-Warn 'DNS toujours HS : DNS publics de secours (1.1.1.1, 9.9.9.9)'
        $ok = Do-It 'Définir 1.1.1.1 / 9.9.9.9' { Get-NetAdapter | Where-Object { "$($_.Status)" -eq 'Up' } | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ('1.1.1.1', '9.9.9.9') } }
    }
    return $ok
}
function Fix-TimeSync {
    $a = Do-It 'Démarrer W32Time' { Set-Service W32Time -StartupType Automatic; Start-Service W32Time }
    $b = Do-It 'w32tm /resync /force' { & w32tm.exe /resync /force }
    return ($a -and $b)
}
function Fix-PowerPlan { return (Do-It 'powercfg /setactive (Équilibré)' { & powercfg.exe /setactive 381b4222-f694-41f0-9685-ff5bb260df2e }) }
function Fix-Pnp { return (Do-It 'pnputil /scan-devices' { & pnputil.exe /scan-devices }) }

# =============================================================================
#  SCAN, SCORE, RAPPORT
# =============================================================================
function Get-SelectedModules {
    $onlyL = @($Only -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $skipL = @($Skip -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return @($script:Modules | Where-Object { ($onlyL.Count -eq 0 -or $onlyL -contains $_[0]) -and ($skipL -notcontains $_[0]) })
}
function Invoke-Scan {
    $script:Findings.Clear(); $script:PassCount = 0; $script:RebootReasons.Clear()
    $sel = Get-SelectedModules; $i = 0
    foreach ($m in $sel) {
        $i++
        if (-not $script:Quiet) { Show-ModuleHeader $i $sel.Count $m[1] }
        Write-Log "MODULE: $($m[0])"
        try { & $m[2] } catch { Write-Log ("ERREUR MODULE $($m[0]) : " + $_.Exception.Message); if (-not $script:Quiet) { Note ("Module $($m[0]) interrompu : " + $_.Exception.Message) } }
    }
    Update-Score
}
function Update-Score {
    $script:NC = @($script:Findings | Where-Object { $_.Sev -eq 'crit' }).Count
    $script:NW = @($script:Findings | Where-Object { $_.Sev -eq 'warn' }).Count
    $script:NI = @($script:Findings | Where-Object { $_.Sev -eq 'info' }).Count
    $s = 100 - $script:NC * 12 - $script:NW * 4 - $script:NI
    if ($s -lt 0) { $s = 0 }
    if ($script:NC -gt 0 -and $s -gt 69) { $s = 69 }
    $script:Score = $s
}
function Get-ScoreLabel { if ($script:Score -ge 90) { 'Excellente santé' } elseif ($script:Score -ge 75) { 'Bonne santé' } elseif ($script:Score -ge 50) { 'À soigner' } else { 'État préoccupant' } }
function Get-ScoreColor { if ($script:Score -ge 90) { 'Green' } elseif ($script:Score -ge 75) { 'DarkGreen' } elseif ($script:Score -ge 50) { 'Yellow' } else { 'Red' } }
function Wrap-Text([string]$t, [int]$w) {
    $out = @(); $line = ''
    foreach ($word in ($t -split '\s+')) {
        if (($line.Length + $word.Length + 1) -gt $w -and $line) { $out += $line; $line = $word } else { if ($line) { $line += ' ' + $word } else { $line = $word } }
    }
    if ($line) { $out += $line }
    return $out
}
function Show-Summary {
    Say-Title 'DIAGNOSTIC'
    $f = [int]($script:Score / 5); $bar = ('█' * $f) + ('░' * (20 - $f))
    Write-Host ''; Write-Host '  Indice de santé  ' -NoNewline; Write-Host $bar -ForegroundColor (Get-ScoreColor) -NoNewline
    Write-Host ("  $($script:Score)/100") -ForegroundColor (Get-ScoreColor) -NoNewline; Write-Host " — $(Get-ScoreLabel)"
    Write-Host "  ✘ $($script:NC) critique(s)   " -ForegroundColor Red -NoNewline
    Write-Host "▲ $($script:NW) avertissement(s)   " -ForegroundColor Yellow -NoNewline
    Write-Host "ℹ $($script:NI) info(s)   " -ForegroundColor Blue -NoNewline
    Write-Host "✔ $($script:PassCount) contrôle(s) réussi(s)" -ForegroundColor Green
    if ($script:Findings.Count -eq 0) { Write-Host ''; Write-Host '  Aucune anomalie détectée. Le patient est en pleine forme !' -ForegroundColor Green; return }
    $n = 0
    foreach ($sev in 'crit', 'warn', 'info') {
        $lbl = 'INFORMATION'; $col = 'Blue'; $ic = 'ℹ'
        if ($sev -eq 'crit') { $lbl = 'CRITIQUE'; $col = 'Red'; $ic = '✘' } elseif ($sev -eq 'warn') { $lbl = 'AVERTISSEMENT'; $col = 'Yellow'; $ic = '▲' }
        $items = @($script:Findings | Where-Object { $_.Sev -eq $sev }); if ($items.Count -eq 0) { continue }
        Write-Host ''; Write-Host "  $lbl" -ForegroundColor $col
        foreach ($it in $items) {
            $n++
            Write-Host ("  $ic {0,2}. " -f $n) -ForegroundColor $col -NoNewline; Write-Host $it.Title -ForegroundColor White -NoNewline; Write-Host "  [$($it.Mod)]" -ForegroundColor DarkGray
            if ($it.Detail) { foreach ($l in (Wrap-Text $it.Detail ($script:Cols - 10))) { Write-Host ('         ' + $l) -ForegroundColor DarkGray } }
            if ($it.Fix) { Write-Host '       Rx → ' -ForegroundColor Cyan -NoNewline; Write-Host $it.FixDesc }
        }
    }
}
function Write-Reports {
    try {
        New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
        $t = New-Object System.Collections.ArrayList
        [void]$t.Add("$($script:App) v$($script:Version) — by BuildWith")
        [void]$t.Add("Rapport du $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') — hôte $env:COMPUTERNAME")
        [void]$t.Add("Indice de santé : $($script:Score)/100 ($(Get-ScoreLabel)) — critiques: $($script:NC), avertissements: $($script:NW), infos: $($script:NI), réussis: $($script:PassCount)")
        [void]$t.Add('')
        foreach ($f in $script:Findings) {
            [void]$t.Add("[$($f.Sev.ToUpper())] ($($f.Mod)) $($f.Title)"); [void]$t.Add("    $($f.Detail)")
            if ($f.Fix) { [void]$t.Add("    Soin proposé : $($f.FixDesc)") }
        }
        if ($script:FixResults.Count -gt 0) { [void]$t.Add(''); [void]$t.Add('Traitements :'); foreach ($r in $script:FixResults) { [void]$t.Add("  $r") } }
        Set-Content -Path $script:ReportTxt -Value $t -Encoding UTF8
        $obj = [ordered]@{
            tool = $script:App; version = $script:Version; signature = 'by BuildWith'; date = (Get-Date -Format 's'); host = $env:COMPUTERNAME
            score = $script:Score; critical = $script:NC; warnings = $script:NW; info = $script:NI; passed = $script:PassCount
            findings = @($script:Findings | ForEach-Object { [ordered]@{ severity = $_.Sev; module = $_.Mod; title = $_.Title; detail = $_.Detail; fix = $_.FixDesc } })
        }
        $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $script:ReportJson -Encoding UTF8
    } catch { }
}

# =============================================================================
#  TRAITEMENT
# =============================================================================
function Invoke-Heal {
    if (-not (Test-Admin)) { Say-Err 'Le traitement exige les droits administrateur.'; return }
    $seen = @{}; $list = @()
    foreach ($sev in 'crit', 'warn', 'info') {
        foreach ($f in @($script:Findings | Where-Object { $_.Sev -eq $sev -and $_.Fix })) { if (-not $seen.ContainsKey($f.Fix)) { $seen[$f.Fix] = 1; $list += $f } }
    }
    Say-Title 'ORDONNANCE'
    if ($list.Count -eq 0) { Say-Ok 'Aucun soin automatique à administrer.'; return }
    if ($script:Dry) { Say-Warn 'MODE SIMULATION : aucun changement ne sera appliqué.' }
    Say-Info "$($list.Count) soin(s) proposé(s). Sauvegardes du registre : $($script:BackupDir)"
    if (-not $script:Dry) {
        try {
            Say-Info 'Création d''un point de restauration Windows…'
            Checkpoint-Computer -Description 'BuildWith Doctor' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            Say-Ok 'Point de restauration créé.'
        } catch { Say-Warn 'Point de restauration non créé (protection du système désactivée ou limite de 24 h).' }
    }
    $okN = 0; $koN = 0; $skN = 0; $idx = 0
    foreach ($f in $list) {
        $idx++
        Write-Host ''; Write-Host "[$idx/$($list.Count)] " -ForegroundColor Cyan -NoNewline; Write-Host $f.FixDesc -ForegroundColor White -NoNewline; Write-Host "  ($($f.Title))" -ForegroundColor DarkGray
        if ($f.Sev -eq 'info' -and $script:AutoYes -and -not $script:FullMode) { Say-Info 'Soin optionnel ignoré (ajoutez -Full pour l''inclure).'; [void]$script:FixResults.Add("IGNORÉ  $($f.FixDesc)"); $skN++; continue }
        if (-not (Confirm-Action '  Administrer ce soin ?')) { [void]$script:FixResults.Add("REFUSÉ  $($f.FixDesc)"); $skN++; continue }
        Write-Log "SOIN: $($f.Fix)"
        $res = $null; try { $res = & $f.Fix } catch { Say-Warn $_.Exception.Message }
        $good = (@($res) | Select-Object -Last 1) -eq $true
        if ($good) { Say-Ok 'Soin appliqué.'; [void]$script:FixResults.Add("OK      $($f.FixDesc)"); $okN++ }
        else { Say-Err "Le soin a échoué ou n'est que partiel (voir $($script:ActionLog))."; [void]$script:FixResults.Add("ÉCHEC   $($f.FixDesc)"); $koN++ }
    }
    Write-Host ''; Write-Host "  ✔ $okN appliqué(s)   " -ForegroundColor Green -NoNewline; Write-Host "✘ $koN échec(s)   " -ForegroundColor Red -NoNewline; Write-Host "• $skN ignoré(s)" -ForegroundColor DarkGray
}
function Invoke-Recheck {
    Say-Title 'CONTRE-VISITE'
    $before = $script:Score
    $script:Quiet = $true; Write-Host '  Nouvelle auscultation en cours…'
    Invoke-Scan; $script:Quiet = $false
    Write-Host ''; Write-Host "  Indice de santé : $before → " -NoNewline; Write-Host "$($script:Score)/100" -ForegroundColor (Get-ScoreColor) -NoNewline; Write-Host " ($(Get-ScoreLabel))"
    if ($script:Findings.Count -gt 0) { Write-Host '  Problèmes restants :'; foreach ($f in $script:Findings) { Write-Host "   • [$($f.Sev)] $($f.Title)" -ForegroundColor DarkGray } }
    else { Write-Host '  Tous les symptômes ont disparu.' -ForegroundColor Green }
}
function Invoke-RebootCheck {
    Say-Title 'FAUT-IL REDÉMARRER ?'
    if ($NoReboot) { Say-Info 'Redémarrage non proposé (-NoReboot).'; return }
    $pr = @(Get-PendingReboot); foreach ($p in $pr) { if (-not ($script:RebootReasons -contains "Redémarrage en attente : $p")) { [void]$script:RebootReasons.Add($p) } }
    if ($script:RebootReasons.Count -eq 0) { Say-Ok 'Aucun redémarrage nécessaire.'; return }
    Say-Warn "Redémarrage recommandé pour $($script:RebootReasons.Count) raison(s) :"
    foreach ($r in ($script:RebootReasons | Select-Object -Unique)) { Write-Host "   • $r" }
    if ($script:Dry) { Say-Info 'Simulation : pas de redémarrage.'; return }
    if (-not (Test-Admin)) { return }
    if ($script:AutoYes) { Say-Info 'Redémarrage non automatique : relancez-le vous-même quand vous êtes prêt.'; return }
    if (Confirm-Action 'Redémarrer maintenant ? Enregistrez votre travail avant.') {
        Say-Warn 'Redémarrage dans 15 s — Ctrl+C pour annuler.'
        for ($s = 15; $s -ge 1; $s--) { Write-Host ("`r  {0,2} s " -f $s) -NoNewline; Start-Sleep 1 }
        Write-Host ''; Restart-Computer -Force
    } else { Say-Info 'Pensez à redémarrer dès que possible.' }
}

# =============================================================================
#  MENU
# =============================================================================
function Show-Menu {
    Write-Host ''
    $items = @(
        @('1', 'Consultation complète', '(diagnostic seul, aucune modification)'),
        @('2', 'Consultation + traitement', '(je valide chaque soin)'),
        @('3', 'Traitement automatique', '(soins critiques/importants sans question)'),
        @('4', 'Consultation approfondie', '(+ DISM, SFC, mises à jour en attente)'),
        @('5', 'Consultation rapide', ''),
        @('6', 'Simulation du traitement', '(-DryRun : rien ne change)'),
        @('7', 'Lire le dernier rapport', ''),
        @('0', 'Quitter', '')
    )
    foreach ($i in $items) { Write-Host "  $($i[0])) " -ForegroundColor Cyan -NoNewline; Write-Host ($i[1].PadRight(28)) -NoNewline; Write-Host $i[2] -ForegroundColor DarkGray }
    Write-Host ''
    $c = Read-Host '  Votre choix'
    switch ($c) {
        '1' { $script:Action = 'scan' }
        '2' { $script:Action = 'heal' }
        '3' { $script:Action = 'heal'; $script:AutoYes = $true }
        '4' { $script:Action = 'scan'; $script:DeepMode = $true }
        '5' { $script:Action = 'scan'; $script:QuickMode = $true }
        '6' { $script:Action = 'heal'; $script:Dry = $true }
        '7' {
            $last = Get-ChildItem $script:LogDir -Filter 'rapport-*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($last) { Get-Content $last.FullName | More } else { Say-Warn 'Aucun rapport précédent.' }
            return $false
        }
        default { Write-Host ''; Write-Host '  Bonne continuation !'; Show-Signature; return $false }
    }
    return $true
}

# =============================================================================
#  PROGRAMME PRINCIPAL
# =============================================================================
function Wait-End { if ($Elevated) { Write-Host ''; Read-Host 'Appuyez sur Entrée pour fermer cette fenêtre' | Out-Null } }

function Invoke-Elevate {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($k in $script:BoundCopy.Keys) {
        if ($k -eq 'Elevated') { continue }
        $v = $script:BoundCopy[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $a += "-$k" } } else { $a += @("-$k", ('"{0}"' -f $v)) }
    }
    $a += '-Elevated'
    $exe = 'powershell.exe'; if ($PSVersionTable.PSEdition -eq 'Core') { $exe = 'pwsh.exe' }
    try { Start-Process -FilePath $exe -ArgumentList $a -Verb RunAs -ErrorAction Stop; return $true } catch { return $false }
}
$script:BoundCopy = @{}; foreach ($k in $PSBoundParameters.Keys) { $script:BoundCopy[$k] = $PSBoundParameters[$k] }

if ($List) {
    Write-Host 'Modules disponibles :' -ForegroundColor White
    foreach ($m in $script:Modules) { Write-Host ("  {0,-10} {1}" -f $m[0], $m[1]) }
    exit 0
}
if ($Demo) { Show-Splash; Show-Signature; exit 0 }

$onWindows = $true
if ($PSVersionTable.PSEdition -eq 'Core' -and (Get-Variable IsWindows -ErrorAction SilentlyContinue) -and -not $IsWindows) { $onWindows = $false }
if (-not $onWindows) { Say-Err 'Cette version est conçue pour Windows. Sous Linux, utilisez buildwith-doctor.sh.'; exit 2 }

if (-not (Test-Admin) -and -not $Elevated) {
    Say-Info 'Droits administrateur requis pour une auscultation complète — demande d''élévation (UAC)…'
    if (Invoke-Elevate) { exit 0 }
    Say-Warn 'Élévation refusée : diagnostic partiel sans droits administrateur.'
    if ($script:Action -eq 'heal') { Say-Err 'Le traitement est impossible sans administrateur.'; exit 2 }
    if (-not $script:Action) { $script:Action = 'scan' }
}

Show-Splash
if (-not $script:Action) {
    $go = Show-Menu
    if ($go -ne $true) { Wait-End; exit 0 }
}
if (-not (Test-Admin)) { Say-Warn 'Exécution sans administrateur : diagnostic partiel.' }

try { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null } catch { $script:LogDir = [IO.Path]::GetTempPath() }
$script:ActionLog = Join-Path $script:LogDir "actions-$($script:Stamp).log"
$script:ReportTxt = Join-Path $script:LogDir "rapport-$($script:Stamp).txt"
$script:ReportJson = Join-Path $script:LogDir "rapport-$($script:Stamp).json"
Write-Log "=== $($script:App) v$($script:Version) démarré (admin: $(Test-Admin)) ==="

$sel = Get-SelectedModules
if ($sel.Count -eq 0) { Say-Err 'Aucun module sélectionné (voir -List).'; Wait-End; exit 2 }
Write-Host ''
$flags = ''; if ($script:DeepMode) { $flags += ' — mode approfondi' }; if ($script:QuickMode) { $flags += ' — mode rapide' }
Write-Host ("  Consultation du {0} — hôte {1} — {2} module(s){3}" -f (Get-Date -Format 'dd/MM/yyyy HH:mm'), $env:COMPUTERNAME, $sel.Count, $flags) -ForegroundColor DarkGray
Write-Host ('─' * $script:Cols) -ForegroundColor DarkGray

Invoke-Scan
Show-Summary
if ($script:Action -eq 'heal') {
    Invoke-Heal
    if (-not $script:Dry) { Invoke-Recheck }
}
Invoke-RebootCheck
Write-Reports
Write-Host ''
Write-Host '  Rapport : ' -ForegroundColor DarkGray -NoNewline; Write-Host $script:ReportTxt
Write-Host '  JSON    : ' -ForegroundColor DarkGray -NoNewline; Write-Host $script:ReportJson
if (Test-Path $script:BackupDir) { Write-Host '  Sauvegardes : ' -ForegroundColor DarkGray -NoNewline; Write-Host $script:BackupDir }
Show-Signature
Write-Log "=== Fin — score $($script:Score), crit=$($script:NC), warn=$($script:NW), info=$($script:NI) ==="
Wait-End
if ($script:NC -gt 0) { exit 2 }
if ($script:NW -gt 0) { exit 1 }
exit 0
