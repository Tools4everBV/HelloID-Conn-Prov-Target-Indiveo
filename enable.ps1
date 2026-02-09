##################################################
# HelloID-Conn-Prov-Target-Indiveo-Enable
# PowerShell V2
##################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

#region functions
function Resolve-GenericScimError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }
        try {
            $errorDetailsObject = ($httpErrorObj.ErrorDetails | ConvertFrom-Json)
            $httpErrorObj.FriendlyMessage = $errorDetailsObject.detail
        }
        catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
        }
        Write-Output $httpErrorObj
    }
}
#endregion

try {
    # Verify if [aRef] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    # Adding headers
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add('Authorization', "Bearer $($actionContext.Configuration.Token)")

    Write-Information 'Verifying if a Indiveo account exists'
    $splatGetUser = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/scim/v2/Users/$($actionContext.References.Account)"
        Method  = 'GET'
        Headers = $headers
    }
    $correlatedAccount = Invoke-RestMethod @splatGetUser

    if ($null -ne $correlatedAccount) {
        $action = 'EnableAccount'
    }
    else {
        $action = 'NotFound'
    }

    # Process
    switch ($action) {
        'EnableAccount' {
            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Disabling Indiveo account with accountReference: [$($actionContext.References.Account)]"
                [System.Collections.Generic.List[object]]$operations = @()
                $operations.Add(
                    [PSCustomObject]@{
                        op    = 'Replace'
                        path  = 'active'
                        value = $true
                    }
                )
                $body = [ordered]@{
                    schemas    = @(
                        'urn:ietf:params:scim:api:messages:2.0:PatchOp'
                    )
                    Operations = $operations
                } | ConvertTo-Json

                $splatEnableParams = @{
                    Uri         = "$($actionContext.Configuration.BaseUrl)/scim/v2/Users/$($actionContext.References.Account)"
                    Headers     = $headers
                    Body        = $body
                    Method      = 'PATCH'
                    ContentType = 'application/scim+json'
                }
                $null = Invoke-RestMethod @splatEnableParams
            }
            else {
                Write-Information "[DryRun] Enable Indiveo account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Enable account [$($actionContext.References.Account)] was successful. Action initiated by: [$($actionContext.Origin)]"
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "Indiveo account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Indiveo account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted. Action initiated by: [$($actionContext.Origin)]"
                    IsError = $false
                })
            break
        }
    }
}
catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-GenericScimError -ErrorObject $ex
        $auditLogMessage = "Could not enable Indiveo account. Error: $($errorObj.FriendlyMessage). Action initiated by: [$($actionContext.Origin)]"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not enable Indiveo account. Error: $($_.Exception.Message). Action initiated by: [$($actionContext.Origin)]"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}