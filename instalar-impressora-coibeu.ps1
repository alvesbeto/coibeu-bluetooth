# Install the Coibeu WKDY-81X thermal label printer over Bluetooth on Windows.
# Label Driver Setup ships a Unidrv TSPL driver (model LABEL) with no USB
# hardware ID. LABELCORE.dll emits SIZE, GAP, BITMAP and PRINT through
# WritePrinter. Pairing is not required: the printer accepts TSPL on RFCOMM
# channel 1. A user-session bridge listens on 127.0.0.1:9101 and forwards
# each job to that channel. The spooler port is a raw TCP port on the bridge.

param(
    [Parameter(Position = 0)]
    [string]$Action,
    [switch]$Elevated
)

$ErrorActionPreference = "Stop"
$Queue = "Coibeu-WKDY-81X"
$DriverModel = "LABEL"
$PrinterName = "BlueTooth Printer"
$KnownMac = "66:32:1A:63:16:C7"
$Channel = "1"
$TcpPort = 9101
$TaskName = "Coibeu-WKDY-81X"
$BridgePort = "CoibeuBT"

function Log {
    param([string]$Message)
    Write-Host $Message
}

if ($Action -and $Action -ne "testar") {
    Log "Uso: instalar-impressora-coibeu.ps1 [testar]"
    exit 1
}

if ($PSVersionTable.PSEdition -ne "Desktop") {
    $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Action) { $commandLine += " `"$Action`"" }
    if ($Elevated) { $commandLine += " -Elevated" }
    $proc = Start-Process -FilePath $windowsPowerShell -ArgumentList $commandLine -Wait -PassThru
    exit $proc.ExitCode
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $commandLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Action) { $commandLine += " `"$Action`"" }
    $commandLine += " -Elevated"
    try {
        Start-Process -FilePath $windowsPowerShell -ArgumentList $commandLine -Verb RunAs | Out-Null
    } catch {
        Log "Instalacao cancelada."
        exit 1
    }
    exit 0
}

# Loaded with Add-Type. Keep this C# 5: Windows PowerShell 5.1 compiles with
# the .NET Framework CodeDom provider.
$BluetoothSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class CoibeuBluetooth
{
    public const int ErrorSuccess = 0;

    [StructLayout(LayoutKind.Sequential)]
    public struct SystemTime
    {
        public ushort Year;
        public ushort Month;
        public ushort DayOfWeek;
        public ushort Day;
        public ushort Hour;
        public ushort Minute;
        public ushort Second;
        public ushort Milliseconds;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SearchParams
    {
        public int Size;
        public bool ReturnAuthenticated;
        public bool ReturnRemembered;
        public bool ReturnUnknown;
        public bool ReturnConnected;
        public bool IssueInquiry;
        public byte TimeoutMultiplier;
        public IntPtr Radio;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DeviceInfo
    {
        public int Size;
        public ulong Address;
        public uint ClassOfDevice;
        public bool Connected;
        public bool Remembered;
        public bool Authenticated;
        public SystemTime LastSeen;
        public SystemTime LastUsed;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)]
        public string Name;
    }

    public sealed class Device
    {
        public ulong Address;
        public string Mac;
        public string Name;
        public bool Connected;
        public bool Remembered;
        public bool Authenticated;
    }

    [DllImport("bthprops.cpl", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr BluetoothFindFirstDevice(ref SearchParams search, ref DeviceInfo info);

    [DllImport("bthprops.cpl", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool BluetoothFindNextDevice(IntPtr find, ref DeviceInfo info);

    [DllImport("bthprops.cpl", CharSet = CharSet.Unicode)]
    private static extern bool BluetoothFindDeviceClose(IntPtr find);

    private static DeviceInfo NewInfo()
    {
        DeviceInfo info = new DeviceInfo();
        info.Size = Marshal.SizeOf(typeof(DeviceInfo));
        return info;
    }

    public static string FormatMac(ulong address)
    {
        return string.Format(
            "{0:X2}:{1:X2}:{2:X2}:{3:X2}:{4:X2}:{5:X2}",
            (address >> 40) & 0xFF,
            (address >> 32) & 0xFF,
            (address >> 24) & 0xFF,
            (address >> 16) & 0xFF,
            (address >> 8) & 0xFF,
            address & 0xFF);
    }

    private static Device ToDevice(DeviceInfo info)
    {
        Device device = new Device();
        device.Address = info.Address;
        device.Mac = FormatMac(info.Address);
        device.Name = info.Name == null ? "" : info.Name.Trim();
        device.Connected = info.Connected;
        device.Remembered = info.Remembered;
        device.Authenticated = info.Authenticated;
        return device;
    }

    public static Device[] Discover(bool inquiry, byte timeoutMultiplier)
    {
        SearchParams search = new SearchParams();
        search.Size = Marshal.SizeOf(typeof(SearchParams));
        search.ReturnAuthenticated = true;
        search.ReturnRemembered = true;
        search.ReturnUnknown = true;
        search.ReturnConnected = true;
        search.IssueInquiry = inquiry;
        search.TimeoutMultiplier = timeoutMultiplier;
        search.Radio = IntPtr.Zero;

        DeviceInfo info = NewInfo();
        IntPtr handle = BluetoothFindFirstDevice(ref search, ref info);
        List<Device> found = new List<Device>();
        if (handle == IntPtr.Zero)
        {
            return found.ToArray();
        }
        try
        {
            do
            {
                found.Add(ToDevice(info));
                info = NewInfo();
            }
            while (BluetoothFindNextDevice(handle, ref info));
        }
        finally
        {
            BluetoothFindDeviceClose(handle);
        }
        return found.ToArray();
    }
}
'@

function Initialize-BluetoothApi {
    if ("CoibeuBluetooth" -as [type]) { return }
    Add-Type -TypeDefinition $BluetoothSource -Language CSharp
}

function Normalize-Mac {
    param([string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return "" }
    $hex = ([regex]::Replace($Mac, "[^0-9A-Fa-f]", "")).ToUpperInvariant()
    if ($hex.Length -ne 12) { return "" }
    $octets = for ($i = 0; $i -lt 12; $i += 2) { $hex.Substring($i, 2) }
    return ($octets -join ":")
}

function Read-PrinterConfig {
    $path = Join-Path $env:ProgramData "Coibeu\printer.conf"
    $result = @{ Mac = "" }
    if (-not (Test-Path -LiteralPath $path)) { return $result }
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match "^MAC=(.+)$") {
            $result.Mac = Normalize-Mac $Matches[1]
        }
    }
    return $result
}

function Write-PrinterConfig {
    param([string]$Mac)
    $dir = Join-Path $env:ProgramData "Coibeu"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir "printer.conf"
    $lines = @(
        "MAC=$Mac",
        "CHANNEL=$Channel",
        "PORT=$TcpPort"
    )
    Set-Content -LiteralPath $path -Value $lines -Encoding ASCII
}

function Get-DriverDirectory {
    $arch = "Driver32"
    if ([Environment]::Is64BitOperatingSystem) { $arch = "Driver64" }
    $dir = Join-Path $PSScriptRoot "drivers\windows\$arch"
    $required = @(
        "LabelPrinter.inf",
        "LabelPrinter.gpd",
        "LabelPrinter.ini",
        "LABELCORE.dll",
        "LABELUI.dll",
        "printer.cat"
    )
    foreach ($name in $required) {
        $path = Join-Path $dir $name
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Arquivo de driver ausente: $path"
        }
    }
    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $dir "printer.cat")
    if ($signature.Status -ne "Valid") {
        throw "Catalogo do driver invalido: $($signature.Status)"
    }
    return $dir
}

function Test-LabelDriver {
    $drivers = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $DriverModel })
    return ($drivers.Count -gt 0)
}

function Install-LabelDriver {
    param([string]$InfPath)
    if (Test-LabelDriver) {
        Log "Driver $DriverModel ja instalado."
        return
    }
    # Add-PrinterDriver rejects this INF with 0x80070057. pnputil stages the
    # signed package and printui registers the Unidrv model with the spooler.
    Log "Instalando driver $DriverModel..."
    $pnputil = Join-Path $env:SystemRoot "System32\pnputil.exe"
    & $pnputil /add-driver $InfPath /install | Out-Host
    Log "pnputil $LASTEXITCODE"
    $arch = "x86"
    if ([Environment]::Is64BitOperatingSystem) { $arch = "x64" }
    $rundll = Join-Path $env:SystemRoot "System32\rundll32.exe"
    $printuiArgs = "printui.dll,PrintUIEntry /ia /m `"$DriverModel`" /h `"$arch`" /f `"$InfPath`""
    $proc = Start-Process -FilePath $rundll -ArgumentList $printuiArgs -Wait -PassThru
    if (-not (Test-LabelDriver)) {
        throw "Driver $DriverModel nao apareceu no spooler (printui $($proc.ExitCode))."
    }
}

function Enable-BluetoothRadio {
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
        [void][Windows.Devices.Radios.Radio, Windows.Devices.Radios, ContentType = WindowsRuntime]
        $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq "AsTask" -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        } | Select-Object -First 1
        if (-not $asTask) { throw "AsTask indisponivel." }
        $listType = [System.Collections.Generic.IReadOnlyList`1].MakeGenericType([Windows.Devices.Radios.Radio])
        $operation = [Windows.Devices.Radios.Radio]::GetRadiosAsync()
        $task = $asTask.MakeGenericMethod($listType).Invoke($null, @($operation))
        $task.Wait()
        if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
        foreach ($radio in @($task.Result)) {
            if ($radio.Kind -ne [Windows.Devices.Radios.RadioKind]::Bluetooth) { continue }
            if ($radio.State -eq [Windows.Devices.Radios.RadioState]::On) { continue }
            $setOperation = $radio.SetStateAsync([Windows.Devices.Radios.RadioState]::On)
            $setTask = $asTask.MakeGenericMethod([Windows.Devices.Radios.RadioAccessStatus]).Invoke($null, @($setOperation))
            $setTask.Wait()
        }
    } catch {
        Log "Radio Bluetooth: $($_.Exception.Message)"
    }
}

function Get-BluetoothDevices {
    param([bool]$Inquiry)
    $timeout = [byte]0
    if ($Inquiry) { $timeout = [byte]16 }
    $raw = [CoibeuBluetooth]::Discover($Inquiry, $timeout)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($raw)) {
        if ($null -ne $item) { [void]$items.Add($item) }
    }
    # The comma keeps an empty array from collapsing to $null.
    return ,$items.ToArray()
}

function Select-CoibeuDevice {
    param(
        $Devices,
        [string[]]$Macs
    )
    foreach ($device in @($Devices)) {
        if ($null -eq $device) { continue }
        if ([string]::Equals($device.Name, $PrinterName, [StringComparison]::OrdinalIgnoreCase)) {
            return $device
        }
    }
    foreach ($mac in $Macs) {
        foreach ($device in @($Devices)) {
            if ($null -eq $device) { continue }
            if ($device.Mac -eq $mac) { return $device }
        }
    }
    return $null
}

# SOCKADDR_BTH is packed to 1 byte. A default-aligned struct makes connect
# return WSAEADDRNOTAVAIL (10049). Channel 1 with an empty service GUID
# matches the direct RFCOMM connection used on Linux.
$BridgeSource = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;

public static class CoibeuBridge
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct WSAData
    {
        public short wVersion;
        public short wHighVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)]
        public string szDescription;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)]
        public string szSystemStatus;
        public short iMaxSockets;
        public short iMaxUdpDg;
        public IntPtr lpVendorInfo;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct SockAddrBth
    {
        public ushort addressFamily;
        public ulong btAddr;
        public Guid serviceClassId;
        public uint port;
    }

    [DllImport("ws2_32.dll")]
    public static extern int WSAStartup(ushort version, out WSAData data);

    [DllImport("ws2_32.dll")]
    public static extern IntPtr socket(int af, int type, int protocol);

    [DllImport("ws2_32.dll")]
    public static extern int connect(IntPtr handle, ref SockAddrBth name, int namelen);

    [DllImport("ws2_32.dll")]
    public static extern int send(IntPtr handle, byte[] buf, int len, int flags);

    [DllImport("ws2_32.dll")]
    public static extern int closesocket(IntPtr handle);

    [DllImport("ws2_32.dll")]
    public static extern int WSAGetLastError();

    [DllImport("ws2_32.dll")]
    public static extern int setsockopt(IntPtr handle, int level, int optname, ref int optval, int optlen);

    static string logPath;

    static string ConfigPath()
    {
        string env = Environment.GetEnvironmentVariable("COIBEU_CONFIG");
        if (!string.IsNullOrEmpty(env)) return env;
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "Coibeu",
            "printer.conf");
    }

    static string GetValue(string key, string fallback)
    {
        string path = ConfigPath();
        if (!File.Exists(path)) return fallback;
        string[] lines = File.ReadAllLines(path);
        for (int i = 0; i < lines.Length; i++)
        {
            string line = lines[i].Trim();
            string prefix = key + "=";
            if (line.StartsWith(prefix)) return line.Substring(prefix.Length).Trim();
        }
        return fallback;
    }

    static ulong ParseMac(string mac)
    {
        string hex = mac.Replace(":", "").Replace("-", "");
        return Convert.ToUInt64(hex, 16);
    }

    static void Log(string message)
    {
        string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message;
        Console.Error.WriteLine(line);
        try
        {
            File.AppendAllText(logPath, line + Environment.NewLine);
        }
        catch (IOException)
        {
        }
    }

    static IntPtr OpenLink(ulong address, uint channel)
    {
        Exception last = null;
        for (int attempt = 1; attempt <= 8; attempt++)
        {
            IntPtr handle = socket(32, 1, 3);
            if (handle == IntPtr.Zero || handle.ToInt64() == -1)
            {
                throw new IOException("socket " + WSAGetLastError());
            }
            int timeout = 20000;
            setsockopt(handle, 0xffff, 0x1005, ref timeout, 4);
            setsockopt(handle, 0xffff, 0x1006, ref timeout, 4);
            SockAddrBth addr = new SockAddrBth();
            addr.addressFamily = 32;
            addr.btAddr = address;
            addr.serviceClassId = Guid.Empty;
            addr.port = channel;
            int rc = connect(handle, ref addr, Marshal.SizeOf(typeof(SockAddrBth)));
            if (rc == 0) return handle;
            int error = WSAGetLastError();
            closesocket(handle);
            last = new IOException("connect " + error);
            Log("RFCOMM attempt " + attempt + " failed: " + error);
            Thread.Sleep(1000);
        }
        throw last;
    }

    static void SendAll(IntPtr handle, byte[] payload)
    {
        int offset = 0;
        while (offset < payload.Length)
        {
            int count = payload.Length - offset;
            if (count > 65536) count = 65536;
            byte[] slice = new byte[count];
            Buffer.BlockCopy(payload, offset, slice, 0, count);
            int sent = send(handle, slice, count, 0);
            if (sent <= 0) throw new IOException("send " + WSAGetLastError());
            offset += sent;
        }
    }

    static byte[] ReadJob(TcpClient client)
    {
        NetworkStream stream = client.GetStream();
        MemoryStream buffer = new MemoryStream();
        byte[] chunk = new byte[65536];
        while (buffer.Length < 8 * 1024 * 1024)
        {
            int read;
            try
            {
                read = stream.Read(chunk, 0, chunk.Length);
            }
            catch (IOException)
            {
                break;
            }
            if (read <= 0) break;
            buffer.Write(chunk, 0, read);
        }
        return buffer.ToArray();
    }

    static void Deliver(TcpClient client, ulong address, uint channel)
    {
        IntPtr link = OpenLink(address, channel);
        try
        {
            byte[] payload = ReadJob(client);
            Log("forwarding " + payload.Length + " bytes");
            if (payload.Length > 0)
            {
                SendAll(link, payload);
                Thread.Sleep(300);
            }
        }
        finally
        {
            closesocket(link);
        }
    }

    public static void Main()
    {
        string dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "Coibeu");
        Directory.CreateDirectory(dir);
        logPath = Path.Combine(dir, "rfcomm.log");
        try
        {
            FileInfo info = new FileInfo(logPath);
            if (info.Exists && info.Length > 1024 * 1024) File.Delete(logPath);
        }
        catch (IOException)
        {
        }

        string macText = GetValue("MAC", "");
        if (macText.Length == 0) throw new InvalidOperationException("MAC ausente");
        ulong address = ParseMac(macText);
        uint channel = uint.Parse(GetValue("CHANNEL", "1"));
        int port = int.Parse(GetValue("PORT", "9101"));

        WSAData data;
        int started = WSAStartup(0x0202, out data);
        if (started != 0) throw new InvalidOperationException("WSAStartup " + started);

        TcpListener listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start(1);
        Log("listening on 127.0.0.1:" + port + " for " + macText + " channel " + channel);
        while (true)
        {
            TcpClient client = listener.AcceptTcpClient();
            client.ReceiveTimeout = 60000;
            client.SendTimeout = 60000;
            try
            {
                Deliver(client, address, channel);
                client.Close();
            }
            catch (Exception ex)
            {
                Log("job failed: " + ex.Message);
                try
                {
                    client.LingerState = new LingerOption(true, 0);
                }
                catch (SocketException)
                {
                }
                client.Close();
            }
        }
    }
}
'@

function Get-CscPath {
    $framework = "Framework"
    if ([Environment]::Is64BitOperatingSystem) { $framework = "Framework64" }
    $csc = Join-Path $env:SystemRoot "Microsoft.NET\$framework\v4.0.30319\csc.exe"
    if (-not (Test-Path -LiteralPath $csc)) {
        throw "Compilador C# ausente: $csc"
    }
    return $csc
}

function Register-BridgeTask {
    param([string]$ExePath)
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute $ExePath
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
}

function Install-Bridge {
    param([string]$Mac)
    $dir = Join-Path $env:ProgramData "Coibeu"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Write-PrinterConfig $Mac
    $source = Join-Path $dir "coibeu-rfcomm.cs"
    $exe = Join-Path $dir "coibeu-rfcomm.exe"
    $log = Join-Path $dir "rfcomm.log"
    Set-Content -LiteralPath $source -Value $BridgeSource -Encoding ASCII
    Get-Process -Name "coibeu-rfcomm" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 400
    $csc = Get-CscPath
    & $csc /nologo /optimize /target:exe "/out:$exe" $source
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
        throw "Falha ao compilar a ponte RFCOMM."
    }
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
    Register-BridgeTask $exe
    Start-Process -FilePath $exe -WindowStyle Hidden | Out-Null
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if ((Test-Path -LiteralPath $log) -and (Select-String -LiteralPath $log -Pattern "listening" -Quiet -ErrorAction SilentlyContinue)) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw "Ponte RFCOMM nao escutou em 127.0.0.1:${TcpPort}."
}

function Ensure-TcpPort {
    $existing = Get-WmiObject -Class Win32_TCPIPPrinterPort -Filter "Name='$BridgePort'" -ErrorAction SilentlyContinue
    if ($existing) {
        $existing.HostAddress = "127.0.0.1"
        $existing.PortNumber = [uint32]$TcpPort
        $existing.Protocol = [uint32]1
        $existing.SNMPEnabled = $false
        $existing.Put() | Out-Null
        return $BridgePort
    }
    $created = ([wmiclass]"Win32_TCPIPPrinterPort").CreateInstance()
    $created.Name = $BridgePort
    $created.HostAddress = "127.0.0.1"
    $created.PortNumber = [uint32]$TcpPort
    $created.Protocol = [uint32]1
    $created.SNMPEnabled = $false
    $created.Put() | Out-Null
    return $BridgePort
}

function Remove-ExistingQueue {
    $current = Get-Printer -Name $Queue -ErrorAction SilentlyContinue
    if (-not $current) { return }
    Get-PrintJob -PrinterName $Queue -ErrorAction SilentlyContinue | Remove-PrintJob -ErrorAction SilentlyContinue
    Remove-Printer -Name $Queue
}

function Install-Queue {
    Remove-ExistingQueue
    $portName = Ensure-TcpPort
    Add-Printer -Name $Queue -DriverName $DriverModel -PortName $portName -Comment "Coibeu WKDY-81X" -Location "Bluetooth"
    # Windows 10 otherwise replaces the default with the last printer used.
    $key = "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"
    New-ItemProperty -Path $key -Name "LegacyDefaultPrinterMode" -PropertyType DWord -Value 1 -Force | Out-Null
    $network = New-Object -ComObject WScript.Network
    $network.SetDefaultPrinter($Queue)
    return $portName
}

function Send-TestLabel {
    Add-Type -AssemblyName System.Drawing
    $doc = New-Object System.Drawing.Printing.PrintDocument
    $doc.PrinterSettings.PrinterName = $Queue
    if (-not $doc.PrinterSettings.IsValid) {
        throw "Fila $Queue indisponivel."
    }
    $doc.PrintController = New-Object System.Drawing.Printing.StandardPrintController
    $width = [int][Math]::Round(40 / 25.4 * 100)
    $height = [int][Math]::Round(30 / 25.4 * 100)
    $paper = New-Object System.Drawing.Printing.PaperSize("40 x 30 mm", $width, $height)
    $doc.DefaultPageSettings.PaperSize = $paper
    $doc.DefaultPageSettings.Margins = New-Object System.Drawing.Printing.Margins(0, 0, 0, 0)
    $doc.DocumentName = "coibeu-teste"
    $handler = {
        param($sender, $eventArgs)
        $font = New-Object System.Drawing.Font("Courier New", 12)
        $eventArgs.Graphics.DrawString("WKDY-81X", $font, [System.Drawing.Brushes]::Black, 8, 16)
        $font.Dispose()
        $eventArgs.HasMorePages = $false
    }
    $doc.add_PrintPage($handler)
    try {
        $doc.Print()
    } finally {
        $doc.remove_PrintPage($handler)
        $doc.Dispose()
    }
}

function Resolve-Printer {
    $saved = Read-PrinterConfig
    $macs = @()
    if ($saved.Mac) { $macs += $saved.Mac }
    $known = Normalize-Mac $KnownMac
    if ($known -and ($macs -notcontains $known)) { $macs += $known }

    $cached = Get-BluetoothDevices $false
    $device = Select-CoibeuDevice $cached $macs
    if (-not $device) {
        Log "Procurando $PrinterName..."
        $live = Get-BluetoothDevices $true
        $device = Select-CoibeuDevice $live $macs
    }
    if ($device) { return $device.Mac }

    if ($saved.Mac) {
        Log "Impressora fora do alcance. Reutilizando $($saved.Mac)."
        return $saved.Mac
    }
    throw "Impressora Bluetooth nao encontrada. Ligue a WKDY-81X e execute de novo."
}

function Install-Printer {
    $driverDir = Get-DriverDirectory
    Log "Driver: $driverDir"
    Install-LabelDriver (Join-Path $driverDir "LabelPrinter.inf")
    Enable-BluetoothRadio
    Initialize-BluetoothApi

    $mac = Resolve-Printer
    Log "Impressora: $mac"
    Install-Bridge $mac
    $printerPort = Install-Queue
    Log "Fila $Queue pronta em $printerPort (127.0.0.1:${TcpPort})"
    if ($Action -eq "testar") {
        Send-TestLabel
        Log "Etiqueta de teste enviada para $Queue."
    }
}

function Wait-IfElevated {
    if (-not $Elevated) { return }
    Write-Host ""
    Write-Host "Pressione Enter para fechar."
    try { [void](Read-Host) } catch { }
}

try {
    Install-Printer
} catch {
    Log $_.Exception.Message
    Wait-IfElevated
    exit 1
}

Wait-IfElevated
exit 0
