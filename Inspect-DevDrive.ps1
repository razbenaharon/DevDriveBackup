param([Parameter(Mandatory)][string]$Root,[string]$OutputDirectory=(Join-Path $env:LOCALAPPDATA 'DevDriveMirror\audit'))
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
Add-Type -TypeDefinition @'
using System; using System.IO; using System.Collections.Generic; using System.Diagnostics; using System.Text;
public class FolderStat {
 public string Path; public long Bytes,Files,Directories,CacheBytes,CacheFiles,GitBytes,DataBytes,SecretBytes; public int Errors,Links; public DateTime Latest;
}
public class DevDriveInspector {
 static readonly HashSet<string> Caches=new HashSet<string>(new[]{"node_modules",".venv","venv","__pycache__",".next",".turbo",".pnpm-store",".pytest_cache",".mypy_cache",".ruff_cache",".cache",".tox",".nox"},StringComparer.OrdinalIgnoreCase);
 static readonly HashSet<string> DataExt=new HashSet<string>(new[]{".db",".sqlite",".sqlite3",".csv",".parquet",".xlsx",".docx",".pptx",".pdf",".mp4",".wav",".safetensors",".pt",".onnx"},StringComparer.OrdinalIgnoreCase);
 static string Csv(string s){return "\""+s.Replace("\"","\"\"")+"\"";}
 public static void Scan(string root,string output) {
  root=Path.GetFullPath(root).TrimEnd('\\')+"\\";
  var stats=new Dictionary<string,FolderStat>(StringComparer.OrdinalIgnoreCase);
  var pending=new Stack<string>();pending.Push(root);
  var watch=Stopwatch.StartNew(); var last=TimeSpan.Zero;
  long bytes=0,files=0,dirs=0; int errors=0,links=0;
  using(var detail=new StreamWriter(Path.Combine(output,"directories.csv"),false,new UTF8Encoding(true)))
  using(var err=new StreamWriter(Path.Combine(output,"scan-errors.csv"),false,new UTF8Encoding(true)))
  using(var big=new StreamWriter(Path.Combine(output,"large-files.csv"),false,new UTF8Encoding(true))) {
   detail.WriteLine("Path,DirectBytes,DirectFiles,ChildDirectories,Errors,Links");err.WriteLine("Path,Error");big.WriteLine("Path,Bytes");
   while(pending.Count>0) {
    string dir=pending.Pop();string relative=dir.Length>=root.Length?dir.Substring(root.Length):"";
    string[] parts=relative.Split(new[]{'\\'},StringSplitOptions.RemoveEmptyEntries);
    var buckets=new List<FolderStat>();
    for(int level=0;level<=Math.Min(parts.Length,3);level++) {
     string key=level==0?"(all)":string.Join("\\",parts,0,level);
     FolderStat item;if(!stats.TryGetValue(key,out item)){item=new FolderStat{Path=key};stats.Add(key,item);}buckets.Add(item);
    }
    bool cache=false,git=false;foreach(string p in parts){if(Caches.Contains(p))cache=true;if(p.Equals(".git",StringComparison.OrdinalIgnoreCase))git=true;}
    if(parts.Length>0&&(parts[0].Equals(".pnpm-store",StringComparison.OrdinalIgnoreCase)||parts[0].Equals("Packages",StringComparison.OrdinalIgnoreCase)))cache=true;
    long directBytes=0,directFiles=0,children=0;int localErrors=0,localLinks=0;
    try {
     foreach(var e in new DirectoryInfo(dir).EnumerateFileSystemInfos()) {
      try {
       if((e.Attributes&FileAttributes.ReparsePoint)!=0){links++;localLinks++;foreach(var b in buckets)b.Links++;continue;}
       if((e.Attributes&FileAttributes.Directory)!=0) {
        dirs++;children++;foreach(var b in buckets)b.Directories++;
        if(dir.Equals(root,StringComparison.OrdinalIgnoreCase)&&(e.Name.Equals("$RECYCLE.BIN",StringComparison.OrdinalIgnoreCase)||e.Name.Equals("System Volume Information",StringComparison.OrdinalIgnoreCase))) {err.WriteLine(Csv(e.FullName)+",\"System-managed; not traversed\"");continue;}
        pending.Push(e.FullName);continue;
       }
       var f=(FileInfo)e;long n=f.Length;bytes+=n;files++;directBytes+=n;directFiles++;
       bool secret=f.Name.Equals(".env",StringComparison.OrdinalIgnoreCase)||f.Name.StartsWith(".env.",StringComparison.OrdinalIgnoreCase)||f.Extension.Equals(".pem",StringComparison.OrdinalIgnoreCase)||f.Extension.Equals(".key",StringComparison.OrdinalIgnoreCase);
       foreach(var b in buckets){b.Bytes+=n;b.Files++;if(cache){b.CacheBytes+=n;b.CacheFiles++;}if(git)b.GitBytes+=n;if(DataExt.Contains(f.Extension))b.DataBytes+=n;if(secret)b.SecretBytes+=n;if(f.LastWriteTimeUtc>b.Latest)b.Latest=f.LastWriteTimeUtc;}
       if(n>=64L*1024*1024)big.WriteLine(Csv(f.FullName)+","+n);
      } catch(Exception ex){errors++;localErrors++;foreach(var b in buckets)b.Errors++;err.WriteLine(Csv(e.FullName)+","+Csv(ex.GetType().Name+": "+ex.Message));}
     }
    }catch(Exception ex){errors++;localErrors++;foreach(var b in buckets)b.Errors++;err.WriteLine(Csv(dir)+","+Csv(ex.GetType().Name+": "+ex.Message));}
    detail.WriteLine(Csv(dir)+","+directBytes+","+directFiles+","+children+","+localErrors+","+localLinks);
    if(watch.Elapsed-last>TimeSpan.FromSeconds(3)) {
     last=watch.Elapsed;
     File.WriteAllText(Path.Combine(output,"scan-progress.txt"),"Seconds="+watch.Elapsed.TotalSeconds+"\nFiles="+files+"\nBytes="+bytes+"\nDirectories="+dirs+"\nErrors="+errors+"\nCurrent="+dir);
    }
   }
  }
  using(var csv=new StreamWriter(Path.Combine(output,"folder-summary.csv"),false,new UTF8Encoding(true))) {
   csv.WriteLine("Path,Bytes,Files,Directories,CacheBytes,CacheFiles,GitBytes,DataBytes,SecretBytes,Errors,Links,LatestUtc");
   foreach(var b in stats.Values)csv.WriteLine(Csv(b.Path)+","+b.Bytes+","+b.Files+","+b.Directories+","+b.CacheBytes+","+b.CacheFiles+","+b.GitBytes+","+b.DataBytes+","+b.SecretBytes+","+b.Errors+","+b.Links+","+b.Latest.ToString("o"));
  }
  File.WriteAllText(Path.Combine(output,"scan-completed.txt"),"Seconds="+watch.Elapsed.TotalSeconds+"\nFiles="+files+"\nBytes="+bytes+"\nDirectories="+dirs+"\nErrors="+errors+"\nLinks="+links);
 }
}
'@
[DevDriveInspector]::Scan($Root,$OutputDirectory)
