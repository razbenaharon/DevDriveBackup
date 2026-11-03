// Content check of a plain copy (Invoke-FastMirror.ps1 -Verify and -VerifyOnly). Both sides are walked
// with the rules the copy uses (per-folder mode, skipped names and paths, links never followed), so a
// selected source file that is missing from the copy is a difference, not only a file whose content differs.
using System; using System.IO; using System.Linq; using System.Threading; using System.Threading.Tasks; using System.Security.Cryptography; using System.Collections.Concurrent; using System.Collections.Generic; using System.Text.RegularExpressions;
public static class MirrorVerifier {
 static string Hash(string p){using(var s=new FileStream(p,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete,1<<20))using(var h=SHA256.Create())return Convert.ToHexString(h.ComputeHash(s));}
 static bool Under(string path,string parent){return path.StartsWith(parent+"\\",StringComparison.OrdinalIgnoreCase);}
 // Mirror mode of a relative path: the longest entry that equals or contains it, else the default.
 static bool IsOn(string rel,string[] paths,bool[] on,bool defaultOn){
  int best=-1;
  for(int i=0;i<paths.Length;i++)if((string.Equals(rel,paths[i],StringComparison.OrdinalIgnoreCase)||Under(rel,paths[i]))&&(best<0||paths[i].Length>paths[best].Length))best=i;
  return best<0?defaultOn:on[best];
 }
 // robocopy wildcards in /XD and /XF names: * and ?, not case-sensitive.
 static Regex[] Globs(string[] names){return names.Select(n=>new Regex("^"+Regex.Escape(n).Replace("\\*",".*").Replace("\\?",".")+"$",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant)).ToArray();}
 sealed class Rules {public string[] Paths;public bool[] On;public bool DefaultOn;public Regex[] DirNames,FileNames;public string[] SkipPaths;}
 // Relative paths of the selected files below root. A folder that cannot be read is reported, not skipped silently.
 static IEnumerable<string> Files(string root,Rules r,ConcurrentBag<string> bad){
  var stack=new Stack<string>();stack.Push(root);
  while(stack.Count>0){var d=stack.Pop();FileSystemInfo[] items;
   try{items=new DirectoryInfo(d).GetFileSystemInfos();}catch(Exception ex){bad.Add("ERROR\t"+d.Substring(root.Length).TrimStart('\\')+"\t"+ex.Message);continue;}
   foreach(var e in items){
    if((e.Attributes&FileAttributes.ReparsePoint)!=0)continue;
    string rel=e.FullName.Substring(root.Length).TrimStart('\\');
    if(r.SkipPaths.Any(s=>string.Equals(rel,s,StringComparison.OrdinalIgnoreCase)||Under(rel,s)))continue;
    if((e.Attributes&FileAttributes.Directory)!=0){
     if(r.DirNames.Any(g=>g.IsMatch(e.Name)))continue;
     // Unselected folders are entered only when a selected entry lies inside them.
     if(IsOn(rel,r.Paths,r.On,r.DefaultOn)||Enumerable.Range(0,r.Paths.Length).Any(i=>r.On[i]&&Under(r.Paths[i],rel)))stack.Push(e.FullName);
    }else if(!r.FileNames.Any(g=>g.IsMatch(e.Name))&&IsOn(rel,r.Paths,r.On,r.DefaultOn))yield return rel;}}
 }
 public static string[] Compare(string mirror,string source,int threads,string[] paths,bool[] on,bool defaultOn,string[] skipDirNames,string[] skipFileNames,string[] skipPaths,out long files,out long bytes){
  var bad=new ConcurrentBag<string>();long f=0,b=0;
  var r=new Rules{Paths=paths,On=on,DefaultOn=defaultOn,DirNames=Globs(skipDirNames),FileNames=Globs(skipFileNames),SkipPaths=skipPaths.Select(s=>s.Trim('\\')).Where(s=>s.Length>0).ToArray()};
  // Every selected source file must be in the copy with the same content.
  Parallel.ForEach(Files(source,r,bad),new ParallelOptions{MaxDegreeOfParallelism=threads},rel=>{
   string s=Path.Combine(source,rel),m=Path.Combine(mirror,rel);
   try{
    var si=new FileInfo(s);var mi=new FileInfo(m);
    if(!mi.Exists){bad.Add("MISSING-IN-MIRROR\t"+rel);return;}
    if(mi.Length!=si.Length){bad.Add("SIZE\t"+rel);return;}
    if(Hash(m)!=Hash(s)){bad.Add("CONTENT\t"+rel);return;}
    Interlocked.Increment(ref f);Interlocked.Add(ref b,mi.Length);
   }catch(Exception ex){bad.Add("ERROR\t"+rel+"\t"+ex.Message);}
  });
  // Files only in the copy (deleted from the source) are listed, not read: a copy that never deletes keeps them.
  foreach(var rel in Files(mirror,r,bad))if(!File.Exists(Path.Combine(source,rel)))bad.Add("MISSING-IN-SOURCE\t"+rel);
  files=f;bytes=b;return bad.OrderBy(x=>x,StringComparer.Ordinal).ToArray();
 }
}
