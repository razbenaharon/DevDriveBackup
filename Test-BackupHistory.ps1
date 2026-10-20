#Requires -Version 7.2
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.History.psm1') -Force
function Assert($ok,$message){if(-not $ok){throw $message};Write-Output ('PASS '+$message)}
function Refuses($action,$message){$refused=$false;try{& $action}catch{$refused=$true};Assert $refused $message}
$old=[pscustomobject]@{id=('a'*64);time='2026-10-16T10:00:00Z';hostname='test';paths=@('X:\source')}
$new=[pscustomobject]@{id=('b'*64);time='2026-10-17T10:00:00Z';hostname='test';paths=@('X:\source')}
$other=[pscustomobject]@{id=('c'*64);time='2026-10-15T10:00:00Z';hostname='other';paths=@('X:\source')}
$snapshots=@($old,$new,$other)
Assert (@(Get-HistoryDeletionPlan $snapshots @($old.id)).Count -eq 1) 'older selected version can be deleted'
Refuses {Get-HistoryDeletionPlan $snapshots @($new.id)} 'newest version is protected'
Refuses {Get-HistoryDeletionPlan $snapshots @($other.id)} 'newest version of another source set is also protected'
Refuses {Get-HistoryDeletionPlan $snapshots @()} 'empty selection is rejected'
Refuses {Get-HistoryDeletionPlan $snapshots @('latest')} 'aliases are rejected for deletion'
Refuses {Get-HistoryDeletionPlan $snapshots @('d'*64)} 'stale snapshot selection is rejected'
Refuses {Assert-SnapshotPath '/E/../source'} 'parent traversal is rejected'
Refuses {Assert-SnapshotPath "--flag"} 'relative and option-like paths are rejected'
Assert ((ConvertTo-ResticLiteralPattern '/E/a [sample].txt') -ceq '/E/a[ ][[]sample].txt') 'bracket filename is escaped for literal restore'
Assert ((ConvertTo-ResticLiteralPattern '/E/a*?.txt') -ceq '/E/a[*][?].txt') 'wildcard characters are escaped for literal restore'
$previousCulture=[Globalization.CultureInfo]::CurrentCulture
try{
 [Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('he-IL')
 $typed=@($snapshots|ConvertTo-Json -Depth 5|ConvertFrom-Json)
 Assert (@(Get-HistoryDeletionPlan $typed @($old.id)).Count -eq 1) 'JSON dates work with non-English Windows culture'
 Refuses {Get-HistoryDeletionPlan $typed @($new.id)} 'newest protection survives JSON date conversion'
}finally{[Globalization.CultureInfo]::CurrentCulture=$previousCulture}
