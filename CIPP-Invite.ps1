# Auth
Connect-AzAccount

# Select CIPP instance
$count = 0
do {
    $count++
    $getSubscription = Get-AzSubscription | Out-GridView -Title "Select Azure Subscription" -OutputMode Single
    Set-AzContext -Subscription $getSubscription.SubscriptionId | Out-Null
    $cipp = Get-AzStaticWebApp | Select-Object Name,DefaultHostName,ResourceGroupName | Out-GridView -Title "Select CIPP app" -OutputMode Single

} until ($cipp -OR $count -ge 5)
if (!$cipp) {
    Write-Host "CIPP instance was not selected, exiting..."
    Pause
    Return
}

# Select role
$role = @(
    [pscustomobject]@{
        RoleName = "readonly"
        Description = "Only allowed to read and list items and send push messages to users."
    },
    [pscustomobject]@{
        RoleName = "editor"
        Description = "Allowed to perform everything, except editing tenants, exclusions, and standards."
    },
    [pscustomobject]@{
        RoleName = "admin"
        Description = "Allowed to perform everything."
    }
) | Out-GridView -Title "Select role for invites" -OutputMode Single
if (!$role) {
    Write-Host "A role was not selected, exiting..."
    Pause
    Return
}

# Select user(s)
$users = Get-AzADUser | Out-GridView -Title "Select users to invite" -OutputMode Multiple
if (!$users) {
    Write-Host "Users were not selected, exiting..."
    Pause
    Return
}

# Process invites
$invites = foreach ($user in $users) {
    try {
        $splat = @{
            ResourceGroupName = $cipp.ResourceGroupName
            Name = $cipp.Name
            Domain = $cipp.DefaultHostName
            Provider = 'aad'
            UserDetail = $user.UserPrincipalName
            Role = $role.RoleName
            NumHoursToExpiration = 1
        }
    
        $invite = New-AzStaticWebAppUserRoleInvitationLink @splat
        Write-Host "Generated invite for $($user.UserPrincipalName)"
    
        [pscustomobject]@{
            User = $user.UserPrincipalName
            InviteURL = $invite.InvitationUrl
        }
    } catch {
        Write-Warning "Failed to invite $($user.UserPrincipalName): $($_.Exception.Message)"
    }
}

# Export invites
$invites | Export-Csv -Path "C:\temp\cippinvites.csv" -NoTypeInformation
