param([Parameter(Mandatory = $true)][string]$ExpectedSid)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$AccountName = 'SkyrimDeploy'

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'batch-right.ps1 requires Administrator Windows PowerShell'
}
if (-not [Environment]::Is64BitProcess -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'batch-right.ps1 requires 64-bit Windows PowerShell 5.1'
}
$User = Get-LocalUser -Name $AccountName -ErrorAction Stop
if (-not $User.Enabled -or $User.SID.Value -ne $ExpectedSid) {
    throw 'SkyrimDeploy identity does not match the expected SID'
}

if (-not ('SkyrimDeployBatchRight' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

public static class SkyrimDeployBatchRight
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LSA_OBJECT_ATTRIBUTES
    {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LSA_UNICODE_STRING
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [DllImport("advapi32.dll")]
    private static extern uint LsaOpenPolicy(
        IntPtr SystemName,
        ref LSA_OBJECT_ATTRIBUTES ObjectAttributes,
        uint DesiredAccess,
        out IntPtr PolicyHandle);

    [DllImport("advapi32.dll")]
    private static extern uint LsaAddAccountRights(
        IntPtr PolicyHandle,
        IntPtr AccountSid,
        LSA_UNICODE_STRING[] UserRights,
        uint CountOfRights);

    [DllImport("advapi32.dll")]
    private static extern uint LsaEnumerateAccountRights(
        IntPtr PolicyHandle,
        IntPtr AccountSid,
        out IntPtr UserRights,
        out uint CountOfRights);

    [DllImport("advapi32.dll")]
    private static extern uint LsaNtStatusToWinError(uint Status);

    [DllImport("advapi32.dll")]
    private static extern uint LsaFreeMemory(IntPtr Buffer);

    [DllImport("advapi32.dll")]
    private static extern uint LsaClose(IntPtr ObjectHandle);

    private static IntPtr OpenPolicy()
    {
        const uint POLICY_CREATE_ACCOUNT = 0x00000010;
        const uint POLICY_LOOKUP_NAMES = 0x00000800;
        LSA_OBJECT_ATTRIBUTES attributes = new LSA_OBJECT_ATTRIBUTES();
        attributes.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr policy;
        uint status = LsaOpenPolicy(
            IntPtr.Zero,
            ref attributes,
            POLICY_CREATE_ACCOUNT | POLICY_LOOKUP_NAMES,
            out policy);
        if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
        return policy;
    }

    private static IntPtr CopySid(SecurityIdentifier sid)
    {
        byte[] bytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(bytes, 0);
        IntPtr pointer = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        return pointer;
    }

    public static void EnsureBatchLogon(SecurityIdentifier sid)
    {
        IntPtr policy = OpenPolicy();
        IntPtr sidPointer = CopySid(sid);
        IntPtr rightBuffer = Marshal.StringToHGlobalUni("SeBatchLogonRight");
        try
        {
            LSA_UNICODE_STRING right = new LSA_UNICODE_STRING();
            right.Buffer = rightBuffer;
            right.Length = (ushort)("SeBatchLogonRight".Length * 2);
            right.MaximumLength = (ushort)(right.Length + 2);
            uint status = LsaAddAccountRights(policy, sidPointer, new[] { right }, 1);
            if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
        }
        finally
        {
            Marshal.FreeHGlobal(rightBuffer);
            Marshal.FreeHGlobal(sidPointer);
            LsaClose(policy);
        }
    }

    public static bool HasBatchLogon(SecurityIdentifier sid)
    {
        const uint STATUS_OBJECT_NAME_NOT_FOUND = 0xC0000034;
        IntPtr policy = OpenPolicy();
        IntPtr sidPointer = CopySid(sid);
        try
        {
            IntPtr rightsPointer;
            uint count;
            uint status = LsaEnumerateAccountRights(policy, sidPointer, out rightsPointer, out count);
            if (status == STATUS_OBJECT_NAME_NOT_FOUND) return false;
            if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
            try
            {
                int size = Marshal.SizeOf(typeof(LSA_UNICODE_STRING));
                for (uint index = 0; index < count; index++)
                {
                    IntPtr current = new IntPtr(rightsPointer.ToInt64() + index * size);
                    LSA_UNICODE_STRING value = (LSA_UNICODE_STRING)Marshal.PtrToStructure(
                        current, typeof(LSA_UNICODE_STRING));
                    string name = Marshal.PtrToStringUni(value.Buffer, value.Length / 2);
                    if (String.Equals(name, "SeBatchLogonRight", StringComparison.Ordinal)) return true;
                }
                return false;
            }
            finally { LsaFreeMemory(rightsPointer); }
        }
        finally
        {
            Marshal.FreeHGlobal(sidPointer);
            LsaClose(policy);
        }
    }
}
'@
}

[SkyrimDeployBatchRight]::EnsureBatchLogon($User.SID)
if (-not [SkyrimDeployBatchRight]::HasBatchLogon($User.SID)) {
    throw 'SeBatchLogonRight readback failed'
}
Write-Host "SeBatchLogonRight present for ${env:COMPUTERNAME}\$AccountName ($ExpectedSid)"
