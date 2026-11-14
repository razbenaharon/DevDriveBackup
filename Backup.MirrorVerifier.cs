// Content check of a plain copy (Invoke-FastMirror.ps1 -Verify and -VerifyOnly). Both sides are walked
// with the rules the copy uses (per-folder mode, skipped names and paths, links never followed), so a
// selected source file that is missing from the copy is a difference, not only a file whose content differs.
// The same rules serve the repair of single files (-Repair) and the look for names robocopy treats
// differently from what the lists say (Survey).
using System; using System.IO; using System.Linq; using System.Threading; using System.Threading.Tasks; using System.Security.Cryptography; using System.Collections.Concurrent; using System.Collections.Generic; using System.Text.RegularExpressions; using System.Runtime.InteropServices;
public static class MirrorVerifier {
 static string Hash(string p){using(var s=new FileStream(p,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete,1<<20))using(var h=SHA256.Create())return Convert.ToHexString(h.ComputeHash(s));}
 static bool Same(string a,string b){return string.Equals(a,b,StringComparison.OrdinalIgnoreCase);}
 static bool Under(string path,string parent){return path.StartsWith(parent+"\\",StringComparison.OrdinalIgnoreCase);}
 // Every path is used in its \\?\ form: Windows otherwise drops a dot or space at the end of a name
 // (and then looks for another file), and stops at 260 characters.
 static string Long(string p){p=Path.GetFullPath(p).TrimEnd('\\');return p.StartsWith("\\\\?\\")?p:p.StartsWith("\\\\")?"\\\\?\\UNC\\"+p.Substring(2):"\\\\?\\"+p;}
 static string Plain(string text){return text.Replace("\\\\?\\UNC\\","\\\\").Replace("\\\\?\\","");}
 // Mirror mode of a relative path: the longest entry that equals or contains it, else the default.
 static bool IsOn(string rel,string[] paths,bool[] on,bool defaultOn){
  int best=-1;
  for(int i=0;i<paths.Length;i++)if((Same(rel,paths[i])||Under(rel,paths[i]))&&(best<0||paths[i].Length>paths[best].Length))best=i;
  return best<0?defaultOn:on[best];
 }
 // robocopy wildcards in /XD and /XF names: * and ?, not case-sensitive.
 static Regex[] Globs(string[] names){return names.Select(n=>new Regex("^"+Regex.Escape(n).Replace("\\*",".*").Replace("\\?",".")+"$",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant)).ToArray();}
 sealed class Rules {public string[] Paths;public bool[] On;public bool DefaultOn;public Regex[] DirNames,FileNames;public string[] SkipPaths,Roots;}
 static Rules Make(string[] paths,bool[] on,bool defaultOn,string[] skipDirNames,string[] skipFileNames,string[] skipPaths,string[] roots){
  return new Rules{Paths=paths,On=on,DefaultOn=defaultOn,DirNames=Globs(skipDirNames),FileNames=Globs(skipFileNames),SkipPaths=skipPaths.Select(s=>s.Trim('\\')).Where(s=>s.Length>0).ToArray(),Roots=roots.Select(s=>s.Trim('\\')).Where(s=>s.Length>0).ToArray()};
 }
 // robocopy skips names and paths only below the folder it copies, never that folder itself. So a
 // folder or file that was copied on its own (one of Roots) is checked whatever is skipped above it
 // or by its own name, and a skipped folder is still entered, without checking its files, where
 // such a root lies inside it.
 // What the copy does with a folder. 0: left out. 1: read. 2: skipped, and entered only for a root inside it.
 static int Folder(string rel,string name,bool skipped,Rules r){
  if(r.Roots.Any(x=>Same(x,rel)))return 1;
  if(skipped||r.SkipPaths.Any(s=>Same(rel,s))||r.DirNames.Any(g=>g.IsMatch(name)))return r.Roots.Any(x=>Under(x,rel))?2:0;
  // Unselected folders are entered only when a selected entry lies inside them.
  return IsOn(rel,r.Paths,r.On,r.DefaultOn)||Enumerable.Range(0,r.Paths.Length).Any(i=>r.On[i]&&Under(r.Paths[i],rel))?1:0;
 }
 // Whether the copy takes a file.
 static bool Taken(string rel,string name,bool skipped,Rules r){
  return (r.Roots.Any(x=>Same(x,rel))||(!skipped&&!r.SkipPaths.Any(s=>Same(rel,s))&&!r.FileNames.Any(g=>g.IsMatch(name))))&&IsOn(rel,r.Paths,r.On,r.DefaultOn);
 }
 // The same for one file by its path alone, folder by folder, without reading the disk.
 static bool Selected(string rel,Rules r){
  var parts=rel.Split('\\');string d="";bool skipped=false;
  for(int i=0;i<parts.Length-1;i++){d=d.Length==0?parts[i]:d+"\\"+parts[i];int k=Folder(d,parts[i],skipped,r);if(k==0)return false;skipped=k==2;}
  return Taken(rel,parts[parts.Length-1],skipped,r);
 }
 // Relative paths of the selected files below root. A folder that cannot be read is reported, not skipped silently.
 static IEnumerable<string> Files(string root,Rules r,ConcurrentBag<string> bad){
  var stack=new Stack<KeyValuePair<string,bool>>();stack.Push(new KeyValuePair<string,bool>("",false));
  while(stack.Count>0){var top=stack.Pop();string d=top.Key;bool skipped=top.Value;FileSystemInfo[] items;
   try{items=new DirectoryInfo(d.Length==0?root+"\\":root+"\\"+d+"\\").GetFileSystemInfos();}catch(Exception ex){bad.Add("ERROR\t"+d+"\t"+Plain(ex.Message));continue;}
   foreach(var e in items){
    if((e.Attributes&FileAttributes.ReparsePoint)!=0)continue;
    string rel=d.Length==0?e.Name:d+"\\"+e.Name;
    if((e.Attributes&FileAttributes.Directory)!=0){int k=Folder(rel,e.Name,skipped,r);if(k>0)stack.Push(new KeyValuePair<string,bool>(rel,k==2));}
    else if(Taken(rel,e.Name,skipped,r))yield return rel;}}
 }
 public static string[] Compare(string mirror,string source,int threads,string[] paths,bool[] on,bool defaultOn,string[] skipDirNames,string[] skipFileNames,string[] skipPaths,out long files,out long bytes){
  return Compare(mirror,source,threads,paths,on,defaultOn,skipDirNames,skipFileNames,skipPaths,new string[0],out files,out bytes);
 }
 // roots: the selected folders and files that were copied on their own ("" is the source root).
 public static string[] Compare(string mirror,string source,int threads,string[] paths,bool[] on,bool defaultOn,string[] skipDirNames,string[] skipFileNames,string[] skipPaths,string[] roots,out long files,out long bytes){
  var bad=new ConcurrentBag<string>();long f=0,b=0;mirror=Long(mirror);source=Long(source);
  var r=Make(paths,on,defaultOn,skipDirNames,skipFileNames,skipPaths,roots);
  // Every selected source file must be in the copy with the same content.
  Parallel.ForEach(Files(source,r,bad),new ParallelOptions{MaxDegreeOfParallelism=threads},rel=>{
   string s=source+"\\"+rel,m=mirror+"\\"+rel;
   try{
    var si=new FileInfo(s);var mi=new FileInfo(m);
    if(!mi.Exists){bad.Add("MISSING-IN-MIRROR\t"+rel);return;}
    if(mi.Length!=si.Length){bad.Add("SIZE\t"+rel);return;}
    if(Hash(m)!=Hash(s)){bad.Add("CONTENT\t"+rel);return;}
    Interlocked.Increment(ref f);Interlocked.Add(ref b,mi.Length);
   }catch(Exception ex){bad.Add("ERROR\t"+rel+"\t"+Plain(ex.Message));}
  });
  // Files only in the copy (deleted from the source) are listed, not read: a copy that never deletes keeps them.
  foreach(var rel in Files(mirror,r,bad))if(!File.Exists(source+"\\"+rel))bad.Add("MISSING-IN-SOURCE\t"+rel);
  files=f;bytes=b;return bad.OrderBy(x=>x,StringComparer.Ordinal).ToArray();
 }

 // --- Repair of single files (Invoke-FastMirror.ps1 -Repair) ---------------------------------------
 // Each file named by an earlier content check is looked at again and, where the copy still differs
 // from the source, copied again. Nothing is deleted or overwritten: the new copy is first written
 // beside the old one and read back, and only when it matches the source by SHA-256 is the old version
 // moved to the recovery folder and the new one given its name. So a file that cannot be read, copied
 // or matched leaves the copy as it was. One line per file, with tabs between: what was done, the
 // path, where the old version went (or nothing), and a note.
 //   REPAIRED         copied again, and the copy now matches the source
 //   MATCHES          the copy matches the source already; nothing was done
 //   SKIPPED          not a file this copy takes any more (no longer selected, gone from the source)
 //   STILL-DIFFERENT  the new copy did not match the source (the file is changing, or the drive fails)
 //   FAILED           could not be read, copied or moved
 public static string[] Repair(string mirror,string source,string recovery,int threads,string[] rels,string[] paths,bool[] on,bool defaultOn,string[] skipDirNames,string[] skipFileNames,string[] skipPaths,string[] roots){
  var done=new ConcurrentBag<string>();mirror=Long(mirror);source=Long(source);recovery=Long(recovery);
  var r=Make(paths,on,defaultOn,skipDirNames,skipFileNames,skipPaths,roots);
  Parallel.ForEach(rels.Distinct(StringComparer.OrdinalIgnoreCase),new ParallelOptions{MaxDegreeOfParallelism=Math.Max(1,threads)},rel=>done.Add(RepairOne(mirror,source,recovery,rel,r)));
  return done.OrderBy(x=>x,StringComparer.Ordinal).ToArray();
 }
 // A link or junction on the way from root down to rel, rel itself included. The copy never follows one.
 static bool Link(string root,string rel){
  string p=root;
  foreach(var part in rel.Split('\\')){p+="\\"+part;
   try{if((File.GetAttributes(p)&FileAttributes.ReparsePoint)!=0)return true;}catch(FileNotFoundException){return false;}catch(DirectoryNotFoundException){return false;}}
  return false;
 }
 // A working file of the repair is the repair's own; nothing else is ever deleted.
 static void Drop(string p){try{File.SetAttributes(p,FileAttributes.Normal);File.Delete(p);}catch{}}
 static string RepairOne(string mirror,string source,string recovery,string rel,Rules r){
  string s=source+"\\"+rel,m=mirror+"\\"+rel,old=recovery+"\\"+rel,work=null,moved="";
  try{
   // The list comes from a file; a path that could lead out of the copy is never followed.
   if(rel.Length==0||rel.IndexOfAny(new[]{':','/'})>=0||rel.Split('\\').Any(p=>p.Length==0||p=="."||p==".."))return "SKIPPED\t"+rel+"\t\tnot the path of a file in the copy";
   if(!Selected(rel,r))return "SKIPPED\t"+rel+"\t\tno longer selected for the plain copy";
   if(Link(source,rel))return "SKIPPED\t"+rel+"\t\tbehind a link or junction in the source, which is never copied";
   if(Directory.Exists(s))return "SKIPPED\t"+rel+"\t\ta folder in the source, not a file";
   if(!File.Exists(s))return "SKIPPED\t"+rel+"\t\tno longer in the source";
   if(Link(mirror,rel))return "FAILED\t"+rel+"\t\tthe copy has a link or junction on the way to this file";
   if(Directory.Exists(m))return "FAILED\t"+rel+"\t\tthe copy has a folder with this name; back up, which moves that folder aside";
   bool had=File.Exists(m);
   // Looked at again now: the file may have been put right since the check. A copy that cannot be
   // read is a damaged copy; a source that cannot be read fails the file (below).
   if(had&&new FileInfo(m).Length==new FileInfo(s).Length){
    string hs=Hash(s),hm=null;try{hm=Hash(m);}catch(IOException){}
    if(hm==hs)return "MATCHES\t"+rel+"\t\t";
   }
   string dir=Path.GetDirectoryName(m);Directory.CreateDirectory(dir);
   work=dir+"\\~repair-"+Guid.NewGuid().ToString("N").Substring(0,12)+".tmp";
   File.Copy(s,work,false);
   try{File.SetCreationTimeUtc(work,File.GetCreationTimeUtc(s));}catch{}
   if(Hash(work)!=Hash(s)){Drop(work);return "STILL-DIFFERENT\t"+rel+"\t\tthe new copy did not match the source: the file is changing, or the drive is failing";}
   if(had){Directory.CreateDirectory(Path.GetDirectoryName(old));File.Move(m,old);moved=Plain(old);}
   File.Move(work,m);
   return "REPAIRED\t"+rel+"\t"+moved+"\t";
  }catch(Exception ex){
   if(work!=null)Drop(work);
   // The old version had left its place and the new one could not take it: it is put back.
   if(moved.Length>0&&!File.Exists(m)){try{File.Move(old,m);moved="";}catch{}}
   return "FAILED\t"+rel+"\t"+moved+"\t"+Plain(ex.Message).Replace("\r"," ").Replace("\n"," ").Replace("\t"," ");
  }
 }

 // --- Names robocopy treats differently from what the lists say --------------------------------------
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
 struct Entry {public uint Attributes,C1,C2,A1,A2,W1,W2,SizeHigh,SizeLow,R0,R1;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)]public string Name;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=14)]public string Short;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern IntPtr FindFirstFileW(string pattern,out Entry e);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool FindNextFileW(IntPtr h,out Entry e);
 [DllImport("kernel32.dll")]static extern bool FindClose(IntPtr h);
 // The entries of one folder with their short (8.3) names, which .NET does not give. A folder that
 // cannot be read gives nothing here; the copy reports it.
 static List<Entry> List(string dir){
  var l=new List<Entry>();Entry e;IntPtr h=FindFirstFileW(dir+"\\*",out e);
  if(h==new IntPtr(-1))return l;
  try{do{if(e.Name!="."&&e.Name!="..")l.Add(e);}while(FindNextFileW(h,out e));}finally{FindClose(h);}
  return l;
 }
 // The short (8.3) name Windows gave a file or folder; empty when it has none.
 public static string ShortName(string path){
  Entry e;IntPtr h=FindFirstFileW(Long(path),out e);if(h==new IntPtr(-1))return "";
  FindClose(h);return e.Short??"";
 }
 // Names in one folder that differ only by the case of their letters, each paired with the first of
 // its kind (first, tab, other). A folder that keeps case apart can hold both; the copy holds one.
 public static string[] SameNames(IEnumerable<string> names){
  var first=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);var pairs=new List<string>();
  foreach(var n in names){string f;if(!first.TryGetValue(n,out f))first[n]=n;else if(f!=n)pairs.Add(f+"\t"+n);}
  return pairs.ToArray();
 }
 // One pass over the names (no file is read) in the folders the copy takes, for two things robocopy
 // does that the lists do not say:
 //   SHORT  path, short name, name: a file or folder (ending in \) that robocopy skips because its
 //          short name fits one of shortNames (the wildcard names of the personal Exclude list),
 //          while its own name fits no skipped name. Nothing inside such a folder is copied.
 //   CASE   path, path: two names in one folder that differ only by letter case.
 public static string[] Survey(string source,string[] paths,bool[] on,bool defaultOn,string[] skipDirNames,string[] skipFileNames,string[] skipPaths,string[] roots,string[] shortNames){
  var found=new List<string>();source=Long(source);var r=Make(paths,on,defaultOn,skipDirNames,skipFileNames,skipPaths,roots);var globs=Globs(shortNames);
  Func<string,int> fits=name=>{if(string.IsNullOrEmpty(name))return -1;for(int i=0;i<globs.Length;i++)if(globs[i].IsMatch(name))return i;return -1;};
  var stack=new Stack<KeyValuePair<string,bool>>();stack.Push(new KeyValuePair<string,bool>("",false));
  while(stack.Count>0){var top=stack.Pop();string d=top.Key;bool skipped=top.Value;var names=new List<string>();
   foreach(var e in List(d.Length==0?source:source+"\\"+d)){
    if((e.Attributes&(uint)FileAttributes.ReparsePoint)!=0)continue;
    string rel=d.Length==0?e.Name:d+"\\"+e.Name;bool root=r.Roots.Any(x=>Same(x,rel));int i;
    if((e.Attributes&(uint)FileAttributes.Directory)!=0){
     int k=Folder(rel,e.Name,skipped,r);if(k==0)continue;
     // robocopy reads this folder as part of a copied one (a folder entered only to reach a
     // selection inside it is not read by robocopy, and one copied on its own is never skipped).
     if(k==1&&!root&&IsOn(rel,r.Paths,r.On,r.DefaultOn)){
      if((i=fits(e.Short))>=0){found.Add("SHORT\t"+rel+"\\\t"+e.Short+"\t"+shortNames[i]);k=r.Roots.Any(x=>Under(x,rel))?2:0;if(k==0)continue;}
      else names.Add(e.Name);
     }
     stack.Push(new KeyValuePair<string,bool>(rel,k==2));
    }else if(Taken(rel,e.Name,skipped,r)){
     if(!root&&(i=fits(e.Short))>=0)found.Add("SHORT\t"+rel+"\t"+e.Short+"\t"+shortNames[i]);else names.Add(e.Name);
    }
   }
   foreach(var pair in SameNames(names)){var p=pair.Split('\t');string pre=d.Length==0?"":d+"\\";found.Add("CASE\t"+pre+p[0]+"\t"+pre+p[1]);}
  }
  return found.OrderBy(x=>x,StringComparer.Ordinal).ToArray();
 }
}
