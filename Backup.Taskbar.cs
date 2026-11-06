// Gives a window its own taskbar identity. Backup Center runs inside PowerShell, and the taskbar
// groups windows by the program that owns them, so without this the button shows PowerShell's icon
// (a Store install of PowerShell always shows its own icon there). With an ID of its own the window
// gets its own button with the window's icon, and pinning it starts Backup Center again rather than
// a bare PowerShell.
using System;
using System.Runtime.InteropServices;

public static class CenterTaskbar
{
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyKey
    {
        public Guid FormatId;
        public uint PropertyId;
    }

    // Only the two kinds used here: empty (clears a value) and a wide string.
    [StructLayout(LayoutKind.Explicit, Size = 16)]
    private struct PropVariant
    {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr Pointer;
    }

    [DllImport("shell32.dll")]
    private static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PropVariant value);

    private const uint RelaunchCommand = 2, RelaunchIconResource = 3, RelaunchDisplayName = 4, AppId = 5;

    // Sets the window's taskbar ID and what a pinned button starts. Pass null for id to remove them
    // again, which Windows asks for before the window closes.
    public static void Set(IntPtr window, string id, string command, string icon, string name)
    {
        Guid iid = typeof(IPropertyStore).GUID;
        IPropertyStore store;
        Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(window, ref iid, out store));
        try
        {
            // The relaunch details go first: the taskbar reads them when the ID arrives.
            Write(store, RelaunchCommand, id == null ? null : command);
            Write(store, RelaunchIconResource, id == null ? null : icon);
            Write(store, RelaunchDisplayName, id == null ? null : name);
            Write(store, AppId, id);
            Marshal.ThrowExceptionForHR(store.Commit());
        }
        finally { Marshal.ReleaseComObject(store); }
    }

    private static void Write(IPropertyStore store, uint id, string text)
    {
        PropertyKey key = new PropertyKey();
        key.FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        key.PropertyId = id;
        PropVariant value = new PropVariant();
        if (text != null) { value.Type = 31; value.Pointer = Marshal.StringToCoTaskMemUni(text); }
        try { Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value)); }
        finally { PropVariantClear(ref value); }
    }
}
