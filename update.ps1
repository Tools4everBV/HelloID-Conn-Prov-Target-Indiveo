#################################################
# HelloID-Conn-Prov-Target-Indiveo-Update
# PowerShell V2
#################################################

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

function ConvertTo-HelloIDAccountObject {
    param (
        [Parameter(Mandatory)]
        [object]$AccountObject
    )

    [PSCustomObject]@{
        id         = $AccountObject.id
        userName   = $AccountObject.'urn:ietf:params:scim:schemas:core:2.0:User'.userName
        givenName  = $AccountObject.'urn:ietf:params:scim:schemas:core:2.0:User'.name.givenName
        familyName = $AccountObject.'urn:ietf:params:scim:schemas:core:2.0:User'.name.familyName
        active     = $AccountObject.'urn:ietf:params:scim:schemas:core:2.0:User'.active
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
    $targetAccount = Invoke-RestMethod @splatGetUser
    $correlatedAccount = ConvertTo-HelloIDAccountObject -AccountObject $targetAccount
    $correlatedAccount.PSObject.Properties.Remove('active')
    $outputContext.PreviousData = $correlatedAccount

    if ($null -ne $correlatedAccount) {
        $splatCompareProperties = @{
            ReferenceObject  = @($correlatedAccount.PSObject.Properties)
            DifferenceObject = @($actionContext.Data.PSObject.Properties)
        }
        $propertiesChanged = Compare-Object @splatCompareProperties -PassThru | Where-Object { $_.SideIndicator -eq '=>' }
        if ($propertiesChanged) {
            $action = 'UpdateAccount'
        }
        else {
            $action = 'NoChanges'
        }
    }
    else {
        $action = 'NotFound'
    }

    # Process
    switch ($action) {
        'UpdateAccount' {
            Write-Information "Account property(s) required to update: $($propertiesChanged.Name -join ', ')"
            [System.Collections.Generic.List[object]]$operations = @()
            foreach ($property in $propertiesChanged) {
                switch ($property.Name) {
                    'Username' {
                        $operations.Add(
                            [PSCustomObject]@{
                                op    = 'Replace'
                                path  = 'userName'
                                value = $property.Value
                            }
                        )
                    }
                    'GivenName' {
                        $operations.Add(
                            [PSCustomObject]@{
                                op    = 'Replace'
                                path  = 'name.givenName'
                                value = $property.Value
                            }
                        )
                    }
                    'FamilyName' {
                        $operations.Add(
                            [PSCustomObject]@{
                                op    = 'Replace'
                                path  = 'name.familyName'
                                value = $property.Value
                            }
                        )
                    }
                }
            }

            $body = [ordered]@{
                schemas    = @(
                    'urn:ietf:params:scim:api:messages:2.0:PatchOp'
                )
                Operations = $operations
            } | ConvertTo-Json

            $splatUpdateParams = @{
                Uri         = "$($actionContext.Configuration.BaseUrl)/scim/v2/Users/$($actionContext.References.Account)"
                Headers     = $headers
                Body        = $body
                Method      = 'PATCH'
                ContentType = 'application/scim+json'
            }

            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Updating Indiveo account with accountReference: [$($actionContext.References.Account)]"
                $null = Invoke-RestMethod @splatUpdateParams

            }
            else {
                Write-Information "[DryRun] Update Indiveo account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Update account was successful, Account property(s) updated: [$($propertiesChanged.name -join ',')]"
                    IsError = $false
                })
            break
        }

        'NoChanges' {
            Write-Information "No changes to Indiveo account with accountReference: [$($actionContext.References.Account)]"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Skipped updating Indiveo account with AccountReference: [$($actionContext.References.Account)]. Reason: No changes."
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "Indiveo account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
            $outputContext.Success = $false
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Indiveo account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
                    IsError = $true
                })
            break
        }
    }
}
catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-GenericScimError -ErrorObject $ex
        $auditLogMessage = "Could not update Indiveo account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not update Indiveo account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}
