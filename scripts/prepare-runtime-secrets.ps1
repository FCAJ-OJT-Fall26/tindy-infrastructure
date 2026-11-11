[CmdletBinding()]
param(
    [string]$AwsProfile = 'tindy-admin'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-TindyAws {
    param([string[]]$Arguments, [switch]$AllowMissingSecret)

    $response = & aws @Arguments --profile $AwsProfile --region us-east-1 --output json --no-cli-pager 2>&1
    $exitCode = $LASTEXITCODE
    $responseText = $response -join "`n"
    if ($exitCode -ne 0) {
        if ($AllowMissingSecret -and $responseText -match 'ResourceNotFoundException') { return $null }
        throw "AWS $($Arguments[0]) $($Arguments[1]) failed: $responseText"
    }

    return $responseText | ConvertFrom-Json -AsHashtable
}

function Get-StackOutputs {
    param([string]$StackName)

    $stack = (Invoke-TindyAws -Arguments @('cloudformation', 'describe-stacks', '--stack-name', $StackName)).Stacks[0]
    $outputs = @{}
    foreach ($output in $stack.Outputs) { $outputs[$output.OutputKey] = $output.OutputValue }
    return $outputs
}

function Get-OrCreateSecret {
    param([string]$SecretName)

    $secret = Invoke-TindyAws -Arguments @('secretsmanager', 'describe-secret', '--secret-id', $SecretName) -AllowMissingSecret
    if ($null -eq $secret) {
        $created = Invoke-TindyAws -Arguments @('secretsmanager', 'create-secret', '--name', $SecretName)
        return @{ ARN = $created.ARN; VersionIdsToStages = @{} }
    }
    return $secret
}

function Initialize-Secret {
    param([System.Collections.IDictionary]$Secret, [scriptblock]$CreateValue)

    foreach ($stages in $Secret.VersionIdsToStages.Values) {
        if ($stages -contains 'AWSCURRENT') { return }
    }

    # A fixed version ID prevents concurrent first runs from writing different initial values.
    $tokenBytes = [Text.Encoding]::UTF8.GetBytes("Tindy/Fresh/v1/$($Secret.ARN)")
    $versionId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($tokenBytes)).ToLowerInvariant()
    $secretFile = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($secretFile, (& $CreateValue))
        Invoke-TindyAws -Arguments @('secretsmanager', 'put-secret-value', '--secret-id', $Secret.ARN,
            '--client-request-token', $versionId, '--secret-string', "file://$secretFile") | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $secretFile -ErrorAction SilentlyContinue
    }
}

function New-DatabaseSecretValue {
    param([string]$Username)

    $password = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    $connectionString = "Host=$dbEndpoint;Port=5432;Database=tindy;Username=$Username;Password=$password;SSL Mode=VerifyFull;Root Certificate=/app/certs/rds-us-east-1-bundle.crt"
    return @{ password = $password; connectionString = $connectionString } | ConvertTo-Json -Compress
}

$database = Get-StackOutputs -StackName 'tindy-database'
if ($database.DBProvisionMode -ne 'Fresh' -or $database.DBEndpointPort -ne '5432' -or -not $database.DBMasterSecretArn) {
    throw 'This script initializes only the Fresh Tindy database on port 5432.'
}
$dbEndpoint = $database.DBEndpointAddress
if ($dbEndpoint -notmatch '^[a-z0-9.-]+\.rds\.amazonaws\.com$') { throw 'Unexpected RDS endpoint.' }

$service = (Invoke-TindyAws -Arguments @('ecs', 'describe-services', '--cluster', 'tindy-runtime', '--services', 'tindy-api')).services[0]
if ($null -eq $service -or $service.desiredCount -ne 0 -or $service.runningCount -ne 0 -or $service.pendingCount -ne 0) {
    throw 'Initialize secrets while the Tindy API service is at 0 desired, running, and pending tasks.'
}

$foundation = Get-StackOutputs -StackName 'tindy-foundation'
$apiDbSecret = Invoke-TindyAws -Arguments @('secretsmanager', 'describe-secret', '--secret-id', $foundation.DatabaseConnectionSecretArn)
$jwtSecret = Invoke-TindyAws -Arguments @('secretsmanager', 'describe-secret', '--secret-id', $foundation.JwtSigningKeySecretArn)
$migrationSecret = Get-OrCreateSecret -SecretName 'tindy/database/migration-connection'
$seedSecret = Get-OrCreateSecret -SecretName 'tindy/database/seed-password'

Initialize-Secret -Secret $apiDbSecret -CreateValue { New-DatabaseSecretValue -Username 'tindy_api' }
Initialize-Secret -Secret $migrationSecret -CreateValue { New-DatabaseSecretValue -Username 'tindy_migrator' }
Initialize-Secret -Secret $jwtSecret -CreateValue { [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) }
Initialize-Secret -Secret $seedSecret -CreateValue { [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)) + '!a1' }

[pscustomobject]@{
    DBEndpointAddress = $dbEndpoint
    DBMasterSecretArn = $database.DBMasterSecretArn
    MigrationConnectionSecretArn = $migrationSecret.ARN
    SeedPasswordSecretArn = $seedSecret.ARN
}
