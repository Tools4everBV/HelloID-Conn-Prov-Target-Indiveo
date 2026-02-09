#################################################
# HelloID-Conn-Prov-Target-Indiveo-Create
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
    # Initial Assignments
    $outputContext.AccountReference = 'Currently not available'

    # Adding headers
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add('Authorization', "Bearer $($actionContext.Configuration.Token)")

    # Validate correlation configuration
    if ($actionContext.CorrelationConfiguration.Enabled) {
        $correlationField = $actionContext.CorrelationConfiguration.AccountField
        $correlationValue = $actionContext.CorrelationConfiguration.PersonFieldValue


        if ([string]::IsNullOrEmpty($($correlationField))) {
            throw 'Correlation is enabled but not configured correctly'
        }
        if ([string]::IsNullOrEmpty($($correlationValue))) {
            throw 'Correlation is enabled but [accountFieldValue] is empty. Please make sure it is correctly mapped'
        }

        # Determine if a user needs to be [created] or [correlated]
        Write-Information "Verifying if a Indiveo account exists where $correlationField is: [$correlationValue]"
        $splatGetAccount = @{
            Uri     = "$($actionContext.configuration.BaseUrl)/scim/v2/Users?filter=urn:ietf:params:scim:schemas:core:2.0:User:userName%20eq%20%22$correlationValue%22"
            Method  = 'GET'
            Headers = $headers
        }
        $response = Invoke-RestMethod @splatGetAccount
    }

    if ($response.Resources.count -eq 0) {
        $action = 'CreateAccount'
    }
    elseif ($response.Resources.Count -eq 1) {
        $correlatedAccount = $response.Resources[0]
        $action = 'CorrelateAccount'

    }
    elseif ($response.Resources.Count -gt 1) {
        throw "Multiple accounts found for person where $correlationField is: [$correlationValue]"
    }

    # Process
    switch ($action) {
        'CreateAccount' {
            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information 'Creating and correlating Indiveo account'
                $splatCreateParams = @{
                    Uri     = "$($actionContext.configuration.BaseUrl)/scim/v2/Users"
                    Method  = 'POST'
                    Body    = [ordered]@{
                        schemas  = @(
                            'urn:ietf:params:scim:schemas:core:2.0:User',
                            'urn:ietf:params:scim:schemas:extension:enterprise:2.0:User'
                        )
                        userName = $actionContext.Data.UserName
                        active   = $false
                        meta     = @{
                            resourceType = 'User'
                        }
                        name     = [ordered]@{
                            familyName = $actionContext.Data.FamilyName
                            givenName  = $actionContext.Data.GivenName
                        }
                    } | ConvertTo-Json
                    Headers = $headers
                    ContentType = 'application/scim+json'
                }
                $createdAccount = Invoke-RestMethod @splatCreateParams
                $outputContext.Data = ConvertTo-HelloIDAccountObject -AccountObject $createdAccount
                $outputContext.AccountReference = $createdAccount.Id
            }
            else {
                Write-Information '[DryRun] Create and correlate Indiveo account, will be executed during enforcement'
            }
            $auditLogMessage = "Create account was successful. AccountReference is: [$($outputContext.AccountReference)]"
            break
        }

        'CorrelateAccount' {
            Write-Information 'Correlating Indiveo account'
            $outputContext.Data = ConvertTo-HelloIDAccountObject -AccountObject $correlatedAccount
            $outputContext.AccountReference = $correlatedAccount.Id
            $outputContext.AccountCorrelated = $true
            $auditLogMessage = "Correlated account: [$($outputContext.AccountReference)] on field: [$($correlationField)] with value: [$($correlationValue)]"
            break
        }
    }

    $outputContext.success = $true
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = $action
            Message = $auditLogMessage
            IsError = $false
        })
}
catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-GenericScimError -ErrorObject $ex
        $auditLogMessage = "Could not create or correlate Indiveo account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not create or correlate Indiveo account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}