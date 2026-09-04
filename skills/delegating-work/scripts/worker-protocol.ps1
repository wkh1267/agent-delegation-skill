$script:DelegentNormalFields = @(
    'status',
    'summary',
    'evidence',
    'changes',
    'tests',
    'risks',
    'decisions_needed',
    'review_targets'
)
$script:DelegentDecisionFields = @(
    'kind',
    'question',
    'evidence',
    'options',
    'recommendation',
    'confidence'
)

function New-DelegentProtocolError {
    param(
        [ValidateSet('missing_terminal_handoff', 'malformed_handoff', 'timeout', 'runtime_output_error')]
        [string]$Kind,
        [string]$SessionId,
        [Nullable[int]]$ExitCode
    )

    $summaries = @{
        missing_terminal_handoff = 'Supported session sources contained no terminal structured result.'
        malformed_handoff        = 'The terminal structured result did not match the Worker protocol.'
        timeout                  = 'The Worker did not produce a terminal structured result before the timeout.'
        runtime_output_error     = 'The Worker runtime or session API failed.'
    }
    $safeSessionId = if ($SessionId -match '^[A-Za-z0-9_.-]{1,128}$') { $SessionId } else { 'none' }
    $safeExitCode = if ($null -ne $ExitCode) { [string]$ExitCode } else { 'none' }
    $output = @(
        'WORKER_PROTOCOL_ERROR'
        "kind: $Kind"
        "session_id: $safeSessionId"
        "exit_code: $safeExitCode"
        "summary: $($summaries[$Kind])"
    ) -join [Environment]::NewLine

    [pscustomobject]@{ ExitCode = 1; Output = $output }
}

function ConvertFrom-DelegentUniqueJson {
    param([AllowEmptyString()][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw [FormatException]::new('Empty JSON.')
    }

    try {
        Add-Type -AssemblyName System.Runtime.Serialization -ErrorAction SilentlyContinue
        $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
        $reader = [Runtime.Serialization.Json.JsonReaderWriterFactory]::CreateJsonReader(
            $bytes,
            [Xml.XmlDictionaryReaderQuotas]::Max
        )
        $document = New-Object Xml.XmlDocument
        $document.Load($reader)
        foreach ($objectNode in @($document.SelectNodes('//*[@type="object"]'))) {
            $seen = @{}
            foreach ($child in @($objectNode.ChildNodes | Where-Object NodeType -eq Element)) {
                if ($seen.ContainsKey($child.LocalName)) {
                    throw [FormatException]::new('Duplicate JSON property.')
                }
                $seen[$child.LocalName] = $true
            }
        }

        return $Json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw [FormatException]::new('Invalid or ambiguous JSON.')
    }
}

function Test-DelegentExactFields {
    param(
        [object]$Value,
        [string[]]$Expected
    )

    if ($null -eq $Value -or $Value -is [string]) { return $false }
    $actual = @($Value.PSObject.Properties | ForEach-Object Name)
    if ($actual.Count -ne $Expected.Count) { return $false }
    foreach ($name in $Expected) {
        if ($actual -cnotcontains $name) { return $false }
        $fieldValue = $Value.PSObject.Properties[$name].Value
        if ($fieldValue -isnot [string] -or [string]::IsNullOrWhiteSpace($fieldValue)) { return $false }
    }
    return $true
}

function Test-DelegentSensitiveContent {
    param(
        [string]$Content,
        [string[]]$SensitiveValues
    )

    foreach ($value in @($SensitiveValues)) {
        if (-not [string]::IsNullOrWhiteSpace($value) -and
            $Content.IndexOf($value, [StringComparison]::Ordinal) -ge 0) {
            return $true
        }
    }
    return $false
}

function ConvertTo-DelegentLeadOutput {
    param(
        [object]$StructuredOutput,
        [string[]]$SensitiveValues = @()
    )

    $isDecision = $null -ne $StructuredOutput.PSObject.Properties['kind']
    if ($isDecision) {
        if (-not (Test-DelegentExactFields $StructuredOutput $script:DelegentDecisionFields) -or
            $StructuredOutput.kind -cne 'decision_needed') {
            return New-DelegentProtocolError -Kind malformed_handoff
        }

        $output = @(
            'DECISION_NEEDED'
            'Question:'
            $StructuredOutput.question
            'Evidence:'
            $StructuredOutput.evidence
            'Options:'
            $StructuredOutput.options
            'Recommendation:'
            $StructuredOutput.recommendation
            'Confidence:'
            $StructuredOutput.confidence
        ) -join [Environment]::NewLine
        if (Test-DelegentSensitiveContent $output $SensitiveValues) {
            return New-DelegentProtocolError -Kind runtime_output_error
        }
        return [pscustomobject]@{ ExitCode = 0; Output = $output }
    }

    if (-not (Test-DelegentExactFields $StructuredOutput $script:DelegentNormalFields) -or
        $StructuredOutput.status -cnotin @('completed', 'blocked')) {
        return New-DelegentProtocolError -Kind malformed_handoff
    }

    $output = @(
        "STATUS: $($StructuredOutput.status)"
        'SUMMARY:'
        $StructuredOutput.summary
        'EVIDENCE:'
        $StructuredOutput.evidence
        'CHANGES:'
        $StructuredOutput.changes
        'TESTS:'
        $StructuredOutput.tests
        'RISKS:'
        $StructuredOutput.risks
        'DECISIONS_NEEDED:'
        $StructuredOutput.decisions_needed
        'REVIEW_TARGETS:'
        $StructuredOutput.review_targets
    ) -join [Environment]::NewLine
    if (Test-DelegentSensitiveContent $output $SensitiveValues) {
        return New-DelegentProtocolError -Kind runtime_output_error
    }
    [pscustomobject]@{ ExitCode = 0; Output = $output }
}

function Resolve-DelegentOpenCodeServer {
    param([string]$CommandSource)

    $extension = [IO.Path]::GetExtension($CommandSource)
    if ($extension -in @('.ps1', '.cmd', '.bat')) {
        $CommandSource = Join-Path (Split-Path $CommandSource -Parent) 'node_modules\opencode-ai\bin\opencode.exe'
    }
    if ([IO.Path]::GetExtension($CommandSource) -ine '.exe' -or
        -not (Test-Path -LiteralPath $CommandSource -PathType Leaf)) {
        throw [InvalidOperationException]::new('A native OpenCode server executable is required.')
    }
    (Resolve-Path -LiteralPath $CommandSource).Path
}

function Initialize-DelegentServerJob {
    if (-not ('DelegentProcessJob' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class DelegentProcessJob {
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits {
        public BasicLimits BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static IntPtr Create() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        var limits = new ExtendedLimits();
        limits.BasicLimitInformation.LimitFlags = 0x00002000;
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(limits))) {
            int error = Marshal.GetLastWin32Error();
            CloseHandle(job);
            throw new Win32Exception(error);
        }
        return job;
    }

    public static void Assign(IntPtr job, IntPtr process) {
        if (!AssignProcessToJobObject(job, process)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public static void Close(IntPtr job) {
        if (job != IntPtr.Zero) CloseHandle(job);
    }
}
'@ -Language CSharp -ErrorAction Stop
    }
}

function New-DelegentServerJob {
    param([Diagnostics.Process]$Process)

    Initialize-DelegentServerJob
    $job = [DelegentProcessJob]::Create()
    try {
        [DelegentProcessJob]::Assign($job, $Process.Handle)
        return $job
    }
    catch {
        [DelegentProcessJob]::Close($job)
        throw
    }
}

function Stop-DelegentServerProcess {
    param(
        [Diagnostics.Process]$Process,
        [IntPtr]$Job = [IntPtr]::Zero
    )

    if ($Job -ne [IntPtr]::Zero) { [DelegentProcessJob]::Close($Job) }
    if ($null -eq $Process -or $Process.HasExited) { return }
    if (-not $Process.WaitForExit(5000)) {
        $Process.Kill()
        $Process.WaitForExit(5000) | Out-Null
    }
}

function Get-DelegentWorkerSchema {
    $string = @{ type = 'string'; minLength = 1 }
    $normalProperties = [ordered]@{}
    foreach ($name in $script:DelegentNormalFields) {
        $normalProperties[$name] = $string.Clone()
    }
    $normalProperties.status = @{ type = 'string'; enum = @('completed', 'blocked') }

    $decisionProperties = [ordered]@{}
    foreach ($name in $script:DelegentDecisionFields) {
        $decisionProperties[$name] = $string.Clone()
    }
    $decisionProperties.kind = @{ type = 'string'; enum = @('decision_needed') }

    @{
        type = 'object'
        oneOf = @(
            @{
                type = 'object'
                properties = $normalProperties
                required = $script:DelegentNormalFields
                additionalProperties = $false
            },
            @{
                type = 'object'
                properties = $decisionProperties
                required = $script:DelegentDecisionFields
                additionalProperties = $false
            }
        )
    }
}

function Get-DelegentWorkerInvocation {
    param([object[]]$Arguments)

    $values = @{}
    $promptParts = New-Object Collections.Generic.List[string]
    $afterDelimiter = $false
    $aliases = @{ '-s' = 'session'; '--session' = 'session'; '--title' = 'title'; '--agent' = 'agent'; '--dir' = 'dir' }

    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = [string]$Arguments[$index]
        if ($afterDelimiter) {
            $promptParts.Add($argument)
            continue
        }
        if ($argument -eq '--') {
            $afterDelimiter = $true
            continue
        }

        $name = $null
        $value = $null
        if ($aliases.ContainsKey($argument)) {
            $name = $aliases[$argument]
            if (++$index -ge $Arguments.Count) { throw [ArgumentException]::new('Missing option value.') }
            $value = [string]$Arguments[$index]
        }
        elseif ($argument -match '^--(session|title|agent|dir)=(.*)$') {
            $name = $Matches[1]
            $value = $Matches[2]
        }
        elseif ($argument.StartsWith('-')) {
            throw [ArgumentException]::new('Unsupported Worker option.')
        }
        else {
            $promptParts.Add($argument)
            continue
        }

        if ($values.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($value)) {
            throw [ArgumentException]::new('Invalid Worker option.')
        }
        $values[$name] = $value
    }

    $prompt = ($promptParts -join ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($prompt)) { throw [ArgumentException]::new('Missing Worker task.') }

    [pscustomobject]@{
        Session = $values.session
        Title   = $values.title
        Agent   = $values.agent
        Dir     = $values.dir
        Prompt  = $prompt
    }
}

function Test-DelegentTimeoutError {
    param([Management.Automation.ErrorRecord]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [TimeoutException]) { return $true }
        if ($exception -is [Net.WebException] -and $exception.Status -eq [Net.WebExceptionStatus]::Timeout) {
            return $true
        }
        $exception = $exception.InnerException
    }
    return $false
}

function Get-DelegentStructuredOutput {
    param([object]$Message)

    if ($null -eq $Message) { return $null }
    $info = $Message.PSObject.Properties['info'].Value
    if ($null -eq $info -or [string]$info.role -cne 'assistant') { return $null }
    if ($null -ne $info.PSObject.Properties['error'] -and $null -ne $info.error) {
        throw [InvalidOperationException]::new('Worker runtime error.')
    }
    # OpenCode message schemas use `structured`; older SDK docs used
    # `structured_output`. Accept either source, never both.
    $structuredNames = @(@('structured', 'structured_output') | Where-Object {
        $null -ne $info.PSObject.Properties[$_]
    })
    if ($structuredNames.Count -gt 1) {
        throw [FormatException]::new('Ambiguous structured result.')
    }
    if ($structuredNames.Count -eq 0) { return $null }
    return $info.PSObject.Properties[$structuredNames[0]].Value
}

function Invoke-DelegentWorkerProtocol {
    param(
        [object]$Invocation,
        [scriptblock]$Request,
        [string[]]$SensitiveValues = @(),
        [ValidateRange(1, 86400)][int]$PromptTimeoutSeconds = 300,
        [ValidateRange(1, 60)][int]$RecoveryTimeoutSeconds = 5
    )

    $sessionId = [string]$Invocation.Session
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        try {
            $createBody = if ($Invocation.Title) { @{ title = $Invocation.Title } } else { @{} }
            $createJson = & $Request 'POST' '/session' ($createBody | ConvertTo-Json -Compress) $RecoveryTimeoutSeconds
            $created = ConvertFrom-DelegentUniqueJson $createJson
            $sessionId = [string]$created.id
            if ([string]::IsNullOrWhiteSpace($sessionId)) { throw [FormatException]::new('Missing session ID.') }
        }
        catch {
            return New-DelegentProtocolError -Kind runtime_output_error
        }
    }

    $sessionPathId = [Uri]::EscapeDataString($sessionId)
    $baselineIds = @{}
    $canRecover = -not $Invocation.Session
    if ($Invocation.Session) {
        try {
            $baselineJson = & $Request 'GET' "/session/$sessionPathId/message" $null $RecoveryTimeoutSeconds
            foreach ($message in @(ConvertFrom-DelegentUniqueJson $baselineJson)) {
                if ($null -ne $message.info -and $message.info.role -ceq 'assistant') {
                    if (-not $message.info.id) { throw [FormatException]::new('Unidentifiable baseline message.') }
                    $baselineIds[[string]$message.info.id] = $true
                }
            }
            $canRecover = $true
        }
        catch {
            $canRecover = $false
        }
    }

    $body = [ordered]@{
        model = @{ providerID = 'nvidia'; modelID = 'nvidia/nemotron-3-super-120b-a12b' }
        parts = @(@{ type = 'text'; text = $Invocation.Prompt })
        format = @{ type = 'json_schema'; schema = Get-DelegentWorkerSchema; retryCount = 2 }
    }
    if ($Invocation.Agent) { $body.agent = $Invocation.Agent }

    $timedOut = $false
    $primaryJson = $null
    try {
        $primaryJson = & $Request 'POST' "/session/$sessionPathId/message" ($body | ConvertTo-Json -Depth 20 -Compress) $PromptTimeoutSeconds
    }
    catch {
        if (Test-DelegentTimeoutError $_) {
            $timedOut = $true
        }
        else {
            return New-DelegentProtocolError -Kind runtime_output_error -SessionId $sessionId
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($primaryJson)) {
        try {
            $primary = ConvertFrom-DelegentUniqueJson $primaryJson
            $structured = Get-DelegentStructuredOutput $primary
            if ($null -ne $structured) {
                return ConvertTo-DelegentLeadOutput $structured $SensitiveValues
            }
        }
        catch [InvalidOperationException] {
            return New-DelegentProtocolError -Kind runtime_output_error -SessionId $sessionId
        }
        catch {
            return New-DelegentProtocolError -Kind malformed_handoff -SessionId $sessionId
        }
    }

    if ($canRecover) {
        try {
            $messagesJson = & $Request 'GET' "/session/$sessionPathId/message" $null $RecoveryTimeoutSeconds
            $messages = @(ConvertFrom-DelegentUniqueJson $messagesJson)
            for ($index = $messages.Count - 1; $index -ge 0; $index--) {
                $message = $messages[$index]
                $messageId = if ($null -ne $message.info) { [string]$message.info.id } else { '' }
                if ($baselineIds.ContainsKey($messageId)) { continue }
                $structured = Get-DelegentStructuredOutput $message
                if ($null -ne $structured) {
                    return ConvertTo-DelegentLeadOutput $structured $SensitiveValues
                }
            }
        }
        catch [InvalidOperationException] {
            return New-DelegentProtocolError -Kind runtime_output_error -SessionId $sessionId
        }
        catch {
            return New-DelegentProtocolError -Kind malformed_handoff -SessionId $sessionId
        }
    }

    if ($timedOut) {
        try { $null = & $Request 'POST' "/session/$sessionPathId/abort" '{}' $RecoveryTimeoutSeconds } catch {}
        return New-DelegentProtocolError -Kind timeout -SessionId $sessionId
    }
    New-DelegentProtocolError -Kind missing_terminal_handoff -SessionId $sessionId
}
