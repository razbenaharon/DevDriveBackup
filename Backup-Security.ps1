#Requires -Version 7.2
param([string]$ConfigPath=(Join-Path $PSScriptRoot 'backup.local.json'),[string]$RenderPreview)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Backup.Status.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Backup.Security.psm1') -Force
[Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('en-US')
[Globalization.CultureInfo]::CurrentUICulture=[Globalization.CultureInfo]::GetCultureInfo('en-US')
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$config=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
$form=[Windows.Forms.Form]::new();$form.Text='Backup Center — Password and recovery key';$form.ClientSize=[Drawing.Size]::new(820,535);$form.Font=[Drawing.Font]::new('Segoe UI',10);$form.StartPosition='CenterScreen';$form.RightToLeft='No';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
$iconFile=Join-Path $PSScriptRoot 'BackupCenter.ico';if(Test-Path -LiteralPath $iconFile){$form.Icon=[Drawing.Icon]::new($iconFile)}
function C($type,$x,$y,$w,$h,$text=''){$c=New-Object ('Windows.Forms.'+$type);$c.SetBounds($x,$y,$w,$h);$c.Text=$text;$form.Controls.Add($c);$c}
$title=C Label 20 15 780 32 'Password and Recovery';$title.Font=[Drawing.Font]::new('Segoe UI',17,[Drawing.FontStyle]::Bold)
[void](C Label 20 58 780 48 'Save a portable recovery key or change the password for this repository. Existing backup versions and file data are preserved.')
[void](C Label 20 116 780 25 'Save recovery key as (choose a new file outside the source and backup repository):')
$path=C TextBox 20 146 650 29
$parent=[IO.Path]::GetDirectoryName($config.RecoveryKeyPath);$path.Text=Join-Path $parent ('DevDrive-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-recovery-key.txt')
$browse=C Button 682 144 118 33 'Browse...'
[void](C Label 20 191 180 25 'New password')
$password=C TextBox 205 187 405 29;$password.UseSystemPasswordChar=$true;$password.MaxLength=1024
$generate=C Button 625 186 175 32 'Generate password'
[void](C Label 20 233 180 25 'Confirm password')
$confirm=C TextBox 205 229 595 29;$confirm.UseSystemPasswordChar=$true;$confirm.MaxLength=1024
[void](C Label 20 273 780 48 'Use at least 12 characters. The current password is read from this Windows account. A new access key is verified and saved before the old key is retired.')
$export=C Button 20 333 230 38 'Save recovery key only'
$change=C Button 265 333 280 38 'Change password and save key'
$resume=C Button 560 333 240 38 'Resume interrupted change'
$status=C Label 20 391 780 72 'Ready. No repository changes occur until you choose an action. Keep the recovery file in a separate safe location; anyone with it can decrypt the backup.'
$logs=C LinkLabel 20 480 780 32 ''
$script:worker=$null;$script:run=$null
$controls=@($path,$browse,$password,$confirm,$generate,$export,$change,$resume)
function Show-Error($message){[void][Windows.Forms.MessageBox]::Show($form,[string]$message,'Password and Recovery','OK','Error')}
function Start-SecurityAction([string]$action){
 if($script:worker -and -not $script:worker.HasExited){throw 'A key-management operation is already running'}
 if($action -eq 'ChangePassword'){Assert-NewBackupPassword $password.Text;if($password.Text -cne $confirm.Text){throw 'The new passwords do not match'}}
 $script:run=Join-Path $env:LOCALAPPDATA ('DevDriveMirror\runs\security-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $script:run|Out-Null
 $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
 foreach($arg in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Backup-Worker.ps1'),'-ConfigPath',$ConfigPath,'-Action',$action,'-RunDirectory',$script:run)){[void]$psi.ArgumentList.Add($arg)}
 $request=@{RecoveryKeyPath=$path.Text}
 if($action -eq 'ChangePassword'){$protectedPath=Join-Path $script:run 'new-password.dpapi';New-PrivateTextFile $protectedPath ($password.Text|ConvertTo-SecureString -AsPlainText -Force|ConvertFrom-SecureString);$request.NewPasswordDpapiPath=$protectedPath}
 $requestPath=Join-Path $script:run 'request.json';[IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json));[void]$psi.ArgumentList.Add('-RequestPath');[void]$psi.ArgumentList.Add($requestPath)
 $script:worker=[Diagnostics.Process]::Start($psi);$password.Clear();$confirm.Clear();foreach($control in $controls){$control.Enabled=$false};$status.Text='Starting '+$action+'...';$logs.Text=$script:run;$timer.Start()
}
$browse.Add_Click({$picker=[Windows.Forms.SaveFileDialog]::new();$picker.Title='Save portable recovery key';$picker.Filter='Recovery key (*.txt)|*.txt';$picker.FileName=[IO.Path]::GetFileName($path.Text);$picker.InitialDirectory=[IO.Path]::GetDirectoryName($path.Text);$picker.OverwritePrompt=$true;try{if($picker.ShowDialog($form) -eq 'OK'){$path.Text=$picker.FileName}}finally{$picker.Dispose()}})
$generate.Add_Click({$value=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32));$password.Text=$value;$confirm.Text=$value;$value=$null})
$export.Add_Click({try{Start-SecurityAction 'ExportKey'}catch{Show-Error $_.Exception.Message}})
$change.Add_Click({try{Start-SecurityAction 'ChangePassword'}catch{Show-Error $_.Exception.Message}})
$resume.Add_Click({try{Start-SecurityAction 'ResumePasswordChange'}catch{Show-Error $_.Exception.Message}})
$logs.Add_LinkClicked({if($script:run){Start-Process explorer.exe -ArgumentList ('"'+$script:run+'"')}})
$timer=[Windows.Forms.Timer]::new();$timer.Interval=700
$timer.Add_Tick({try{
 $file=Join-Path $script:run 'result.json';if(-not(Test-Path -LiteralPath $file)){$file=Join-Path $script:run 'status.json'}
 if(Test-Path -LiteralPath $file){$s=Read-BackupStatus $file;$status.Text='Stage: '+$s.State;if($s.State -eq 'Failed'){$status.Text='Failed: '+$s.Error}}
 if(-not $script:worker.HasExited){return};$timer.Stop();foreach($control in $controls){$control.Enabled=$true}
 $result=Join-Path $script:run 'result.json';if(-not(Test-Path -LiteralPath $result)){throw 'The worker stopped unexpectedly. If a password change began, use Resume interrupted change.'}
 $s=Read-BackupStatus $result
 if($s.State -eq 'Completed'){$path.Text=$s.RecoveryKeyPath;$status.Text='Completed. Recovery key saved to: '+$s.RecoveryKeyPath+'. Keep a copy outside this computer. Existing backup versions are preserved.'}
 }catch{$timer.Stop();foreach($control in $controls){$control.Enabled=$true};Show-Error $_.Exception.Message}})
$form.Add_FormClosing({param($sender,$event) if($script:worker -and -not $script:worker.HasExited){$event.Cancel=$true;Show-Error 'Wait for the key-management operation to finish before closing.'}})
if($RenderPreview){$form.Add_Shown({$bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height);$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($RenderPreview);$bitmap.Dispose();$form.Close()})}
[void]$form.ShowDialog()
