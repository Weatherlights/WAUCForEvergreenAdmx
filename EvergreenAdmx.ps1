﻿#Requires -RunAsAdministrator

<#PSScriptInfo

.VERSION 2301.2

.GUID 999952b7-1337-4018-a1b9-499fad48e734

.AUTHOR Arjan Mensch & Jonathan Pitre

.COMPANYNAME IT-WorXX

.TAGS GroupPolicy GPO Admx Evergreen Automation

.LICENSEURI https://github.com/msfreaks/EvergreenAdmx/blob/main/LICENSE

.PROJECTURI https://github.com/msfreaks/EvergreenAdmx

#>

<#
.SYNOPSIS
 Script to automatically download latest Admx files for several products.

.DESCRIPTION
 Script to automatically download latest Admx files for several products.
 Optionally copies the latest Admx files to a folder of your chosing, for example a Policy Store.

.PARAMETER Windows10Version
 The Windows 10 version to get the Admx files for.
 If omitted the newest version supported by this script will be used.

.PARAMETER Windows11Version
 The Windows 11 version to get the Admx files for.
 If omitted the newest version supported by this script will be used.

.PARAMETER WorkingDirectory
 Optionally provide a Working Directory for the script.
 The script will store Admx files in a subdirectory called "admx".
 The script will store downloaded files in a subdirectory called "downloads".
 If omitted the script will treat the script's folder as the working directory.

.PARAMETER PolicyStore
 Optionally provide a Policy Store location to copy the Admx files to after processing.

.PARAMETER Languages
 Optionally provide an array of languages to process. Entries must be in 'xy-XY' format.
 If omitted the script will process 'en-US'.

.PARAMETER UseProductFolders
 When specified the extracted Admx files are copied to their respective product folders in a subfolder of 'Admx' in the WorkingDirectory.

.PARAMETER CustomPolicyStore
 When specified processes a location for custom policy files. Can be UNC format or local folder.
 The script will expect to find .admx files in this location, and at least one language folder holding the .adml file(s).
 Versioning will be done based on the newest file found recursively in this location (any .admx or .adml).
 Note that if any file has changed the script will process all files found in location.

.PARAMETER Include
 Array containing Admx products to include when checking for updates.
 Defaults to "Windows 11", "Microsoft Edge", "Microsoft OneDrive", "Microsoft Office" if omitted.

.PARAMETER PreferLocalOneDrive
 Microsoft OneDrive Admx files are only available after installing OneDrive.
 If this script is running on a machine that has OneDrive installed locally, use this switch to prevent automatically uninstalling OneDrive.

.EXAMPLE
 .\EvergreenAdmx.ps1 -Windows10Version "22H2" -PolicyStore "C:\Windows\SYSVOL\domain\Policies\PolicyDefinitions" -Languages @("en-US", "nl-NL") -UseProductFolders
 Will process the default set of products, storing results in product folders, for both English United States as Dutch languages, and copies the files to the Policy store.

.LINK
 https://github.com/msfreaks/EvergreenAdmx
 https://msfreaks.wordpress.com

#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $False)][ValidateSet("1903", "1909", "2004", "20H2", "21H1", "21H2", "22H2")]
    [System.String] $Windows10Version = "22H2",
    [Parameter(Mandatory = $False)][ValidateSet("21H2", "22H2")]
    [System.String] $Windows11Version = "22H2",
    [Parameter(Mandatory = $False)]
    [System.String] $WorkingDirectory = $null,
    [Parameter(Mandatory = $False)]
    [System.String] $PolicyStore = $null,
    [Parameter(Mandatory = $False)]
    [System.String[]] $Languages = @("en-US"),
    [Parameter(Mandatory = $False)]
    [switch] $UseProductFolders,
    [Parameter(Mandatory = $False)]
    [System.String] $CustomPolicyStore = $null,
    [Parameter(Mandatory = $False)][ValidateSet("Custom Policy Store", "Windows 10", "Windows 11", "Microsoft Edge", "Microsoft OneDrive", "Microsoft Office", "FSLogix", "Adobe Acrobat", "Adobe Reader", "BIS-F", "Citrix Workspace App", "Google Chrome", "Microsoft Desktop Optimization Pack", "Mozilla Firefox", "Zoom Desktop Client")]
    [System.String[]] $Include = @("Windows 11", "Microsoft Edge", "Microsoft OneDrive", "Microsoft Office"),
    [Parameter(Mandatory = $False)]
    [switch] $PreferLocalOneDrive = $false
)

#region init

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "SilentlyContinue"

$admxversions = $null
if (-not $WorkingDirectory) { $WorkingDirectory = $PSScriptRoot }
if (Test-Path -Path "$($WorkingDirectory)\admxversions.xml") { $admxversions = Import-Clixml -Path "$($WorkingDirectory)\admxversions.xml" }
if (-not (Test-Path -Path "$($WorkingDirectory)\admx")) { $null = New-Item -Path "$($WorkingDirectory)\admx" -ItemType Directory -Force }
if (-not (Test-Path -Path "$($WorkingDirectory)\downloads")) { $null = New-Item -Path "$($WorkingDirectory)\downloads" -ItemType Directory -Force }
if ($PolicyStore -and -not $PolicyStore.EndsWith("\")) { $PolicyStore += "\" }
if ($Languages -notmatch "([A-Za-z]{2})-([A-Za-z]{2})$") { Write-Warning "Language not in expected format: $($Languages -notmatch "([A-Za-z]{2})-([A-Za-z]{2})$")" }
if ($CustomPolicyStore -and -not (Test-Path -Path "$($CustomPolicyStore)")) { throw "'$($CustomPolicyStore)' is not a valid path." }
if ($CustomPolicyStore -and -not $CustomPolicyStore.EndsWith("\")) { $CustomPolicyStore += "\" }
if ($CustomPolicyStore -and (Get-ChildItem -Path $CustomPolicyStore -Directory) -notmatch "([A-Za-z]{2})-([A-Za-z]{2})$") { throw "'$($CustomPolicyStore)' does not contain at least one subfolder matching the language format (e.g 'en-US')." }
if ($PreferLocalOneDrive -and $Include -notcontains "Microsoft OneDrive") { Write-Warning "PreferLocalOneDrive is used, but Microsoft OneDrive is not in the list of included products to process." }
$oneDriveADMXFolder = $null
if ((Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\OneDrive").CurrentVersionPath)
{
    $oneDriveADMXFolder = (Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\OneDrive").CurrentVersionPath
}
if ((Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\OneDrive").CurrentVersionPath)
{
    $oneDriveADMXFolder = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\OneDrive").CurrentVersionPath
}
if ($PreferLocalOneDrive -and $Include -contains "Microsoft OneDrive" -and $null -eq $oneDriveADMXFolder)
{
    throw "PreferLocalOneDrive will only work if OneDrive is machine installed. User installed OneDrive is not supported.`nLocal machine installed OneDrive not found."
    break
}
Write-Verbose "Windows 10 Version:`t'$($Windows10Version)'"
Write-Verbose "Windows 11 Version:`t'$($Windows11Version)'"
Write-Verbose "WorkingDirectory:`t`t'$($WorkingDirectory)'"
Write-Verbose "PolicyStore:`t`t`t'$($PolicyStore)'"
Write-Verbose "CustomPolicyStore:`t`t'$($CustomPolicyStore)'"
Write-Verbose "Languages:`t`t`t`t'$($Languages)'"
Write-Verbose "Use product folders:`t'$($UseProductFolders)'"
Write-Verbose "Admx path:`t`t`t`t'$($WorkingDirectory)\admx'"
Write-Verbose "Download path:`t`t`t'$($WorkingDirectory)\downloads'"
Write-Verbose "Included:`t`t`t`t'$($Include -join ',')'"
Write-Verbose "PreferLocalOneDrive:`t'$($PreferLocalOneDrive)'"

#endregion

#region functions
function Get-WindowsAdmxDownloadId
{
    <#
    .SYNOPSIS
    Returns download Id for Admx file based on Windows 10 version

    .PARAMETER WindowsVersion
    Official WindowsVersion format
#>

    param (
        [string]$WindowsVersion,
        [int]$WindowsEdition
    )

    switch ($WindowsEdition)
    {
        10
        {
            return (@( @{ "1903" = "58495" }, @{ "1909" = "100591" }, @{ "2004" = "101445" }, @{ "20H2" = "102157" }, @{ "21H1" = "103124" }, @{ "21H2" = "104042" }, @{ "22H2" = "104677" } ).$WindowsVersion)
            break
        }
        11
        {
            return (@( @{ "21H2" = "103507" }, @{ "22H2" = "104593" } ).$WindowsVersion)
            break
        }
    }
}

function Copy-Admx
{
    param (
        [string]$SourceFolder,
        [string]$TargetFolder,
        [string]$PolicyStore = $null,
        [string]$ProductName,
        [switch]$Quiet,
        [string[]]$Languages = $null
    )
    if (-not (Test-Path -Path "$($TargetFolder)")) { $null = (New-Item -Path "$($TargetFolder)" -ItemType Directory -Force) }
    if (-not $Languages -or $Languages -eq "") { $Languages = @('en-US') }

    Write-Verbose "Copying Admx files from '$($SourceFolder)' to '$($TargetFolder)'"
    Copy-Item -Path "$($SourceFolder)\*.admx" -Destination "$($TargetFolder)" -Force
    foreach ($language in $Languages)
    {
        if (-not (Test-Path -Path "$($SourceFolder)\$($language)"))
        {
            Write-Verbose "$($language) not found"
            if (-not $Quiet) { Write-Warning "Language '$($language)' not found for '$($ProductName)'. Processing 'en-US' instead." }
            $language = "en-US"
        }
        if (-not (Test-Path -Path "$($TargetFolder)\$($language)"))
        {
            Write-Verbose "'$($TargetFolder)\$($language)' does not exist, creating folder"
            $null = (New-Item -Path "$($TargetFolder)\$($language)" -ItemType Directory -Force)
        }
        Write-Verbose "Copying '$($SourceFolder)\$($language)\*.adml' to '$($TargetFolder)\$($language)'"
        Copy-Item -Path "$($SourceFolder)\$($language)\*.adml" -Destination "$($TargetFolder)\$($language)" -Force
    }
    if ($PolicyStore)
    {
        Write-Verbose "Copying Admx files from '$($SourceFolder)' to '$($PolicyStore)'"
        Copy-Item -Path "$($SourceFolder)\*.admx" -Destination "$($PolicyStore)" -Force
        foreach ($language in $Languages)
        {
            if (-not (Test-Path -Path "$($SourceFolder)\$($language)")) { $language = "en-US" }
            if (-not (Test-Path -Path "$($PolicyStore)$($language)")) { $null = (New-Item -Path "$($PolicyStore)$($language)" -ItemType Directory -Force) }
            Copy-Item -Path "$($SourceFolder)\$($language)\*.adml" -Destination "$($PolicyStore)$($language)" -Force
        }
    }
}

function Get-FSLogixOnline
{
    <#
    .SYNOPSIS
    Returns latest Version and Uri for FSLogix
#>

    try
    {
        # grab URI (redirected url)
        $URI = Get-RedirectedUrl -Url 'https://aka.ms/fslogix/download'
        # grab version
        $Version = ($URI.Split("/")[-1] | Select-String -Pattern "(\d+(\.\d+){1,4})" -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value }).ToString()

        # return evergreen object
        return @{ Version = $Version; URI = $URI }
    }
    catch
    {
        Throw $_
    }
}

function Get-RedirectedUrl
{
    param (
        [Parameter(Mandatory = $true)]
        [String]$Url
    )

    $request = [System.Net.WebRequest]::Create($url)
    $request.AllowAutoRedirect = $true

    try
    {
        $response = $request.GetResponse()
        $redirectedUrl = $response.ResponseUri.AbsoluteUri
        $response.Close()

        Write-Output -InputObject $redirectedUrl
    }

    catch
    {
        Throw $_
    }
}

function Get-MicrosoftOfficeAdmxOnline
{
    <#
    .SYNOPSIS
    Returns latest Version and Uri for the Office Admx files (both x64 and x86)
#>

    $id = "49030"
    $urlversion = "https://www.microsoft.com/en-us/download/details.aspx?id=$($id)"
    $urldownload = "https://www.microsoft.com/en-us/download/confirmation.aspx?id=$($id)"
    try
    {

        # load page for version scrape
        $web = Invoke-WebRequest -UseDefaultCredentials -UseBasicParsing -Uri $urlversion
        $str = ($web.ToString() -split "[`r`n]" | Select-String "Version:").ToString()
        # grab version
        $Version = ($str | Select-String -Pattern "(\d+(\.\d+){1,4})" -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value }).ToString()
        # load page for uri scrape
        $web = Invoke-WebRequest -UseDefaultCredentials -UseBasicParsing -Uri $urldownload -MaximumRedirection 0
        # grab x64 version
        $hrefx64 = $web.Links | Where-Object { $_.outerHTML -like "*click here to download manually*" -and $_.href -like "*.exe" -and $_.href -like "*x64*" } | Select-Object -First 1
        # grab x86 version
        $hrefx86 = $web.Links | Where-Object { $_.outerHTML -like "*click here to download manually*" -and $_.href -like "*.exe" -and $_.href -like "*x86*" } | Select-Object -First 1

        # return evergreen object
        return @( @{ Version = $Version; URI = $hrefx64.href; Architecture = "x64" }, @{ Version = $Version; URI = $hrefx86.href; Architecture = "x86" })
    }
    catch
    {
        Throw $_
    }
}

function Get-WindowsAdmxOnline
{
    <#
    <#
    .SYNOPSIS
    Returns latest Version and Uri for the Windows 10 or Windows 11 Admx files

    .PARAMETER DownloadId
    Id returned from Get-WindowsAdmxDownloadId
#>

    param(
        [string]$DownloadId
    )

    $urlversion = "https://www.microsoft.com/en-us/download/details.aspx?id=$($DownloadId)"
    $urldownload = "https://www.microsoft.com/en-us/download/confirmation.aspx?id=$($DownloadId)"
    try
    {

        # load page for version scrape
        $web = Invoke-WebRequest -UseDefaultCredentials -UseBasicParsing -Uri $urlversion
        $str = ($web.ToString() -split "[`r`n]" | Select-String "Version:").ToString()
        # grab version
        $Version = "$($DownloadId).$(($str | Select-String -Pattern "(\d+(\.\d+){1,4})" -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value }).ToString())"
        # load page for uri scrape
        $web = Invoke-WebRequest -UseDefaultCredentials -UseBasicParsing -Uri $urldownload -MaximumRedirection 0
        $href = $web.Links | Where-Object { $_.outerHTML -like "*click here to download manually*" -and $_.href -like "*.msi" } | Select-Object -First 1

        # return evergreen object
        return @{ Version = $Version; URI = $href.href }
    }
    catch
    {
        Throw $_
    }
}

function Get-OneDriveOnline
{
    <#
    .SYNOPSIS
    Returns latest Version and Uri for OneDrive
#>
    param (
        [bool]$PreferLocalOneDrive
    )

    if ($PreferLocalOneDrive)
    {
        if (Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\OneDrive")
        {
            $URI = "$((Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\OneDrive").CurrentVersionPath)"
            $Version = "$((Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\OneDrive").Version)"
        }
        if ((Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\OneDrive"))
        {
            $URI = "$((Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\OneDrive").CurrentVersionPath)"
            $Version = "$((Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\OneDrive").Version)"
        }

        return @{ Version = $Version; URI = $URI }
    }
    else
    {
        try
        {
            $url = "https://go.microsoft.com/fwlink/p/?LinkID=844652"
            # grab content without redirecting to the download
            $web = Invoke-WebRequest -UseDefaultCredentials -Uri $url -UseBasicParsing -MaximumRedirection 0
            # grab uri
            $URI = $web.Headers.Location
            # grab version
            $Version = ($URI | Select-String -Pattern "(\d+(\.\d+){1,4})" -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value }).ToString()

            # return evergreen object
            return @{ Version = $Version; URI = $URI }
        }
        catch
        {
            Throw $_
        }
    }
}

function Get-MicrosoftEdgePolicyOnline
{
    <#
    .SYNOPSIS
    Returns latest Version and Uri for the Microsoft Edge Admx files
#>

    try
    {

        $url = "https://edgeupdates.microsoft.com/api/products?view=enterprise"
        # grab json containing product info
        $json = Invoke-WebRequest -UseDefaultCredentials -Uri $url -UseBasicParsing -MaximumRedirection 0 | ConvertFrom-Json
        # filter out the newest release
        $release = ($json | Where-Object { $_.Product -like "Policy" }).Releases | Sort-Object ProductVersion -Descending | Select-Object -First 1
        # grab version
        $Version = $release.ProductVersion
        # grab uri
        $URI = $release.Artifacts[0].Location

        # return evergreen object
        return @{ Version = $Version; URI = $URI }
    }
    catch
    {
        Throw $_
    }

}

function Get-GoogleChromeAdmxOnline
{
    <#
    .SYNOPSIS
    Returns latest Version and Uri for the Google Chrome Admx files
#>

    try
    {

        $URI = "https://dl.google.com/dl/edgedl/chrome/policy/policy_templates.zip"
        # download the file
        Invoke-WebRequest -UseDefaultCredentials -Uri $URI -OutFile "$($env:TEMP)\policy_templates.zip"
        # extract the file
        Expand-Archive -Path "$($env:TEMP)\policy_templates.zip" -DestinationPath "$($env:TEMP)\chromeadmx" -Force

        # open the version file
        $versionfile = (Get-Content -Path "$($env:TEMP)\chromeadmx\VERSION").Split('=')
        $Version = "$($versionfile[1]).$($versionfile[3]).$($versionfile[5]).$($versionfile[7])"

        # cleanup
        Remove-Item -Path "$($env:TEMP)\policy_templates.zip" -Force
        Remove-Item -Path "$($env:TEMP)\chromeadmx" -Recurse -Force

        # return evergreen object
        return @{ Version = $Version; URI = $URI }
    }
    catch
    {
        Throw $_
    }
}

function Get-AdobeAcrobatAdmxOnline
{
    <#
    .SYNOPSIS
    Returns latest Version and Uri for the Adobe Acrobat Continuous track Admx files
#>

    try
    {

        $file = "AcrobatADMTemplate.zip"
        $url = "ftp://ftp.adobe.com/pub/adobe/acrobat/win/AcrobatDC/misc/"

        # grab ftp response from $url
        Write-Verbose "FTP $($url)"
        $listRequest = [Net.WebRequest]::Create($url)
        $listRequest.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails
        $lines = New-Object System.Collections.ArrayList

        # process response
        $listResponse = $listRequest.GetResponse()
        $listStream = $listResponse.GetResponseStream()
        $listReader = New-Object System.IO.StreamReader($listStream)
        while (!$listReader.EndOfStream)
        {
            $line = $listReader.ReadLine()
            if ($line.Contains($file)) { $lines.Add($line) | Out-Null }
        }
        $listReader.Dispose()
        $listStream.Dispose()
        $listResponse.Dispose()

        Write-Verbose "received $($line.Length) characters response"

        # parse response to get Version
        $tokens = $lines[0].Split(" ", 9, [StringSplitOptions]::RemoveEmptyEntries)
        $Version = Get-Date -Date "$($tokens[6])/$($tokens[5])/$($tokens[7])" -Format "yy.M.d"

        # return evergreen object
        return @{ Version = $Version; URI = "$($url)$($file)" }
    }
    catch
    {
        Throw $_
    }
}

function Get-AdobeReaderAdmxOnline
{
    <#
    .SYNOPSIS
    Returns latest Version and Uri for the Adobe Reader Continuous track Admx files
#>

    try
    {

        $file = "ReaderADMTemplate.zip"
        $url = "ftp://ftp.adobe.com/pub/adobe/reader/win/AcrobatDC/misc/"

        # grab ftp response from $url
        Write-Verbose "FTP $($url)"
        $listRequest = [Net.WebRequest]::Create($url)
        $listRequest.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails
        $lines = New-Object System.Collections.ArrayList

        # process response
        $listResponse = $listRequest.GetResponse()
        $listStream = $listResponse.GetResponseStream()
        $listReader = New-Object System.IO.StreamReader($listStream)
        while (!$listReader.EndOfStream)
        {
            $line = $listReader.ReadLine()
            if ($line.Contains($file)) { $lines.Add($line) | Out-Null }
        }
        $listReader.Dispose()
        $listStream.Dispose()
        $listResponse.Dispose()

        Write-Verbose "received $($line.Length) characters response"
        # parse response to get Version
        $tokens = $lines[0].Split(" ", 9, [StringSplitOptions]::RemoveEmptyEntries)
        $Version = Get-Date -Date "$($tokens[6])/$($tokens[5])/$($tokens[7])" -Format "yy.M.d"

        # return evergreen object
        return @{ Version = $Version; URI = "$($url)$($file)" }
    }
    catch
    {
        Throw $_
    }
}

function Get-CitrixWorkspaceAppAdmxOnline
{
    <#
    .SYNOPSIS
    Returns latest Version and Uri for Citrix Workspace App ADMX files
#>

    try
    {

        $url = "https://www.citrix.com/downloads/workspace-app/windows/workspace-app-for-windows-latest.html"
        # grab content
        $web = (Invoke-WebRequest -UseDefaultCredentials -Uri $url -UseBasicParsing -DisableKeepAlive).RawContent
        # find line with ADMX download
        $str = ($web -split "`r`n" | Select-String -Pattern "_ADMX_")[0].ToString().Trim()
        # extract url from ADMX download string
        $URI = "https:$(((Select-String '(\/\/)([^\s,]+)(?=")' -Input $str).Matches.Value))"
        # grab version
        $VersionRegEx = "Version\: ((?:\d+\.)+(?:\d+)) \((.+)\)"
        $Version = ($web | Select-String -Pattern $VersionRegEx).Matches.Groups[1].Value

        # return evergreen object
        return @{ Version = $Version; URI = $URI }
    }
    catch
    {
        Throw $_
    }
}

function Get-MozillaFirefoxAdmxOnline
{
    <#
    .SYNOPSIS
    Returns latest Version and Uri for Mozilla Firefox ADMX files
#>

    try
    {

        # define github repo
        $repo = "mozilla/policy-templates"
        # grab latest release properties
        $latest = (Invoke-WebRequest -UseDefaultCredentials -Uri "https://api.github.com/repos/$($repo)/releases" -UseBasicParsing | ConvertFrom-Json)[0]

        # grab version
        $Version = ($latest.tag_name | Select-String -Pattern "(\d+(\.\d+){1,4})" -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value }).ToString()
        # grab uri
        $URI = $latest.assets.browser_download_url

        # return evergreen object
        return @{ Version = $Version; URI = $URI }
    }
    catch
    {
        Throw $_
    }
}

function Get-BIS-FAdmxOnline
{
    <#
    .SYNOPSIS
    Returns latest Version and Uri for BIS-F ADMX files
#>

    try
    {

        # define github repo
        $repo = "EUCweb/BIS-F"
        # grab latest release properties
        $latest = (Invoke-WebRequest -UseDefaultCredentials -Uri "https://api.github.com/repos/$($repo)/releases" -UseBasicParsing | ConvertFrom-Json)[0]

        # grab version
        $Version = ($latest.tag_name | Select-String -Pattern "(\d+(\.\d+){1,4})" -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value }).ToString()
        # grab uri
        $URI = $latest.zipball_url

        # return evergreen object
        return @{ Version = $Version; URI = $URI }
    }
    catch
    {
        Throw $_
    }
}

function Get-MDOPAdmxOnline
{
    <#
    .SYNOPSIS
    Returns latest Version and Uri for the Desktop Optimization Pack Admx files (both x64 and x86)
#>

    $id = "55531"
    $urlversion = "https://www.microsoft.com/en-us/download/details.aspx?id=$($id)"
    $urldownload = "https://www.microsoft.com/en-us/download/confirmation.aspx?id=$($id)"
    try
    {

        # load page for version scrape
        $web = Invoke-WebRequest -UseDefaultCredentials -UseBasicParsing -Uri $urlversion
        $str = ($web.ToString() -split "[`r`n]" | Select-String "Version:").ToString()
        # grab version
        $Version = ($str | Select-String -Pattern "(\d+(\.\d+){1,4})" -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value }).ToString()
        # load page for uri scrape
        $web = Invoke-WebRequest -UseDefaultCredentials -UseBasicParsing -Uri $urldownload -MaximumRedirection 0
        # grab download url
        $href = $web.Links | Where-Object { $_.outerHTML -like "*click here to download manually*" }

        # return evergreen object
        return @{ Version = $Version; URI = $href.href }
    }
    catch
    {
        Throw $_
    }
}


function Get-WAUCAdmxOnline
{
    <#
    .SYNOPSIS
    Returns latest Version and Uri for the Desktop Optimization Pack Admx files (both x64 and x86)
#>

    $urldownload = "https://raw.githubusercontent.com/Weatherlights/Winget-AutoUpdate-Intune/main/ADMX/WinGet-AutoUpdate-Configurator.admx"
    try
    {
        $web = Invoke-WebRequest -UseBasicParsing -Uri $urldownload -ContentType "application/xml" ;
        $web.Content | Out-file .\Downloads\testadmx.xml
        [xml]$xml = (Get-Content .\Downloads\testadmx.xml -Raw) 
        # load page for version scrape
        $web = Invoke-WebRequest -UseDefaultCredentials -UseBasicParsing -Uri $urlversion
        $str = ($web.ToString() -split "[`r`n]" | Select-String "Version:").ToString()
        # grab version
        $Version = ($str | Select-String -Pattern "(\d+(\.\d+){1,4})" -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value }).ToString()
        # load page for uri scrape
        $web = Invoke-WebRequest -UseDefaultCredentials -UseBasicParsing -Uri $urldownload -MaximumRedirection 0
        # grab download url
        $href = $web.Links | Where-Object { $_.outerHTML -like "*click here to download manually*" }

        # return evergreen object
        return @{ Version = $Version; URI = $href.href }
    }
    catch
    {
        Throw $_
    }
}


function Get-ZoomDesktopClientAdmxOnline
{
    <#
    .SYNOPSIS
    Returns latest Version and Uri for Zoom Desktop Client ADMX files
#>

    try
    {
        $Version = "5.13.0"
        #$ZoomADMX = Split-Path -Path $ZoomADMXUrl -Leaf

        #$url = "https://support.zoom.us/hc/en-us/articles/360039100051"
        # grab content
        #$web = Invoke-WebRequest -UseDefaultCredentials -Uri $url -UseBasicParsing
        # find ADMX download
        #$URI = (($web.Links | Where-Object {$_.href -like "*msi-templates*.zip"})[-1]).href
        $URI = "https://assets.zoom.us/docs/msi-templates/Zoom_$($Version).zip"
        # grab version
        #$Version = ($URI.Split("/")[-1] | Select-String -Pattern "(\d+(\.\d+){1,4})" -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value }).ToString()

        # return evergreen object
        return @{ Version = $Version; URI = $URI }
    }
    catch
    {
        Throw $_
    }
}

function Get-CustomPolicyOnline
{
    <#
    .SYNOPSIS
    Returns latest Version and Uri for Custom Policies

    .PARAMETER CustomPolicyStore
    Folder where Custom Policies can be found
#>
    param(
        [string] $CustomPolicyStore
    )

    $newestFileDate = Get-Date -Date ((Get-ChildItem -Path $CustomPolicyStore -Include "*.admx", "*.adml" -Recurse | Sort-Object LastWriteTime -Descending) | Select-Object -First 1).LastWriteTime

    $version = Get-Date -Date $newestFileDate -Format "yyMM.dd.HHmmss"

    return @{ Version = $version; URI = $CustomPolicyStore }
}

function Get-FSLogixAdmx
{
    <#
    .SYNOPSIS
    Process FSLogix Admx files

    .PARAMETER Version
    Current Version present

    .PARAMETER PolicyStore
    Destination for the Admx files
#>

    param(
        [string]$Version,
        [string]$PolicyStore = $null,
        [string[]]$Languages = $null
    )

    $evergreen = Get-FSLogixOnline
    $productname = "FSLogix"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        $outfile = "$($WorkingDirectory)\downloads\$($evergreen.URI.Split("/")[-1])"
        try
        {
            # download
            Write-Verbose "Downloading '$($evergreen.URI)' to '$($outfile)'"
            Invoke-WebRequest -UseDefaultCredentials -Uri $evergreen.URI -UseBasicParsing -OutFile $outfile

            # extract
            Write-Verbose "Extracting '$($outfile)' to '$($env:TEMP)\fslogix'"
            Expand-Archive -Path $outfile -DestinationPath "$($env:TEMP)\fslogix" -Force

            # copy
            $sourceadmx = "$($env:TEMP)\fslogix"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            if (-not (Test-Path -Path "$($targetadmx)\en-US")) { $null = (New-Item -Path "$($targetadmx)\en-US" -ItemType Directory -Force) }

            Write-Verbose "Copying Admx files from '$($sourceadmx)' to '$($targetadmx)'"
            Copy-Item -Path "$($sourceadmx)\*.admx" -Destination "$($targetadmx)" -Force
            Copy-Item -Path "$($sourceadmx)\*.adml" -Destination "$($targetadmx)\en-US" -Force
            if ($PolicyStore)
            {
                Write-Verbose "Copying Admx files from '$($sourceadmx)' to '$($PolicyStore)'"
                Copy-Item -Path "$($sourceadmx)\*.admx" -Destination "$($PolicyStore)" -Force
                if (-not (Test-Path -Path "$($PolicyStore)en-US")) { $null = (New-Item -Path "$($PolicyStore)en-US" -ItemType Directory -Force) }
                Copy-Item -Path "$($sourceadmx)\*.adml" -Destination "$($PolicyStore)en-US" -Force
            }

            # cleanup
            Remove-Item -Path "$($env:TEMP)\fslogix" -Recurse -Force

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}

function Get-MicrosoftOfficeAdmx
{
    <#
    .SYNOPSIS
    Process Office Admx files

    .PARAMETER Version
    Current Version present

    .PARAMETER PolicyStore
    Destination for the Admx files

    .PARAMETER Architecture
    Architecture (x86 or x64)
#>

    param(
        [string]$Version,
        [string]$PolicyStore = $null,
        [string]$Architecture = "x64",
        [string[]]$Languages = $null
    )

    $evergreen = Get-MicrosoftOfficeAdmxOnline | Where-Object { $_.Architecture -like $Architecture }
    $productname = "Microsoft Office $($Architecture)"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        $outfile = "$($WorkingDirectory)\downloads\$($evergreen.URI.Split("/")[-1])"
        try
        {
            # download
            Write-Verbose "Downloading '$($evergreen.URI)' to '$($outfile)'"
            Invoke-WebRequest -UseDefaultCredentials -Uri $evergreen.URI -UseBasicParsing -OutFile $outfile

            # extract
            Write-Verbose "Extracting '$($outfile)' to '$($env:TEMP)\office'"
            $null = Start-Process -FilePath $outfile -ArgumentList "/quiet /norestart /extract:`"$($env:TEMP)\office`"" -PassThru -Wait

            # copy
            $sourceadmx = "$($env:TEMP)\office\admx"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName $productname -Languages $Languages

            # cleanup
            Remove-Item -Path "$($env:TEMP)\office" -Recurse -Force

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}

function Get-WindowsAdmx
{
    <#
    .SYNOPSIS
    Process Windows 10 or Windows 11 Admx files

    .PARAMETER Version
    Current Version present

    .PARAMETER PolicyStore
    Destination for the Admx files

    .PARAMETER WindowsVersion
    Official WindowsVersion format

    .PARAMETER WindowsEdition
    Differentiate between Windows 10 and Windows 11

    .PARAMETER Languages
    Languages to check
#>

    param(
        [string]$Version,
        [string]$PolicyStore = $null,
        [string]$WindowsVersion,
        [int]$WindowsEdition,
        [string[]]$Languages = $null
    )

    $id = Get-WindowsAdmxDownloadId -WindowsVersion $WindowsVersion -WindowsEdition $WindowsEdition
    $evergreen = Get-WindowsAdmxOnline -DownloadId $id
    $productname = "Microsoft Windows $($WindowsEdition) $($WindowsVersion)"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        $outfile = "$($WorkingDirectory)\downloads\$($evergreen.URI.Split("/")[-1])"
        try
        {
            # download
            Write-Verbose "Downloading '$($evergreen.URI)' to '$($outfile)'"
            Invoke-WebRequest -UseDefaultCredentials -Uri $evergreen.URI -UseBasicParsing -OutFile $outfile

            # install
            Write-Verbose "Installing downloaded Windows $($WindowsEdition) Admx installer"
            $null = Start-Process -FilePath "MsiExec.exe" -WorkingDirectory "$($WorkingDirectory)\downloads" -ArgumentList "/qn /norestart /I`"$($outfile.split('\')[-1])`"" -PassThru -Wait

            # find installation path
            Write-Verbose "Grabbing installation path for Windows $($WindowsEdition) Admx installer"
            $installfolder = Get-ChildItem -Path "C:\Program Files (x86)\Microsoft Group Policy"
            Write-Verbose "Found '$($installfolder.Name)'"

            # find uninstall info
            Write-Verbose "Grabbing uninstallation info from registry for Windows $($WindowsEdition) Admx installer"
            $uninstall = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" | Where-Object { $_.DisplayName -like "*(.admx)*" }
            Write-Verbose "Found '$($uninstall.DisplayName)'"

            # copy
            $sourceadmx = "C:\Program Files (x86)\Microsoft Group Policy\$($installfolder.Name)\PolicyDefinitions"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName $productname -Languages $Languages

            # uninstall
            Write-Verbose "Uninstalling Windows $($WindowsEdition) Admx installer"
            $null = Start-Process -FilePath "MsiExec.exe" -ArgumentList "/qn /norestart /X$($uninstall.PSChildName)" -PassThru -Wait

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}

function Get-OneDriveAdmx
{
    <#
    .SYNOPSIS
    Process OneDrive Admx files

    .PARAMETER Version
    Current Version present

    .PARAMETER PolicyStore
    Destination for the Admx files

    .PARAMETER PreferLocalOneDrive
    Check locally only
#>

    param(
        [string] $Version,
        [string] $PolicyStore = $null,
        [bool] $PreferLocalOneDrive,
        [string[]]$Languages = $null
    )

    $evergreen = Get-OneDriveOnline -PreferLocalOneDrive $PreferLocalOneDrive
    $productname = "Microsoft OneDrive"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        $outfile = "$($WorkingDirectory)\downloads\$($evergreen.URI.Split("/")[-1])"
        try
        {
            if (-not $PreferLocalOneDrive)
            {
                # download
                Write-Verbose "Downloading '$($evergreen.URI)' to '$($outfile)'"
                Invoke-WebRequest -UseDefaultCredentials -Uri $evergreen.URI -UseBasicParsing -OutFile $outfile

                # install
                Write-Verbose "Installing downloaded OneDrive installer"
                $null = Start-Process -FilePath $outfile -ArgumentList "/allusers" -PassThru
                # wait for setup to complete
                while (Get-Process -Name "OneDriveSetup") { Start-Sleep -Seconds 10 }
                # onedrive starts automatically after setup. kill!
                Stop-Process -Name "OneDrive" -Force

                # find uninstall info
                Write-Verbose "Grabbing uninstallation info from registry for OneDrive installer"
                $uninstall = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe"
                if ($null -eq $uninstall)
                {
                    $uninstall = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe"
                }
                if ($null -eq $uninstall)
                {
                    Write-Warning -Message "Unable to find uninstall information for OneDrive."
                }
                else
                {
                    Write-Verbose "Found '$($uninstall.DisplayName)'"

                    # find installation path
                    Write-Verbose "Grabbing installation path for OneDrive installer"
                    $installfolder = $uninstall.DisplayIcon.Substring(0, $uninstall.DisplayIcon.IndexOf("\OneDriveSetup.exe"))
                    Write-Verbose "Found '$($installfolder)'"
                }
            }
            else
            {
                $installfolder = $evergreen.URI
            }
            # copy
            $sourceadmx = "$($installfolder)\adm"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            if (-not (Test-Path -Path "$($targetadmx)")) { $null = (New-Item -Path "$($targetadmx)" -ItemType Directory -Force) }

            Write-Verbose "Copying Admx files from '$($sourceadmx)' to '$($targetadmx)'"
            Copy-Item -Path "$($sourceadmx)\*.admx" -Destination "$($targetadmx)" -Force
            foreach ($language in $Languages)
            {
                if (-not (Test-Path -Path "$($sourceadmx)\$($language)") -and -not (Test-Path -Path "$($sourceadmx)\$($language.Substring(0,2))"))
                {
                    if ($language -notlike "en-us") { Write-Warning "Language '$($language)' not found for '$($productname)'. Processing 'en-US' instead." }
                    if (-not (Test-Path -Path "$($targetadmx)\en-US")) { $null = (New-Item -Path "$($targetadmx)\en-US" -ItemType Directory -Force) }
                    Copy-Item -Path "$($sourceadmx)\*.adml" -Destination "$($targetadmx)\en-US" -Force
                }
                else
                {
                    $sourcelanguage = $language; if (-not (Test-Path -Path "$($sourceadmx)\$($language)")) { $sourcelanguage = $language.Substring(0, 2) }
                    if (-not (Test-Path -Path "$($targetadmx)\$($language)")) { $null = (New-Item -Path "$($targetadmx)\$($language)" -ItemType Directory -Force) }
                    Copy-Item -Path "$($sourceadmx)\$($sourcelanguage)\*.adml" -Destination "$($targetadmx)\$($language)" -Force
                }
            }

            if ($PolicyStore)
            {
                Write-Verbose "Copying Admx files from '$($sourceadmx)' to '$($PolicyStore)'"
                Copy-Item -Path "$($sourceadmx)\*.admx" -Destination "$($PolicyStore)" -Force
                foreach ($language in $Languages)
                {
                    if (-not (Test-Path -Path "$($sourceadmx)\$($language)") -and -not (Test-Path -Path "$($sourceadmx)\$($language.Substring(0,2))"))
                    {
                        if (-not (Test-Path -Path "$($PolicyStore)en-US")) { $null = (New-Item -Path "$($PolicyStore)en-US" -ItemType Directory -Force) }
                        Copy-Item -Path "$($sourceadmx)\*.adml" -Destination "$($PolicyStore)en-US" -Force
                    }
                    else
                    {
                        $sourcelanguage = $language; if (-not (Test-Path -Path "$($sourceadmx)\$($language)")) { $sourcelanguage = $language.Substring(0, 2) }
                        if (-not (Test-Path -Path "$($PolicyStore)$($language)")) { $null = (New-Item -Path "$($PolicyStore)$($language)" -ItemType Directory -Force) }
                        Copy-Item -Path "$($sourceadmx)\$($sourcelanguage)\*.adml" -Destination "$($PolicyStore)$($language)" -Force
                    }
                }
            }

            if (-not $PreferLocalOneDrive)
            {
                # uninstall
                Write-Verbose "Uninstalling OneDrive installer"
                $null = Start-Process -FilePath "$($installfolder)\OneDriveSetup.exe" -ArgumentList "/uninstall /allusers" -PassThru -Wait
            }

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}

function Get-MicrosoftEdgeAdmx
{
    <#
    .SYNOPSIS
    Process Microsoft Edge (Chromium) Admx files

    .PARAMETER Version
    Current Version present

    .PARAMETER PolicyStore
    Destination for the Admx files
#>

    param(
        [string]$Version,
        [string]$PolicyStore = $null,
        [string[]]$Languages = $null
    )

    $evergreen = Get-MicrosoftEdgePolicyOnline
    $productname = "Microsoft Edge (Chromium)"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        $outfile = "$($WorkingDirectory)\downloads\MicrosoftEdgePolicyTemplates.cab"
        $zipfile = "$($WorkingDirectory)\downloads\MicrosoftEdgePolicyTemplates.zip"

        try
        {
            # download
            Write-Verbose "Downloading '$($evergreen.URI)' to '$($outfile)'"
            Invoke-WebRequest -UseDefaultCredentials -Uri $evergreen.URI -UseBasicParsing -OutFile $outfile

            # extract
            Write-Verbose "Extracting '$($outfile)' to '$($env:TEMP)\microsoftedgepolicy'"
            $null = (New-Item -Path "$($env:TEMP)\microsoftedgepolicy" -ItemType Directory -Force)
            $null = (expand "$($outfile)" -F:* "$($env:TEMP)\microsoftedgepolicy" $zipfile)

            Expand-Archive -Path $zipfile -DestinationPath "$($env:TEMP)\microsoftedgepolicy" -Force

            # copy
            $sourceadmx = "$($env:TEMP)\microsoftedgepolicy\windows\admx"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName $productname -Languages $Languages

            # cleanup
            Remove-Item -Path $outfile -Force
            Remove-Item -Path "$env:TEMP\microsoftedgepolicy" -Recurse -Force

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}

function Get-GoogleChromeAdmx
{
    <#
    .SYNOPSIS
    Process Google Chrome Admx files

    .PARAMETER Version
    Current Version present

    .PARAMETER PolicyStore
    Destination for the Admx files
#>

    param(
        [string]$Version,
        [string]$PolicyStore = $null,
        [string[]]$Languages = $null
    )

    $evergreen = Get-GoogleChromeAdmxOnline
    $productname = "Google Chrome"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        $outfile = "$($WorkingDirectory)\downloads\googlechromeadmx.zip"
        try
        {
            # download
            Write-Verbose "Downloading '$($evergreen.URI)' to '$($outfile)'"
            Invoke-WebRequest -UseDefaultCredentials -Uri $evergreen.URI -UseBasicParsing -OutFile $outfile

            # extract
            Write-Verbose "Extracting '$($outfile)' to '$($env:TEMP)\chromeadmx'"
            Expand-Archive -Path $outfile -DestinationPath "$($env:TEMP)\chromeadmx" -Force

            # copy
            $sourceadmx = "$($env:TEMP)\chromeadmx\windows\admx"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName $productname -Languages $Languages

            # cleanup
            Remove-Item -Path "$($env:TEMP)\chromeadmx" -Recurse -Force

            # chrome update admx is a seperate download
            $url = "https://dl.google.com/dl/update2/enterprise/googleupdateadmx.zip"

            # download
            $outfile = "$($WorkingDirectory)\downloads\googlechromeupdateadmx.zip"
            Write-Verbose "Downloading '$($url)' to '$($outfile)'"
            Invoke-WebRequest -UseDefaultCredentials -Uri $url -UseBasicParsing -OutFile $outfile

            # extract
            Write-Verbose "Extracting '$($outfile)' to '$($env:TEMP)\chromeupdateadmx'"
            Expand-Archive -Path $outfile -DestinationPath "$($env:TEMP)\chromeupdateadmx" -Force

            # copy
            $sourceadmx = "$($env:TEMP)\chromeupdateadmx\GoogleUpdateAdmx"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName $productname -Quiet -Languages $Languages

            # cleanup
            Remove-Item -Path "$($env:TEMP)\chromeupdateadmx" -Recurse -Force

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}

function Get-AdobeAcrobatAdmx
{
    <#
    .SYNOPSIS
    Process Adobe Acrobat Admx files

    .PARAMETER Version
    Current Version present

    .PARAMETER PolicyStore
    Destination for the Admx files
#>

    param(
        [string]$Version,
        [string]$PolicyStore = $null,
        [string[]]$Languages = $null
    )

    $evergreen = Get-AdobeAcrobatAdmxOnline
    $productname = "Adobe Acrobat"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        $outfile = "$($WorkingDirectory)\downloads\$($evergreen.URI.Split("/")[-1])"
        try
        {
            # download
            Write-Verbose "Downloading '$($evergreen.URI)' to '$($outfile)'"
            Invoke-WebRequest -Uri $evergreen.URI -UseBasicParsing -OutFile $outfile

            # extract
            Write-Verbose "Extracting '$($outfile)' to '$($env:TEMP)\AdobeAcrobat'"
            Expand-Archive -Path $outfile -DestinationPath "$($env:TEMP)\AdobeAcrobat" -Force

            # copy
            $sourceadmx = "$($env:TEMP)\AdobeAcrobat"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName $productname -Languages $Languages

            # cleanup
            Remove-Item -Path "$($env:TEMP)\AdobeAcrobat" -Recurse -Force

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}

function Get-AdobeReaderAdmx
{
    <#
    .SYNOPSIS
    Process Adobe Reader Admx files

    .PARAMETER Version
    Current Version present

    .PARAMETER PolicyStore
    Destination for the Admx files
#>

    param(
        [string]$Version,
        [string]$PolicyStore = $null,
        [string[]]$Languages = $null
    )

    $evergreen = Get-AdobeReaderAdmxOnline
    $productname = "Adobe Reader"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        $outfile = "$($WorkingDirectory)\downloads\$($evergreen.URI.Split("/")[-1])"
        try
        {
            # download
            Write-Verbose "Downloading '$($evergreen.URI)' to '$($outfile)'"
            Invoke-WebRequest -Uri $evergreen.URI -UseBasicParsing -OutFile $outfile

            # extract
            Write-Verbose "Extracting '$($outfile)' to '$($env:TEMP)\AdobeReader'"
            Expand-Archive -Path $outfile -DestinationPath "$($env:TEMP)\AdobeReader" -Force

            # copy
            $sourceadmx = "$($env:TEMP)\AdobeReader"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName $productname -Languages $Languages

            # cleanup
            Remove-Item -Path "$($env:TEMP)\AdobeReader" -Recurse -Force

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}

function Get-CitrixWorkspaceAppAdmx
{
    <#
    .SYNOPSIS
    Process Citrix Workspace App Admx files

    .PARAMETER Version
    Current Version present

    .PARAMETER PolicyStore
    Destination for the Admx files
#>

    param(
        [string]$Version,
        [string]$PolicyStore = $null,
        [string[]]$Languages = $null
    )

    $evergreen = Get-CitrixWorkspaceAppAdmxOnline
    $productname = "Citrix Workspace App"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        $outfile = "$($WorkingDirectory)\downloads\$($evergreen.URI.Split("?")[0].Split("/")[-1])"
        try
        {
            # download
            Write-Verbose "Downloading '$($evergreen.URI)' to '$($outfile)'"
            Invoke-WebRequest -UseDefaultCredentials -Uri $evergreen.URI -UseBasicParsing -OutFile $outfile

            # extract
            Write-Verbose "Extracting '$($outfile)' to '$($env:TEMP)\citrixworkspaceapp'"
            Expand-Archive -Path $outfile -DestinationPath "$($env:TEMP)\citrixworkspaceapp" -Force

            # copy
            # $sourceadmx = "$($env:TEMP)\citrixworkspaceapp\$($evergreen.URI.Split("/")[-2].Split("?")[0].SubString(0,$evergreen.URI.Split("/")[-2].Split("?")[0].IndexOf(".")))"
            $sourceadmx = (Get-ChildItem -Path "$($env:TEMP)\citrixworkspaceapp\$($evergreen.URI.Split("/")[-2].Split("?")[0].SubString(0,$evergreen.URI.Split("/")[-2].Split("?")[0].IndexOf(".")))" -Include "*.admx" -Recurse)[0].DirectoryName
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName $productname -Languages $Languages

            # cleanup
            Remove-Item -Path "$($env:TEMP)\citrixworkspaceapp" -Recurse -Force

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}

function Get-MozillaFirefoxAdmx
{
    <#
    .SYNOPSIS
    Process Mozilla Firefox Admx files

    .PARAMETER Version
    Current Version present

    .PARAMETER PolicyStore
    Destination for the Admx files
#>

    param(
        [string]$Version,
        [string]$PolicyStore = $null,
        [string[]]$Languages = $null
    )

    $evergreen = Get-MozillaFirefoxAdmxOnline
    $productname = "Mozilla Firefox"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        $outfile = "$($WorkingDirectory)\downloads\$($evergreen.URI.Split("/")[-1])"
        try
        {
            # download
            Write-Verbose "Downloading '$($evergreen.URI)' to '$($outfile)'"
            Invoke-WebRequest -UseDefaultCredentials -Uri $evergreen.URI -UseBasicParsing -OutFile $outfile

            # extract
            Write-Verbose "Extracting '$($outfile)' to '$($env:TEMP)\firefoxadmx'"
            Expand-Archive -Path $outfile -DestinationPath "$($env:TEMP)\firefoxadmx" -Force

            # copy
            $sourceadmx = "$($env:TEMP)\firefoxadmx\windows"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName $productname -Languages $Languages

            # cleanup
            Remove-Item -Path "$($env:TEMP)\firefoxadmx" -Recurse -Force

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}

function Get-ZoomDesktopClientAdmx
{
    <#
    .SYNOPSIS
    Process Zoom Desktop Client Admx files

    .PARAMETER Version
    Current Version present

    .PARAMETER PolicyStore
    Destination for the Admx files
#>

    param(
        [string]$Version,
        [string]$PolicyStore = $null,
        [string[]]$Languages = $null
    )

    $evergreen = Get-ZoomDesktopClientAdmxOnline
    $productname = "Zoom Desktop Client"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        $outfile = "$($WorkingDirectory)\downloads\$($evergreen.URI.Split("/")[-1])"
        try
        {
            # download
            Write-Verbose "Downloading '$($evergreen.URI)' to '$($outfile)'"
            Invoke-WebRequest -UseDefaultCredentials -Uri $evergreen.URI -UseBasicParsing -OutFile $outfile

            # extract
            Write-Verbose "Extracting '$($outfile)' to '$($env:TEMP)\zoomclientadmx'"
            Expand-Archive -Path $outfile -DestinationPath "$($env:TEMP)\zoomclientadmx" -Force

            # copy
            $sourceadmx = "$($env:TEMP)\zoomclientadmx\$([io.path]::GetFileNameWithoutExtension($evergreen.URI.Split("/")[-1]))"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName $productname -Languages $Languages

            # cleanup
            Remove-Item -Path "$($env:TEMP)\zoomclientadmx" -Recurse -Force

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}

function Get-BIS-FAdmx
{
    <#
    .SYNOPSIS
    Process BIS-F Admx files

    .PARAMETER Version
    Current Version present

    .PARAMETER PolicyStore
    Destination for the Admx files
#>

    param(
        [string]$Version,
        [string]$PolicyStore = $null,
        [string[]]$Languages = $null
    )

    $evergreen = Get-BIS-FAdmxOnline
    $productname = "BIS-F"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        $outfile = "$($WorkingDirectory)\downloads\bis-f.$($evergreen.Version).zip"
        try
        {
            # download
            Write-Verbose "Downloading '$($evergreen.URI)' to '$($outfile)'"
            Invoke-WebRequest -UseDefaultCredentials -Uri $evergreen.URI -UseBasicParsing -OutFile $outfile

            # extract
            Write-Verbose "Extracting '$($outfile)' to '$($env:TEMP)\bisfadmx'"
            Expand-Archive -Path $outfile -DestinationPath "$($env:TEMP)\bisfadmx" -Force

            # find extraction folder
            Write-Verbose "Finding extraction folder"
            $folder = (Get-ChildItem -Path "$($env:TEMP)\bisfadmx" | Sort-Object LastWriteTime -Descending)[0].Name

            # copy
            $sourceadmx = "$($env:TEMP)\bisfadmx\$($folder)\admx"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName $productname -Languages $Languages

            # cleanup
            Remove-Item -Path "$($env:TEMP)\bisfadmx" -Recurse -Force

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}


function Get-WAUCAdmx
{
    <#
    .SYNOPSIS
    Process Winget-Autoupdate-Configurator (WAUC) Admx files

    .PARAMETER Version
    Current Version present

    .PARAMETER PolicyStore
    Destination for the Admx files
#>

    param(
        [string]$Version,
        [string]$PolicyStore = $null,
        [string[]]$Languages = $null
    )

    $evergreen = Get-MDOPAdmxOnline
    $productname = "Microsoft Desktop Optimization Pack"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        $outfile = "$($WorkingDirectory)\downloads\$($evergreen.URI.Split("/")[-1])"
        try
        {
            # download
            Write-Verbose "Downloading '$($evergreen.URI)' to '$($outfile)'"
            Invoke-WebRequest -UseDefaultCredentials -Uri $evergreen.URI -UseBasicParsing -OutFile $outfile

            # extract
            Write-Verbose "Extracting '$($outfile)' to '$($env:TEMP)\mdopadmx'"
            $null = (New-Item -Path "$($env:TEMP)\mdopadmx" -ItemType Directory -Force)
            $null = (expand "$($outfile)" -F:* "$($env:TEMP)\mdopadmx")

            # find app-v folder
            Write-Verbose "Finding App-V folder"
            $appvfolder = (Get-ChildItem -Path "$($env:TEMP)\mdopadmx" -Filter "App-V*" | Sort-Object Name -Descending)[0].Name

            Write-Verbose "Finding MBAM folder"
            $mbamfolder = (Get-ChildItem -Path "$($env:TEMP)\mdopadmx" -Filter "MBAM*" | Sort-Object Name -Descending)[0].Name

            Write-Verbose "Finding UE-V folder"
            $uevfolder = (Get-ChildItem -Path "$($env:TEMP)\mdopadmx" -Filter "UE-V*" | Sort-Object Name -Descending)[0].Name

            # copy
            $sourceadmx = "$($env:TEMP)\mdopadmx\$($appvfolder)"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName "$($productname) - App-V" -Languages $Languages
            $sourceadmx = "$($env:TEMP)\mdopadmx\$($mbamfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName "$($productname) - MBAM" -Languages $Languages
            $sourceadmx = "$($env:TEMP)\mdopadmx\$($uevfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName "$($productname) - UE-V" -Languages $Languages

            # cleanup
            Remove-Item -Path "$($env:TEMP)\mdopadmx" -Recurse -Force

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}

function Get-MDOPAdmx
{
    <#
    .SYNOPSIS
    Process MDOP Admx files

    .PARAMETER Version
    Current Version present

    .PARAMETER PolicyStore
    Destination for the Admx files
#>

    param(
        [string]$Version,
        [string]$PolicyStore = $null,
        [string[]]$Languages = $null
    )

    $evergreen = Get-MDOPAdmxOnline
    $productname = "Microsoft Desktop Optimization Pack"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        $outfile = "$($WorkingDirectory)\downloads\$($evergreen.URI.Split("/")[-1])"
        try
        {
            # download
            Write-Verbose "Downloading '$($evergreen.URI)' to '$($outfile)'"
            Invoke-WebRequest -UseDefaultCredentials -Uri $evergreen.URI -UseBasicParsing -OutFile $outfile

            # extract
            Write-Verbose "Extracting '$($outfile)' to '$($env:TEMP)\mdopadmx'"
            $null = (New-Item -Path "$($env:TEMP)\mdopadmx" -ItemType Directory -Force)
            $null = (expand "$($outfile)" -F:* "$($env:TEMP)\mdopadmx")

            # find app-v folder
            Write-Verbose "Finding App-V folder"
            $appvfolder = (Get-ChildItem -Path "$($env:TEMP)\mdopadmx" -Filter "App-V*" | Sort-Object Name -Descending)[0].Name

            Write-Verbose "Finding MBAM folder"
            $mbamfolder = (Get-ChildItem -Path "$($env:TEMP)\mdopadmx" -Filter "MBAM*" | Sort-Object Name -Descending)[0].Name

            Write-Verbose "Finding UE-V folder"
            $uevfolder = (Get-ChildItem -Path "$($env:TEMP)\mdopadmx" -Filter "UE-V*" | Sort-Object Name -Descending)[0].Name

            # copy
            $sourceadmx = "$($env:TEMP)\mdopadmx\$($appvfolder)"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName "$($productname) - App-V" -Languages $Languages
            $sourceadmx = "$($env:TEMP)\mdopadmx\$($mbamfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName "$($productname) - MBAM" -Languages $Languages
            $sourceadmx = "$($env:TEMP)\mdopadmx\$($uevfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName "$($productname) - UE-V" -Languages $Languages

            # cleanup
            Remove-Item -Path "$($env:TEMP)\mdopadmx" -Recurse -Force

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}

function Get-CustomPolicyAdmx
{
    <#
        .SYNOPSIS
        Process Custom Policy Admx files

        .PARAMETER Version
        Current Version present

        .PARAMETER PolicyStore
        Destination for the Admx files
    #>

    param(
        [string]$Version,
        [string]$PolicyStore = $null,
        [string]$CustomPolicyStore,
        [string[]]$Languages = $null
    )

    $evergreen = Get-CustomPolicyOnline -CustomPolicyStore $CustomPolicyStore
    $productname = "Custom Policy Store"
    $productfolder = ""; if ($UseProductFolders) { $productfolder = "\$($productname)" }

    # see if this is a newer version
    if (-not $Version -or [version]$evergreen.Version -gt [version]$Version)
    {
        Write-Verbose "Found new version $($evergreen.Version) for '$($productname)'"

        # download and process
        try
        {
            # copy
            $sourceadmx = "$($evergreen.URI)"
            $targetadmx = "$($WorkingDirectory)\admx$($productfolder)"
            Copy-Admx -SourceFolder $sourceadmx -TargetFolder $targetadmx -PolicyStore $PolicyStore -ProductName "$($productname)" -Languages $Languages

            return $evergreen
        }
        catch
        {
            Throw $_
        }
    }
    else
    {
        # version already processed
        return $null
    }
}
#endregion

# Custom Policy Store
if ($Include -notcontains 'Custom Policy Store')
{
    Write-Verbose "`nSkipping Custom Policy Store"
}
else
{
    Write-Verbose "`nProcessing Admx files for Custom Policy Store"
    $currentversion = $null
    if ($admxversions.PSObject.properties -match 'CustomPolicyStore') { $currentversion = $admxversions.CustomPolicyStore.Version }
    $admx = Get-CustomPolicyAdmx -Version $currentversion -PolicyStore $PolicyStore -CustomPolicyStore $CustomPolicyStore -Languages $Languages
    if ($admx) { if ($admxversions.CustomPolicyStore) { $admxversions.CustomPolicyStore = $admx } else { $admxversions += @{ CustomPolicyStore = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

# Windows 10
if ($Include -notcontains 'Windows 10')
{
    Write-Verbose "`nSkipping Windows 10"
}
else
{
    Write-Verbose "`nProcessing Admx files for Windows 10 $($Windows10Version)"
    $admx = Get-WindowsAdmx -Version $admxversions.Windows10.Version -PolicyStore $PolicyStore -WindowsVersion $Windows10Version -WindowsEdition 10 -Languages $Languages
    if ($admx) { if ($admxversions.Windows10) { $admxversions.Windows10 = $admx } else { $admxversions += @{ Windows10 = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

# Windows 11
if ($Include -notcontains 'Windows 11')
{
    Write-Verbose "`nSkipping Windows 11"
}
else
{
    Write-Verbose "`nProcessing Admx files for Windows 11 $($Windows11Version)"
    $admx = Get-WindowsAdmx -Version $admxversions.Windows11.Version -PolicyStore $PolicyStore -WindowsVersion $Windows11Version -WindowsEdition 11 -Languages $Languages
    if ($admx) { if ($admxversions.Windows11) { $admxversions.Windows11 = $admx } else { $admxversions += @{ Windows11 = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

# Microsoft Edge (Chromium)
if ($Include -notcontains 'Microsoft Edge')
{
    Write-Verbose "`nSkipping Microsoft Edge (Chromium)"
}
else
{
    Write-Verbose "`nProcessing Admx files for Microsoft Edge (Chromium)"
    $admx = Get-MicrosoftEdgeAdmx -Version $admxversions.Edge.Version -PolicyStore $PolicyStore -Languages $Languages
    if ($admx) { if ($admxversions.Edge) { $admxversions.Edge = $admx } else { $admxversions += @{ Edge = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

# Microsoft OneDrive
if ($Include -notcontains 'Microsoft OneDrive')
{
    Write-Verbose "`nSkipping Microsoft OneDrive"
}
else
{
    Write-Verbose "`nProcessing Admx files for Microsoft OneDrive"
    $admx = Get-OneDriveAdmx -Version $admxversions.OneDrive.Version -PolicyStore $PolicyStore -PreferLocalOneDrive $PreferLocalOneDrive -Languages $Languages
    if ($admx) { if ($admxversions.OneDrive) { $admxversions.OneDrive = $admx } else { $admxversions += @{ OneDrive = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

# Microsoft Office
if ($Include -notcontains 'Microsoft Office')
{
    Write-Verbose "`nSkipping Microsoft Office"
}
else
{
    Write-Verbose "`nProcessing Admx files for Microsoft Office"
    $admx = Get-MicrosoftOfficeAdmx -Version $admxversions.Office.Version -PolicyStore $PolicyStore -Architecture "x64" -Languages $Languages
    if ($admx) { if ($admxversions.Office) { $admxversions.Office = $admx } else { $admxversions += @{ Office = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

# FSLogix
if ($Include -notcontains 'FSLogix')
{
    Write-Verbose "`nSkipping FSLogix"
}
else
{
    Write-Verbose "`nProcessing Admx files for FSLogix"
    $admx = Get-FSLogixAdmx -Version $admxversions.FSLogix.Version -PolicyStore $PolicyStore -Languages $Languages
    if ($admx) { if ($admxversions.FSLogix) { $admxversions.FSLogix = $admx } else { $admxversions += @{ FSLogix = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

# Adobe Acrobat
if ($Include -notcontains 'Adobe Acrobat')
{
    Write-Verbose "`nSkipping Adobe Acrobat"
}
else
{
    Write-Verbose "`nProcessing Admx files for Adobe Acrobat"
    $admx = Get-AdobeAcrobatAdmx -Version $admxversions.AdobeAcrobat.Version -PolicyStore $PolicyStore -Languages $Languages
    if ($admx) { if ($admxversions.AdobeAcrobat) { $admxversions.AdobeAcrobat = $admx } else { $admxversions += @{ AdobeAcrobat = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

# Adobe Reader
if ($Include -notcontains 'Adobe Reader')
{
    Write-Verbose "`nSkipping Adobe Reader"
}
else
{
    Write-Verbose "`nProcessing Admx files for Adobe Reader"
    $admx = Get-AdobeReaderAdmx -Version $admxversions.AdobeReader.Version -PolicyStore $PolicyStore -Languages $Languages
    if ($admx) { if ($admxversions.AdobeReader) { $admxversions.AdobeReader = $admx } else { $admxversions += @{ AdobeReader = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

# BIS-F
if ($Include -notcontains 'BIS-F')
{
    Write-Verbose "`nSkipping BIS-F"
}
else
{
    Write-Verbose "`nProcessing Admx files for BIS-F"
    $admx = Get-BIS-FAdmx -Version $admxversions.BISF.Version -PolicyStore $PolicyStore
    if ($admx) { if ($admxversions.BISF) { $admxversions.BISF = $admx } else { $admxversions += @{ BISF = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

# Citrix Workspace App
if ($Include -notcontains 'Citrix Workspace App')
{
    Write-Verbose "`nSkipping Citrix Workspace App"
}
else
{
    Write-Verbose "`nProcessing Admx files for Citrix Workspace App"
    $admx = Get-CitrixWorkspaceAppAdmx -Version $admxversions.CitrixWorkspaceApp.Version -PolicyStore $PolicyStore -Languages $Languages
    if ($admx) { if ($admxversions.CitrixWorkspaceApp) { $admxversions.CitrixWorkspaceApp = $admx } else { $admxversions += @{ CitrixWorkspaceApp = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

# Google Chrome
if ($Include -notcontains 'Google Chrome')
{
    Write-Verbose "`nSkipping Google Chrome"
}
else
{
    Write-Verbose "`nProcessing Admx files for Google Chrome"
    $admx = Get-GoogleChromeAdmx -Version $admxversions.GoogleChrome.Version -PolicyStore $PolicyStore -Languages $Languages
    if ($admx) { if ($admxversions.GoogleChrome) { $admxversions.GoogleChrome = $admx } else { $admxversions += @{ GoogleChrome = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

# Microsoft Desktop Optimization Pack
if ($Include -notcontains 'Microsoft Desktop Optimization Pack')
{
    Write-Verbose "`nSkipping Microsoft Desktop Optimization Pack"
}
else
{
    Write-Verbose "`nProcessing Admx files for Microsoft Desktop Optimization Pack"
    $admx = Get-MDOPAdmx -Version $admxversions.MDOP.Version -PolicyStore $PolicyStore -Languages $Languages
    if ($admx) { if ($admxversions.MDOP) { $admxversions.MDOP = $admx } else { $admxversions += @{ MDOP = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

# Mozilla Firefox
if ($Include -notcontains 'Mozilla Firefox')
{
    Write-Verbose "`nSkipping Mozilla Firefox"
}
else
{
    Write-Verbose "`nProcessing Admx files for Mozilla Firefox"
    $admx = Get-MozillaFirefoxAdmx -Version $admxversions.MozillaFirefox.Version -PolicyStore $PolicyStore -Languages $Languages
    if ($admx) { if ($admxversions.MozillaFirefox) { $admxversions.MozillaFirefox = $admx } else { $admxversions += @{ MozillaFirefox = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

# Zoom Desktop Client
if ($Include -notcontains 'Zoom Desktop Client')
{
    Write-Verbose "`nSkipping Zoom Desktop Client"
}
else
{
    Write-Verbose "`nProcessing Admx files for Zoom Desktop Client"
    $admx = Get-ZoomDesktopClientAdmx -Version $admxversions.ZoomDesktopClient.Version -PolicyStore $PolicyStore -Languages $Languages
    if ($admx) { if ($admxversions.ZoomDesktopClient) { $admxversions.ZoomDesktopClient = $admx } else { $admxversions += @{ ZoomDesktopClient = @{ Version = $admx.Version; URI = $admx.URI } } } }
}

Write-Verbose "`nSaving Admx versions to '$($WorkingDirectory)\admxversions.xml'"
$admxversions | Export-Clixml -Path "$($WorkingDirectory)\admxversions.xml" -Force