<#
.SYNOPSIS
    Powershell script to remap your GDAP relationships

.DESCRIPTION
    Powershell script to remap your GDAP relationships

.NOTES
    Version:          1.0
    Author:           Roel van der Wegen
    Creation Date:    03/03/2024
    Github:           https://github.com/rvdwegen/Partner-Management
    Purpose/Change:   Initial script (re)development
#>

#region manual input

# Remove all current accessAssignments
$removeCurrentAssignments = $false

# Define tenants to re-do, if left empty script will retrieve a full list by itself.
[array]$tenants = @(
    #'tenantid1here',
    #'tenantid2here',
	#'tenantidetcetchere', # last one can't have a comma
) | ForEach-Object { if (![guid]::TryParse($_, $([ref][guid]::Empty))) { throw "Invalid GUID: $_" } else { $_ } }

# Build accessAssignments
# Blog link to section here
# https://learn.microsoft.com/en-us/graph/api/delegatedadminrelationship-post-accessassignments?view=graph-rest-1.0&tabs=http#request
# https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference
$accessAssignments = @(
    @{
        accessContainer = @{
            accessContainerId = "00000000-0000-0000-0000-000000000001" # objectId of the group in your Entra
            accessContainerType = "securityGroup"
        }
        accessDetails = @{
            # unifiedRoles is an array and will accept multiple values.
            unifiedRoles = @(
                "62e90394-69f5-4237-9190-012177145e10" # Global Administrator, keep in mind that GA being present in the relationship means you cannnot auto extend it,
            )
        }
    },
    @{
        accessContainer = @{
            accessContainerId = "00000000-0000-0000-0000-000000000002" # objectId of the group in your Entra
            accessContainerType = "securityGroup"
        }
        accessDetails = @{
            # unifiedRoles is an array and will accept multiple values.
            unifiedRoles = @(
                "f2ef992c-3afb-46b9-b7cf-a126ee74c451" # Global Reader, great fallback in case other roles have been implemented improperly.
            )
        }
    } # Copy/paste per @{} and change the accessContainerId and unifiedRoles values.
)

#endregion

#region Authentication

try {
    # Authenticate to tenant using MSAL.PS and the "vdwegen - GDAP Management App"
    try {
        $msalTokenSplat = @{
            TenantId = if ($Env:OS -eq "Windows_NT" -OR $IsWindows) { (whoami /upn).Split('@')[1] } else { Read-Host -Prompt "Enter TenantId or verified domain" }
            Scopes = "DelegatedAdminRelationship.ReadWrite.All"
            ClientId = "7146d3ef-b8bf-4d5f-adde-b1b402906326" # Note, I created my own multi-tenant app for this for convenience sake. See the blogpost on the base requirements to use this script. {Insert blogpost link later}
        }

        $graphToken = (Get-MsalToken @msalTokenSplat  -Interactive).CreateAuthorizationHeader()

        $graphHeader = @{
            "Authorization"          = $graphToken
            "Content-type"           = "application/json"
            "X-Requested-With"       = "XMLHttpRequest"
        }
    } catch {
        throw "Failed to authenticate to tenant $($msalTokenSplat.TenantId): $($_.Exception.Message)"
    }

    try {
        # Retrieve all tenants if $tenants array is empty
        if (!$tenants) {
            # Page this
            $tenants = (Invoke-RestMethod -Method "GET" -Headers $graphHeader -Uri "https://graph.microsoft.com/beta/tenantRelationships/delegatedAdminCustomers").value.tenantId
        }
    } catch {
        throw "Failed to retrieve tenants: $($_.Exception.Message)"
    }

    try {
        # Retrieve all active relationships
        # Page this
        $relationships = (Invoke-RestMethod -Method "GET" -Headers $graphHeader -Uri "https://graph.microsoft.com/beta/tenantRelationships/delegatedAdminRelationships?`$filter=(status eq 'active')").value
    } catch {
        throw "Failed to retrieve relationships: $($_.Exception.Message)"
    }

    # Check if all accessContainerIds can be matched to a group in Entra
    foreach ($group in $accessAssignments.accessContainer.accessContainerId) {
        try {
            $groupObject = (Invoke-RestMethod -Method "GET" -Headers $graphHeader -Uri "https://graph.microsoft.com/v1.0/directoryObjects/{$($group)")
        } catch {
            throw "Failed to find group $($group) in Entra: $($_.Exception.Message)"
        }
    }
} catch {
    throw $($_.Exception.Message)
}

#endregion

#region Processing

# loop through tenants
foreach ($tenant in $tenants) {

    $tenantRelationships = $relationships | Where-Object { $_.customer.tenantId -eq $tenant }
    if (!$tenantRelationships) {
        Write-Host "Skipping tenant $($tenant) because no valid relationships were found"
        Continue # Skip this tenant
    } else {
        # Loop through the active relationships
        foreach ($tenantRelationship in $tenantRelationships) {
            # Warn/skip if the relationship is a Microsoft Led Transition one
            if ($tenantRelationship.displayName -like "MTL_*") {
                Write-Warning "Skipping relationship $($tenantRelationship.displayName) for tenant $($tenantRelationship.customer.displayName) because it is a Microsoft Led Transition one and is unlikely to contain the needed roles. It is recommended to terminate this relationship and/or replace it with a new one."
                Continue
            }

            # Warn if the relationship is a Lighthouse one
            if ($tenantRelationship.displayName -like "LH_*") {
                Write-Warning "Relationship $($tenantRelationship.displayName) for tenant $($tenantRelationship.customer.displayName) was created using Lighthouse. Due to the nature of the lighthouse tool it may not contain the required roles."
            }

            # Warn if the relationship expires within 60 days
            if ($tenantRelationship.endDateTime -le ((Get-Date).AddDays(60))) {
                Write-Warning "Relationship $($tenantRelationship.displayName) for tenant $($tenantRelationship.customer.displayName) will expire within 60 days"
            }

            # Process relationships
            try {
                Write-Host "processing relationship $($tenantRelationship.displayName) for tenant $($tenantRelationship.customer.displayName)"

                # Remove all current access assignments on $tenantRelationship
                if ($removeCurrentAssignments) {
                    # Get current access assignments
                    # Page this
                    $accessAssignments = (Invoke-RestMethod -Method "GET" -Headers $graphHeader -Uri "https://graph.microsoft.com/beta/tenantRelationships/delegatedAdminRelationships/$($tenantRelationship.id)/accessAssignments?`$filter=(status eq 'active')").value

                    # Loop through current access assignments
                    foreach ($assignment in $accessAssignments) {
                        try {
                            $ifmatchheaders = $null
                            $ifmatchheaders = @{
                                Authorization = 'bearer {0}' -f $graphToken
                                Accept = "application/json"
                                "If-Match" = $assignment.'@odata.etag'
                            }
                            $removeaccess = Invoke-RestMethod -Method DELETE -Uri "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$($tenantRelationship.id)/accessAssignments/$($assignment.id)" -Headers $ifmatchheaders
                        } catch {
                            Write-Error "Unable to delete (all) current Access Assignment(s) for $($relation.id): $($_.Exception.Message)"
                        }
                    }

                    # Small delay to prevent cached overlap with the new assignment(s)
                    Start-Sleep -Seconds 5
                }

                # Loop through accessAssignments array and create the needed assignments
                foreach ($accessAssignment in $accessAssignments) {
                    try {
                        $newaccess = Invoke-RestMethod -Method POST -Body ($accessAssignment | ConvertTo-Json -Depth 5) -Uri "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships/$($tenantRelationship.id)/accessAssignments" -Headers $graphHeader -ContentType "application/json"
                    } catch {
                        Write-Error "Unable to create Access Assignment for $($relation.id): $($_.Exception.Message)"
                    }
                }
            } catch {
                throw "top level error: $($_.Exception.Message)"
            }
        }
    }
}

#endregion
