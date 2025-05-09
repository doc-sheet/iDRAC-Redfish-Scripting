<#
_author_ = Texas Roemer <Texas_Roemer@Dell.com>
_version_ = 1.0

Copyright (c) 2024, Dell, Inc.

This software is licensed to you under the GNU General Public License,
version 2 (GPLv2). There is NO WARRANTY for this software, express or
implied, including the implied warranties of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. You should have received a copy of GPLv2
along with this software; if not, see
http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt
#>

<#
.Synopsis
   iDRAC cmdlet using Redfish API with OEM extension to run remote diagnostics on the server. Once remote diags has been performed you can export diag results locally or a network share to review. 
.DESCRIPTION
   iDRAC cmdlet using Redfish API with OEM extension to run remote diagnostics on the server. Once remote diags has been performed you can export diag results locally or a network share to review.
   Supported parameters to pass in for cmdlet:
   
   - idrac_ip: Pass in iDRAC IP
   - idrac_username: Pass in iDRAC username
   - idrac_password: Pass in iDRAC password
   - x_auth_token: Pass in iDRAC X-Auth token session to execute cmdlet instead of username / password (recommended)
   - run_diags: Perform remote diags on the server.
   - reboot_type: Pass in server reboot job type. Server reboot is required to start running remote diags. Supported values: GracefulRebootWithForcedShutdown, GracefulRebootWithoutForcedShutdown or PowerCycle. 
   - run_mode: Pass in the run mode type you want to execute for diags. Supported values: Express, ExpressAndExtended and Extended
   - export: Export diag results locally or network share.
   - network_share_IPAddress: Pass in network share IP address 
   - ShareName: Pass in network share name 
   - ShareType: Pass in network share type. Supported values: Local, NFS, CIFS, HTTP and HTTPS 
   - FileName: Pass in unique name for exporting diags results to a network share. Note this argument not required for exporting locally.  
   - share_username: If your network share has auth enabled, pass in username
   - share_password: If your network share has auth enabled, pass in username password

.EXAMPLE
   Invoke-RemoteDiagsREDFISH -idrac_ip 192.168.0.120 -idrac_username root -idrac_password calvin -run_diags -reboot_type PowerCycle -run_mode Express 
   This example shows performing server power cycle to run express remote diags.
.EXAMPLE
   Invoke-RemoteDiagsREDFISH -idrac_ip 192.168.0.120 -idrac_username root -idrac_password calvin -export -ShareType Local
   This example shows exporting remote diags results locally using default browser.
.EXAMPLE
   Invoke-RemoteDiagsREDFISH -idrac_ip 192.168.0.120 -idrac_username root -idrac_password calvin -export -ShareType NFS -network_share_IPAddress 192.168.0.130 -ShareName /nfs -FileName diags_results.txt
   This example shows exporting remote diags results to a NFS share.
#>

function Invoke-RemoteDiagsREDFISH {

param(
    [Parameter(Mandatory=$True)]
    [string]$idrac_ip,
    [Parameter(Mandatory=$False)]
    [string]$idrac_username,
    [Parameter(Mandatory=$False)]
    [string]$idrac_password,
    [Parameter(Mandatory=$False)]
    [string]$x_auth_token,
    [Parameter(Mandatory=$False)]
    [switch]$run_diags,
    [ValidateSet("GracefulRebootWithForcedShutdown", "GracefulRebootWithoutForcedShutdown", "PowerCycle")]
    [Parameter(Mandatory=$False)]
    [string]$reboot_type,
    [ValidateSet("Express", "ExpressAndExtended", "Extended")]
    [Parameter(Mandatory=$False)]
    [string]$run_mode,
    [Parameter(Mandatory=$False)]
    [switch]$export,
    [ValidateSet("Local", "NFS", "CIFS", "HTTP", "HTTPS")]
    [Parameter(Mandatory=$False)]
    [string]$ShareType,
    [Parameter(Mandatory=$False)]
    [string]$ShareName,
    [Parameter(Mandatory=$False)]
    [string]$network_share_IPAddress,
    [Parameter(Mandatory=$False)]
    [string]$FileName,
    [Parameter(Mandatory=$False)]
    [string]$share_username,
    [Parameter(Mandatory=$False)]
    [string]$share_password
    )


# Function to ignore SSL certs

function Ignore-SSLCertificates
{
    $Provider = New-Object Microsoft.CSharp.CSharpCodeProvider
    $Compiler = $Provider.CreateCompiler()
    $Params = New-Object System.CodeDom.Compiler.CompilerParameters
    $Params.GenerateExecutable = $false
    $Params.GenerateInMemory = $true
    $Params.IncludeDebugInformation = $false
    $Params.ReferencedAssemblies.Add("System.DLL") > $null
    $TASource=@'
        namespace Local.ToolkitExtensions.Net.CertificatePolicy
        {
            public class TrustAll : System.Net.ICertificatePolicy
            {
                public bool CheckValidationResult(System.Net.ServicePoint sp,System.Security.Cryptography.X509Certificates.X509Certificate cert, System.Net.WebRequest req, int problem)
                {
                    return true;
                }
            }
        }
'@ 
    $TAResults=$Provider.CompileAssemblyFromSource($Params,$TASource)
    $TAAssembly=$TAResults.CompiledAssembly
    $TrustAll = $TAAssembly.CreateInstance("Local.ToolkitExtensions.Net.CertificatePolicy.TrustAll")
    [System.Net.ServicePointManager]::CertificatePolicy = $TrustAll
}

# Function to set up iDRAC credentials 

function setup_idrac_creds
{

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::TLS12

if ($x_auth_token)
{
$global:x_auth_token = $x_auth_token
}
elseif ($idrac_username -and $idrac_password)
{
$user = $idrac_username
$pass= $idrac_password
$secpasswd = ConvertTo-SecureString $pass -AsPlainText -Force
$global:credential = New-Object System.Management.Automation.PSCredential($user, $secpasswd)
}
else
{
$get_creds = Get-Credential
$global:credential = New-Object System.Management.Automation.PSCredential($get_creds.UserName, $get_creds.Password)
}
}

# Function to get Powershell version

function get_powershell_version 
{
$get_host_info = Get-Host
$major_number = $get_host_info.Version.Major
$global:get_powershell_version = $major_number
}


# Function to run remote diags

function execute_remote_diags
{

$Global:create_job_success = "yes"
$create_payload = @{"RebootJobType"=$reboot_type;"RunMode"=$run_mode}

$JsonBody = $create_payload | ConvertTo-Json -Compress

$uri = "https://$idrac_ip/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellLCService/Actions/DellLCService.RunePSADiagnostics"

if ($x_auth_token)
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $post_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $post_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}


else
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $post_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $post_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}


if ($post_result.StatusCode -eq 202 -or $post_result.StatusCode -eq 200)
{
    $job_id_search=$post_result.Headers['Location']
    $Global:job_id=$job_id_search.Split("/")[-1]
    [String]::Format("`n- PASS, statuscode {0} returned successfully for POST command to create update job ID '{1}'",$post_result.StatusCode, $Global:job_id)
    Write-Host
    return
}
else
{
    [String]::Format("- FAIL, statuscode {0} returned. Detail error message: {1}",$post_result.StatusCode,$post_result)
    break
}

}

function export_remote_diags_results
{

$create_payload = @{}

if ($ShareType)
{
$create_payload["ShareType"]=$ShareType
}
if ($network_share_IPAddress)
{
$create_payload["IPAddress"]=$network_share_IPAddress
}
if ($ShareName)
{
$create_payload["ShareName"]=$ShareName
}
if ($FileName)
{
$create_payload["FileName"]=$FileName
}
if ($share_password)
{
$create_payload["Password"]=$share_password
}
if ($share_username)
{
$create_payload["Username"]=$share_username
}

$JsonBody = $create_payload | ConvertTo-Json -Compress

$uri = "https://$idrac_ip/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellLCService/Actions/DellLCService.ExportePSADiagnosticsResult"
$Global:create_job_success = "no"

if ($x_auth_token)
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $post_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $post_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}


else
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $post_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $post_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}

if ($ShareType -eq "Local")
{
    if ($post_result.StatusCode -eq 202 -or $post_result.StatusCode -eq 200)
    {
    $diags_export_local_uri = $post_result.Headers.Location
    $uri = "https://$idrac_ip$diags_export_local_uri"
    Start-Sleep 3
    start $uri
    }
    else
    {
    [String]::Format("- FAIL, statuscode {0} returned. Detail error message: {1}",$post_result.StatusCode,$post_result)
    break
    }

}
else
{
    if ($post_result.StatusCode -eq 202 -or $post_result.StatusCode -eq 200)
    {
    $job_id_search = $post_result.Headers.Location
    $Global:job_id = $job_id_search.Split("/")[-1]
    [String]::Format("`n- PASS, statuscode {0} returned successfully for POST command to create update job ID '{1}'",$post_result.StatusCode, $Global:job_id)
    $Global:create_job_success = "yes"
    }
    else
    {
    [String]::Format("- FAIL, statuscode {0} returned. Detail error message: {1}",$post_result.StatusCode,$post_result)
    return
}
}

}


function loop_job_status
{
if ($Global:create_job_success -eq "no")
{
return
}
Write-Host "- INFO, script will now loop polling the job status until marked completed`n"
while ($true)
{
$loop_time = Get-Date
$uri ="https://$idrac_ip/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/Jobs/$Global:job_id"

    if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

else
{
    try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    $RespErr
    return
    }
}
$get_output = $result.Content | ConvertFrom-Json
$job_message = $get_output.Message
$job_message = $job_message.ToLower()

if ($get_output.JobState -eq "Completed")
{
Write-Host "- PASS, $job_message"
break
}
elseif ($get_output.JobState -eq "Failed" -or $job_message.Contains.("fail") -or $job_message.Contains("error"))
{
Write-Host ("- FAIL, job ID final results detected an error")
$get_output
return
}
else
{
Write-Host "- INFO, job ID not marked completed, polling job status again"
Start-Sleep 10
}

}

}


# Run cmdlet

get_powershell_version
setup_idrac_creds

# Check to validate iDRAC version detected supports this feature

$uri = "https://$idrac_ip/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellLCService"
 if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    }
    }
    catch
    {
    $RespErr
    Write-Host "`n- WARNING, iDRAC version detected does not support this feature using Redfish API or incorrect iDRAC user credentials passed in.`n"
    return
    }
}

else
{
    try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

if ($result.StatusCode -eq 200 -or $result.StatusCode -eq 202)
{
$get_actions = $result.Content | ConvertFrom-Json
$run_diags_action_name = "#DellLCService.RunePSADiagnostics"
$validate_supported_idrac = $get_actions.Actions.$run_diags_action_name
    try
    {
    $test = $validate_supported_idrac.GetType()
    }
    catch
    {
    Write-Host "`n- WARNING, iDRAC version detected does not support this feature using Redfish API or incorrect iDRAC user credentials passed in.`n"
    return
    }
}
else
{
Write-Host "`n- WARNING, iDRAC version detected does not support this feature using Redfish API or incorrect iDRAC user credentials passed in.`n"
return
}

if ($run_diags -and $reboot_type -and $run_mode)
{
execute_remote_diags
loop_job_status
}
elseif ($export -and $ShareType)
{
export_remote_diags_results

if ($ShareType -ne "Local")
    {
    loop_job_status
    }
}

else
{
Write-Host "- FAIL, either incorrect parameter(s) used or missing required parameters(s)"
}


}










