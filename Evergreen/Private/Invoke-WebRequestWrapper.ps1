function Invoke-WebRequestWrapper {
    <#
        .SYNOPSIS
            Validates and return responses from Invoke-WebRequest
            Enables normalisation for all public functions and across PowerShell/Windows PowerShell
            Some validation of $Uri is expected before passing to this function

            TODO: Add proxy support
    #>
    [OutputType([Microsoft.PowerShell.Commands.WebResponseObject])]
    [CmdletBinding(SupportsShouldProcess = $True)]
    param (
        [Parameter(Mandatory = $True, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [System.String] $Uri,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String] $ContentType,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [System.Collections.Hashtable] $Headers,

        [Parameter()]
        [ValidateSet("Default", "Get", "Head", "Post")]
        [System.String] $Method = "Default",

        [Parameter()]
        [ValidateSet("Default", "Tls", "Tls11", "Tls12", "Tls13")]
        [System.String] $SslProtocol = "Tls12",

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [System.String] $UserAgent = [Microsoft.PowerShell.Commands.PSUserAgent]::Chrome,

        [Parameter()]
        [System.Management.Automation.SwitchParameter] $Raw,

        [Parameter()]
        [System.Management.Automation.SwitchParameter] $SkipCertificateCheck,

        [Parameter()]
        [ValidateSet("Content", "RawContent", "Headers", "All")]
        [System.String] $ReturnObject = "Content"
    )

    # Disable the Invoke-WebRequest progress bar for faster downloads
    if ($PSBoundParameters.ContainsKey('Verbose')) {
        $ProgressPreference = [System.Management.Automation.ActionPreference]::Continue
    }
    else {
        $ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
    }

    # PowerShell 5.1: Trust certificate used by the remote server (typically self-sign certs)
    # PowerShell Core will use -SkipCertificateCheck
    if ($PSBoundParameters.ContainsKey("SkipCertificateCheck") -and -not(Test-PSCore)) {
        Write-Verbose -Message "$($MyInvocation.MyCommand): Creating class TrustAllCertsPolicy."
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object -TypeName "TrustAllCertsPolicy"
    }

    # Use TLS for connections
    if ($PSBoundParameters.ContainsKey("SslProtocol") -and -not(Test-PSCore)) {
        if ($SslProtocol -eq "Tls13") {
            $SslProtocol = "Tls12"
            Write-Warning -Message "$($MyInvocation.MyCommand): Defaulting back to TLS1.2."
        }
        Write-Verbose -Message "$($MyInvocation.MyCommand): Settings Net.SecurityProtocolType to $SslProtocol."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::$SslProtocol
    }

    #region Set Invoke-WebRequest parameters
    $iwrParams = @{
        Uri             = $Uri
        Method          = $Method
        UserAgent       = $UserAgent
        UseBasicParsing = $True
    }

    # Set additional parameters
    if ($PSBoundParameters.ContainsKey("ContentType")) {
        Write-Verbose -Message "$($MyInvocation.MyCommand): Adding ContentType."
        $iwrParams.ContentType = $ContentType
    }
    if ($PSBoundParameters.ContainsKey("Headers")) {
        Write-Verbose -Message "$($MyInvocation.MyCommand): Adding Headers."
        $iwrParams.Headers = $Headers
    }
    if ($PSBoundParameters.ContainsKey("SkipCertificateCheck") -and (Test-PSCore)) {
        Write-Verbose -Message "$($MyInvocation.MyCommand): Adding SkipCertificateCheck."
        $iwrParams.SkipCertificateCheck = $True
    }
    if ($PSBoundParameters.ContainsKey("SslProtocol") -and (Test-PSCore)) {
        Write-Verbose -Message "$($MyInvocation.MyCommand): Adding SslProtocol."
        $iwrParams.SslProtocol = $SslProtocol
    }
    if ($PSBoundParameters.ContainsKey("Raw")) {
        $tempFile = New-TemporaryFile -WhatIf:$WhatIfPreference
        $iwrParams.OutFile = $tempFile
        $iwrParams.PassThru = $True
        Write-Verbose -Message "$($MyInvocation.MyCommand): Using temp file $tempFile."
    }
    if (Test-ProxyEnv) {
        $iwrParams.Proxy = $script:EvergreenProxy
    }
    if (Test-ProxyEnv -Creds) {
        $iwrParams.ProxyCredential = $script:EvergreenProxyCreds
    }
    foreach ($item in $iwrParams.GetEnumerator()) {
        Write-Verbose -Message "$($MyInvocation.MyCommand): Invoke-WebRequest parameter: [$($item.name): $($item.value)]."
    }
    #endregion

    # Call Invoke-WebRequest
    try {
        if ($PSCmdlet.ShouldProcess($Uri, "Invoke-WebRequest")) {
            $Response = Invoke-WebRequest @iwrParams
        }
    }
    catch {
        Write-Warning -Message "$($MyInvocation.MyCommand): Error at URI: $Uri."
        Write-Warning -Message "$($MyInvocation.MyCommand): Error encountered: $($_.Exception.Message)."
        Write-Warning -Message "$($MyInvocation.MyCommand): For troubleshooting steps see: $($script:resourceStrings.Uri.Info)."
        Write-Error -Message "$($MyInvocation.MyCommand): $($_.Exception.Message)."
    }

    if ($Null -ne $Response) {
        Write-Verbose -Message "$($MyInvocation.MyCommand): Response: [$($Response.StatusCode)]."
        Write-Verbose -Message "$($MyInvocation.MyCommand): Content type: [$($Response.Headers.'Content-Type')]."

        # Output content from the response
        switch ($ReturnObject) {
            "All" {
                Write-Verbose -Message "$($MyInvocation.MyCommand): Returning entire response."
                Write-Output -InputObject $Response
                break
            }
            "Headers" {
                Write-Verbose -Message "$($MyInvocation.MyCommand): Returning headers."
                Write-Output -InputObject $Response.Headers
                break
            }
            "RawContent" {
                Write-Verbose -Message "$($MyInvocation.MyCommand): Returning raw content of length: [$($Response.RawContent.Length)]."
                Write-Output -InputObject $Response.RawContent
                break
            }
            "Content" {
                if ($PSBoundParameters.ContainsKey("Raw")) {
                    $Content = Get-Content -Path $TempFile
                }
                else {
                    $Content = $Response.Content
                }
                Write-Verbose -Message "$($MyInvocation.MyCommand): Returning content of length: [$($Content.Length)]."
                Write-Output -InputObject $Content
                break
            }
            default {
                if ($PSBoundParameters.ContainsKey("Raw")) {
                    $Content = Get-Content -Path $TempFile
                }
                else {
                    $Content = $Response.Content
                }
                Write-Verbose -Message "$($MyInvocation.MyCommand): Returning content of length: [$($Content.Length)]."
                Write-Output -InputObject $Content
            }
        }
    }
}
