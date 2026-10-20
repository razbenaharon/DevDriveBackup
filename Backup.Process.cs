using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.ComponentModel;
public sealed class BackupMemoryJob : IDisposable {
 [StructLayout(LayoutKind.Sequential)] struct Basic {public long PerProcessUserTimeLimit,PerJobUserTimeLimit;public uint LimitFlags;public UIntPtr MinimumWorkingSetSize,MaximumWorkingSetSize;public uint ActiveProcessLimit;public UIntPtr Affinity;public uint PriorityClass,SchedulingClass;}
 [StructLayout(LayoutKind.Sequential)] struct Io {public ulong ReadOperationCount,WriteOperationCount,OtherOperationCount,ReadTransferCount,WriteTransferCount,OtherTransferCount;}
 [StructLayout(LayoutKind.Sequential)] struct Extended {public Basic BasicLimitInformation;public Io IoInfo;public UIntPtr ProcessMemoryLimit,JobMemoryLimit,PeakProcessMemoryUsed,PeakJobMemoryUsed;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr a,string name);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int info,IntPtr ptr,uint length);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 IntPtr handle;
 public BackupMemoryJob(long bytes) {
  handle=CreateJobObject(IntPtr.Zero,null);if(handle==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());
  var data=new Extended();data.BasicLimitInformation.LimitFlags=0x100|0x2000;data.ProcessMemoryLimit=(UIntPtr)bytes;
  int size=Marshal.SizeOf(data);IntPtr ptr=Marshal.AllocHGlobal(size);
  try{Marshal.StructureToPtr(data,ptr,false);if(!SetInformationJobObject(handle,9,ptr,(uint)size))throw new Win32Exception(Marshal.GetLastWin32Error());}catch{Dispose();throw;}finally{Marshal.FreeHGlobal(ptr);}
 }
 public void Add(Process process){if(!AssignProcessToJobObject(handle,process.Handle))throw new Win32Exception(Marshal.GetLastWin32Error());}
 public void Dispose(){if(handle!=IntPtr.Zero){CloseHandle(handle);handle=IntPtr.Zero;}}
}
