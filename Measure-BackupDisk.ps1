param([Parameter(Mandatory)][string]$Drive,[int]$SizeMiB=512,[string]$OutputDirectory=(Join-Path $env:LOCALAPPDATA 'DevDriveMirror\audit'),[switch]$LinkOnly)
$ErrorActionPreference='Stop'
if($Drive -notmatch '^[A-Za-z]$'){throw 'A drive letter is required'}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
Add-Type -TypeDefinition @'
using System; using System.IO; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles; using System.ComponentModel; using System.Diagnostics;
public class BackupDiskProbe {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string n,uint a,uint s,IntPtr sa,uint d,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool WriteFile(SafeFileHandle h,IntPtr b,uint n,out uint done,IntPtr o);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadFile(SafeFileHandle h,IntPtr b,uint n,out uint done,IntPtr o);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool FlushFileBuffers(SafeFileHandle h);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr VirtualAlloc(IntPtr a,UIntPtr n,uint t,uint p);
 [DllImport("kernel32.dll")] static extern bool VirtualFree(IntPtr a,UIntPtr n,uint t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool DeviceIoControl(SafeFileHandle h,uint c,byte[] input,int il,byte[] output,int ol,out int bytes,IntPtr overlapped);
 [DllImport("cfgmgr32.dll",CharSet=CharSet.Unicode)] static extern int CM_Get_Device_Interface_List_SizeW(out uint size,ref Guid guid,string id,uint flags);
 [DllImport("cfgmgr32.dll",CharSet=CharSet.Unicode)] static extern int CM_Get_Device_Interface_ListW(ref Guid guid,string id,char[] buffer,uint length,uint flags);
 public static string UsbSpeed(string hubId,int port) {
  Guid g=new Guid("f18a0e88-c30c-11d0-8815-00a0c906bed8");uint n;
  int r=CM_Get_Device_Interface_List_SizeW(out n,ref g,hubId,0);if(r!=0||n<2)throw new Exception("Hub interface size error "+r);
  char[] paths=new char[n];r=CM_Get_Device_Interface_ListW(ref g,hubId,paths,n,0);if(r!=0)throw new Exception("Hub interface error "+r);
  string path=new string(paths).Split('\0')[0];
  using(var h=CreateFile(path,0xC0000000,3,IntPtr.Zero,3,0,IntPtr.Zero)) {
   if(h.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());
   byte[] b=new byte[4096];BitConverter.GetBytes(port).CopyTo(b,0);int done;
   if(!DeviceIoControl(h,0x220448,b,b.Length,b,b.Length,out done,IntPtr.Zero))throw new Win32Exception(Marshal.GetLastWin32Error());
   int speed=b[23];byte[] v2=new byte[16];BitConverter.GetBytes(port).CopyTo(v2,0);BitConverter.GetBytes(16).CopyTo(v2,4);BitConverter.GetBytes(4).CopyTo(v2,8);
   bool hasV2=DeviceIoControl(h,0x22045C,v2,16,v2,16,out done,IntPtr.Zero);int flags=hasV2?BitConverter.ToInt32(v2,12):0;
   string label=(flags&4)!=0?"SuperSpeedPlus (10 Gbit/s+)":(flags&1)!=0?"SuperSpeed (5 Gbit/s+)":new[]{"Low (1.5 Mbit/s)","Full (12 Mbit/s)","High (480 Mbit/s)","SuperSpeed (5 Gbit/s+)"}[Math.Min(speed,3)];
   return "{\"Port\":"+port+",\"LegacySpeedCode\":"+speed+",\"ExV2Available\":"+hasV2.ToString().ToLowerInvariant()+",\"ExV2Flags\":"+flags+",\"SuperSpeedActive\":"+((flags&5)!=0||speed==3).ToString().ToLowerInvariant()+",\"Speed\":\""+label+"\",\"VendorId\":"+BitConverter.ToUInt16(b,12)+",\"ProductId\":"+BitConverter.ToUInt16(b,14)+"}";
  }
 }
 public static string Measure(string path,int sizeMiB) {
  const int block=4*1024*1024;IntPtr buffer=VirtualAlloc(IntPtr.Zero,(UIntPtr)block,0x3000,4);if(buffer==IntPtr.Zero)throw new Win32Exception();
  long bytes=0;double writeSeconds=0,readSeconds=0;bool created=false;
  try {
   byte[] seed=new byte[block];new Random(20261017).NextBytes(seed);Marshal.Copy(seed,0,buffer,block);
   using(var h=CreateFile(path,0x40000000,0,IntPtr.Zero,1,0xA8000000,IntPtr.Zero)) {
    if(h.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());created=true;var w=Stopwatch.StartNew();
    while(bytes<(long)sizeMiB*1024*1024&&w.Elapsed.TotalSeconds<25){uint done;if(!WriteFile(h,buffer,block,out done,IntPtr.Zero)||done!=block)throw new Win32Exception(Marshal.GetLastWin32Error());bytes+=done;}
    if(!FlushFileBuffers(h))throw new Win32Exception(Marshal.GetLastWin32Error());writeSeconds=w.Elapsed.TotalSeconds;
   }
   using(var h=CreateFile(path,0x80000000,1,IntPtr.Zero,3,0x28000000,IntPtr.Zero)) {
    if(h.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());var w=Stopwatch.StartNew();long read=0;
    while(read<bytes){uint done;if(!ReadFile(h,buffer,block,out done,IntPtr.Zero)||done!=block)throw new Win32Exception(Marshal.GetLastWin32Error());read+=done;}readSeconds=w.Elapsed.TotalSeconds;
   }
   return "{\"Bytes\":"+bytes+",\"BlockBytes\":"+block+",\"WriteSeconds\":"+writeSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture)+",\"ReadSeconds\":"+readSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture)+",\"WriteMBps\":"+(bytes/writeSeconds/1e6).ToString(System.Globalization.CultureInfo.InvariantCulture)+",\"ReadMBps\":"+(bytes/readSeconds/1e6).ToString(System.Globalization.CultureInfo.InvariantCulture)+",\"Unbuffered\":true,\"WriteThrough\":true}";
  }finally{VirtualFree(buffer,UIntPtr.Zero,0x8000);if(created)File.Delete(path);}
 }
}
'@
$disk=Get-Partition -DriveLetter $Drive | Get-Disk
$hub=$null;$location=$null
# A Thunderbolt/USB4 NVMe enclosure is not a USB device; report that and still run the benchmark.
try {
 if($disk.BusType -ne 'USB'){throw "Not a USB device (bus type $($disk.BusType)); USB link speed does not apply"}
 $id=(Get-CimInstance Win32_DiskDrive | Where-Object {$_.Index -eq $disk.Number}).PNPDeviceID
 $usb=(Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_Parent).Data
 $hub=(Get-PnpDeviceProperty -InstanceId $usb -KeyName DEVPKEY_Device_Parent).Data
 $location=[string](Get-PnpDeviceProperty -InstanceId $usb -KeyName DEVPKEY_Device_LocationInfo).Data
 $port=[int]([regex]::Match($location,'Port_#(\d+)').Groups[1].Value)
 $speed=[BackupDiskProbe]::UsbSpeed($hub,$port)|ConvertFrom-Json
} catch {$speed=[pscustomobject]@{Error=$_.Exception.Message;BusType=[string]$disk.BusType;Hub=$hub;Location=$location}}
$speed|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutputDirectory 'usb-speed.json')
if($LinkOnly){$speed|ConvertTo-Json;return}
$path=$Drive+':\DevDriveBackup-benchmark-'+[guid]::NewGuid().ToString('N')+'.tmp'
$test=[BackupDiskProbe]::Measure($path,$SizeMiB)|ConvertFrom-Json
[pscustomobject]@{Utc=[DateTime]::UtcNow.ToString('o');Drive=$Drive;Disk=$disk.FriendlyName;Usb=$speed;Benchmark=$test}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $OutputDirectory 'disk-benchmark.json')
