Param(
    #will accept multiple image IDs
    [string[]][Parameter(Mandatory=$True)] $image
)
#can share multiple imageID -image ami-1234567 ami-987654 etc

Function GetImageWhenReady()
{
    Param(
        [string][Parameter(Mandatory=$True)] $newAMI
    )
        
    Write-Host "Waiting for new image to be available ($newAMI)" -NoNewline -ForegroundColor Yellow

    #Loop will stay here indefinitely checking, until AMI state is 'available'
    While((Get-EC2Image -ImageId $newAMI).State -ne "available") {  
            Start-Sleep -s 10
            Write-Host "." -NoNewline -ForegroundColor Yellow
        }
    Write-Host ""
}

# Set profile for non-prod AMIs, assume cie/CieAdministrators role in dev-nimbus
Initialize-AWSDefaults -ProfileName intranet -Region us-east-1
$Creds = (Use-STSRole -RoleArn "arn:aws:iam::911712956223:role/Axial-Administrator" -RoleSessionName "cloud").Credentials
Set-AWSCredentials -SecretKey $Creds.SecretAccessKey -AccessKey $Creds.AccessKeyId -SessionToken $Creds.SessionToken -Verbose 

#initialize array for new AMIs
#$ImageList = [System.Collections.ArrayList]@()

#Add permissions to us-east-1 accounts
Write-Host "Sharing AMI permissions to us-east-1 region/accounts..." -ForegroundColor Red
Foreach ($ec2Image in $image) {
    Edit-EC2ImageAttribute -ImageId $ec2Image -Attribute "launchPermission" -OperationType "add" -UserIds "560581309983","025468978248","074275778229","399798447946","877582243023","629125459719","397982773385"
    Write-Host "Permissions added for $ec2Image" -ForegroundColor Yellow
    
    #share snapshot ID as well
    #$snapshot=(Get-EC2Image -ImageId $ec2Image  |Select-Object @{Name="SnapshotId"; Expression={ $_.BlockDeviceMapping.Ebs.SnapshotId}}).SnapshotId
    $AMIdetails=(Get-EC2Image -ImageId $ec2Image  |Select-Object Name,@{Name="SnapshotId"; Expression={ $_.BlockDeviceMapping.Ebs.SnapshotId}})
    $snapID=$AMIdetails.SnapshotId
    $snapname=$AMIdetails.Name
    
    Edit-EC2SnapshotAttribute -SnapshotId $snapID -Attribute "CreateVolumePermission" -OperationType "add" -UserIds "560581309983","025468978248","074275778229","399798447946","877582243023","629125459719","397982773385"
    #Write-Host "Permissions added for $snapID" -ForegroundColor Yellow
    
    $snapID=$AMIdetails.SnapshotId
    $snapname=$AMIdetails.Name
    New-EC2Tag -Resources $snapID -Tags @{ Key = "Name"; Value = $snapname } # Add/overwrite "Name" tag in each snapshot of this AMI
    Write-Host "Permissions and name tag added for $snapID (name: $snapname)" -ForegroundColor Yellow  
}