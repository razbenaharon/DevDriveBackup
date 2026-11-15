#Requires -Version 7.2
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.History.psm1') -Force
function Assert($ok,$message){if(-not $ok){throw $message};Write-Output ('PASS '+$message)}
# A refusal counts only when it is the expected one: any other error (a typo, a missing function) fails the test.
function Refuses($action,[string]$like,$message){$refused=$false;try{& $action}catch{if($_.Exception.Message -notlike $like){throw "$message (unexpected error: $($_.Exception.Message))"};$refused=$true};Assert $refused $message}
$old=[pscustomobject]@{id=('a'*64);time='2026-10-16T10:00:00Z';hostname='test';paths=@('X:\source')}
$new=[pscustomobject]@{id=('b'*64);time='2026-10-17T10:00:00Z';hostname='test';paths=@('X:\source')}
$other=[pscustomobject]@{id=('c'*64);time='2026-10-15T10:00:00Z';hostname='other';paths=@('X:\source')}
$snapshots=@($old,$new,$other)
Assert (@(Get-HistoryDeletionPlan $snapshots @($old.id)).Count -eq 1) 'older selected version can be deleted'
Refuses {Get-HistoryDeletionPlan $snapshots @($new.id)} '*protected*' 'newest version is protected'
Refuses {Get-HistoryDeletionPlan $snapshots @($other.id)} '*protected*' 'newest version of another source set is also protected'
Refuses {Get-HistoryDeletionPlan $snapshots @()} '*Select at least*' 'empty selection is rejected'
Refuses {Get-HistoryDeletionPlan $snapshots @('latest')} '*exact snapshot ID*' 'aliases are rejected for deletion'
Refuses {Get-HistoryDeletionPlan $snapshots @('d'*64)} '*no longer exists*' 'stale snapshot selection is rejected'
Refuses {Assert-SnapshotPath '/E/../source'} '*Invalid absolute snapshot path*' 'parent traversal is rejected'
Refuses {Assert-SnapshotPath "--flag"} '*Invalid absolute snapshot path*' 'relative and option-like paths are rejected'
Assert ((ConvertTo-ResticLiteralPattern '/E/a [sample].txt') -ceq '/E/a[ ][[]sample].txt') 'bracket filename is escaped for literal restore'
Assert ((ConvertTo-ResticLiteralPattern '/E/a*?.txt') -ceq '/E/a[*][?].txt') 'wildcard characters are escaped for literal restore'
$previousCulture=[Globalization.CultureInfo]::CurrentCulture
try{
 [Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('he-IL')
 $typed=@($snapshots|ConvertTo-Json -Depth 5|ConvertFrom-Json)
 Assert (@(Get-HistoryDeletionPlan $typed @($old.id)).Count -eq 1) 'JSON dates work with non-English Windows culture'
 Refuses {Get-HistoryDeletionPlan $typed @($new.id)} '*protected*' 'newest protection survives JSON date conversion'
}finally{[Globalization.CultureInfo]::CurrentCulture=$previousCulture}
# Deletion by hand protects the newest complete version this tool made of each computer and set of
# folders, told apart exactly as the clean-up tells them apart (Get-SnapshotGroupKey). Grouping all
# versions without regard to case let a newer version of another program, or the same folder written
# with other capital letters, take that protection away.
$mine=[pscustomobject]@{id=('e'*64);time='2026-10-16T10:00:00Z';hostname='test';paths=@('X:\work');tags=@('devdrive')}
$minePartial=[pscustomobject]@{id=('f'*64);time='2026-10-17T10:00:00Z';hostname='test';paths=@('X:\work');tags=@('devdrive-partial')}
$foreign=[pscustomobject]@{id=('1'*64);time='2026-10-18T10:00:00Z';hostname='test';paths=@('X:\work')}
Refuses {Get-HistoryDeletionPlan @($mine,$minePartial,$foreign) @($mine.id)} '*protected*' 'the newest complete version this tool made stays protected when another program saved a newer version of the same folders'
$mineOlder=[pscustomobject]@{id=('2'*64);time='2026-10-15T10:00:00Z';hostname='test';paths=@('X:\work');tags=@('devdrive')}
Assert (@(Get-HistoryDeletionPlan @($mineOlder,$mine,$minePartial,$foreign) @($mineOlder.id)).Count -eq 1) 'an older complete version of the same folders can still be deleted'
$upper=[pscustomobject]@{id=('3'*64);time='2026-10-16T10:00:00Z';hostname='test';paths=@('X:\Work');tags=@('devdrive')}
$lower=[pscustomobject]@{id=('4'*64);time='2026-10-17T10:00:00Z';hostname='test';paths=@('X:\work');tags=@('devdrive')}
Refuses {Get-HistoryDeletionPlan @($upper,$lower) @($upper.id)} '*protected*' 'the newest version of a set written with other capital letters is protected, as the clean-up keeps it'
