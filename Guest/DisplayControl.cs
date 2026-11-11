using System;
using System.Runtime.InteropServices;

public static class WindowVMDisplay {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct Device {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string Name;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Description;
    public uint Flags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string ID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Key;
  }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct Mode {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string Name;
    public ushort SpecVersion, DriverVersion, Size, DriverExtra;
    public uint Fields;
    public int X, Y;
    public uint Orientation, FixedOutput;
    public short Color, Duplex, YResolution, TTOption, Collate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string FormName;
    public ushort LogPixels;
    public uint BitsPerPixel, Width, Height, DisplayFlags, Frequency, ICMMethod, ICMIntent,
      MediaType, DitherType, Reserved1, Reserved2, PanningWidth, PanningHeight;
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplayDevices(string name, uint index, ref Device device, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplaySettings(string name, int index, ref Mode mode);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string name, ref Mode mode, IntPtr hwnd, uint flags, IntPtr param);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="ChangeDisplaySettingsExW")] static extern int Apply(string name, IntPtr mode, IntPtr hwnd, uint flags, IntPtr param);

  static Mode Read(string name) {
    Mode m = new Mode(); m.Size = (ushort)Marshal.SizeOf(typeof(Mode));
    if (!EnumDisplaySettings(name, -1, ref m)) throw new InvalidOperationException("Cannot read display mode: " + name);
    return m;
  }
  static Device Get(uint index) { Device d = new Device(); d.cb = Marshal.SizeOf(typeof(Device)); EnumDisplayDevices(null,index,ref d,0); return d; }
  public static string EnsurePrimary() {
    Device gpu = new Device();
    for (uint i=0;i<16;i++) {
      Device d=Get(i); if (String.IsNullOrEmpty(d.Name)) break;
      if ((d.ID ?? "").IndexOf("VEN_1AF4&DEV_1050",StringComparison.OrdinalIgnoreCase)>=0) { gpu=d; break; }
    }
    if (String.IsNullOrEmpty(gpu.Name)) throw new InvalidOperationException("VirtIO GPU driver is not installed");
    Mode mode=Read(gpu.Name);
    if ((gpu.Flags & 4)==0) {
      mode.X=0; mode.Y=0; mode.Fields |= 0x20;
      int result=ChangeDisplaySettingsEx(gpu.Name,ref mode,IntPtr.Zero,0x10000000 | 1 | 0x10,IntPtr.Zero);
      if (result!=0) throw new InvalidOperationException("Cannot select VirtIO primary display: " + result);
    }
    // RAMFB remains available for firmware/recovery, but the interactive Windows
    // desktop uses only the VirtIO monitor; this avoids an invisible second desktop.
    for (uint i=0;i<16;i++) {
      Device d=Get(i); if (String.IsNullOrEmpty(d.Name)) break;
      if (d.Name==gpu.Name || (d.Flags & 1)==0 || (d.Flags & 8)!=0) continue;
      Mode other=Read(d.Name); other.Width=0; other.Height=0; other.X=0; other.Y=0; other.Fields=0x20 | 0x80000 | 0x100000;
      int result=ChangeDisplaySettingsEx(d.Name,ref other,IntPtr.Zero,0x10000000 | 1,IntPtr.Zero);
      // Some Windows Basic Display drivers reject detaching RAMFB. Keep it as
      // a secondary monitor in that case; the VirtIO primary still adapts.
    }
    int applied=Apply(null,IntPtr.Zero,IntPtr.Zero,0,IntPtr.Zero);
    if (applied!=0) throw new InvalidOperationException("Cannot apply display layout: " + applied);
    return gpu.Name;
  }
  [StructLayout(LayoutKind.Sequential)] public struct Luid { public uint Low; public int High; }
  [StructLayout(LayoutKind.Sequential)] struct OpenAdapter { public IntPtr DC; public uint Handle; public Luid ID; public uint Source; }
  [StructLayout(LayoutKind.Sequential)] struct Escape { public uint Adapter, Device, Type, Flags; public IntPtr Data; public uint Size, Context; }
  [StructLayout(LayoutKind.Sequential)] struct SourcePath { public Luid Adapter; public uint ID, Mode, Flags; }
  [StructLayout(LayoutKind.Sequential)] struct TargetPath {
    public Luid Adapter; public uint ID, Mode, Technology, Rotation, Scaling, RefreshNumerator, RefreshDenominator, Scanline;
    public int Available; public uint Flags;
  }
  [StructLayout(LayoutKind.Sequential)] struct DisplayPath { public SourcePath Source; public TargetPath Target; public uint Flags; }
  [DllImport("gdi32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateDC(string driver, string device, string output, IntPtr init);
  [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
  [DllImport("gdi32.dll")] static extern int D3DKMTOpenAdapterFromHdc(ref OpenAdapter adapter);
  [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref uint adapter);
  [DllImport("gdi32.dll")] static extern int D3DKMTEscape(ref Escape escape);
  [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
  [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, [Out] DisplayPath[] pathArray, ref uint modes, IntPtr modeArray, IntPtr topology);
  [DllImport("user32.dll")] static extern int SetDisplayConfig(uint paths, [In] DisplayPath[] pathArray, uint modes, IntPtr modeArray, uint flags);
  static void Check(int result, string operation) { if (result!=0) throw new InvalidOperationException(operation+": 0x"+result.ToString("X8")); }
  public static void SetSize(string name, int width, int height) {
    // Target the known VirtIO device directly. Upstream viogpures stops its
    // enumeration when adapter zero is RAMFB and never reaches adapter one.
    IntPtr dc=CreateDC(null,name,null,IntPtr.Zero);
    if (dc==IntPtr.Zero) throw new InvalidOperationException("Cannot open VirtIO display context");
    OpenAdapter adapter=new OpenAdapter(); adapter.DC=dc;
    IntPtr data=Marshal.AllocHGlobal(8);
    try {
      Check(D3DKMTOpenAdapterFromHdc(ref adapter),"Open VirtIO adapter");
      Marshal.WriteInt16(data,0,2); Marshal.WriteInt16(data,2,4);
      Marshal.WriteInt16(data,4,(short)width); Marshal.WriteInt16(data,6,(short)height);
      Escape escape=new Escape(); escape.Adapter=adapter.Handle; escape.Data=data; escape.Size=8;
      Check(D3DKMTEscape(ref escape),"Register custom VirtIO mode");
      Marshal.WriteInt16(data,0,1);
      Check(D3DKMTEscape(ref escape),"Read custom VirtIO mode");
      if (Marshal.ReadInt16(data,4)!=width || Marshal.ReadInt16(data,6)!=height)
        throw new InvalidOperationException("VirtIO rejected custom dimensions");
      for (int attempt=0;attempt<3;attempt++) {
        uint paths,modes; Check(GetDisplayConfigBufferSizes(2,out paths,out modes),"Size active display paths");
        DisplayPath[] all=new DisplayPath[paths]; IntPtr buffer=Marshal.AllocHGlobal(checked((int)modes*64));
        try {
          int queried=QueryDisplayConfig(2,ref paths,all,ref modes,buffer,IntPtr.Zero);
          if (queried==122) continue;
          Check(queried,"Query active display paths");
          for (int i=0;i<paths;i++) {
            DisplayPath path=all[i];
            if (path.Source.Adapter.Low!=adapter.ID.Low || path.Source.Adapter.High!=adapter.ID.High || path.Source.ID!=adapter.Source) continue;
            if (path.Source.Mode>=modes) throw new InvalidOperationException("No source mode for VirtIO");
            IntPtr source=IntPtr.Add(buffer,checked((int)path.Source.Mode*64+16));
            Marshal.WriteInt32(source,0,width); Marshal.WriteInt32(source,4,height);
            Marshal.WriteInt32(source,12,0); Marshal.WriteInt32(source,16,0);
            // Supply only the VirtIO path, retaining RAMFB for firmware recovery.
            Check(SetDisplayConfig(1,new DisplayPath[]{path},modes,buffer,0x80|0x20|0x400|0x200),"Apply VirtIO display mode");
            return;
          }
          throw new InvalidOperationException("VirtIO display path is inactive");
        } finally { Marshal.FreeHGlobal(buffer); }
      }
      throw new InvalidOperationException("Display configuration kept changing");
    } finally {
      if (adapter.Handle!=0) D3DKMTCloseAdapter(ref adapter.Handle);
      Marshal.FreeHGlobal(data); DeleteDC(dc);
    }
  }
  public static int[] Current(string name) { Mode m=Read(name); return new int[]{(int)m.Width,(int)m.Height}; }
}
