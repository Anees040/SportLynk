$status = git status --porcelain
foreach ($line in $status) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $action = $line.Substring(0,2)
    $file = $line.Substring(3).Trim()
    if ($file.StartsWith('"') -and $file.EndsWith('"')) {
        $file = $file.Substring(1, $file.Length - 2)
    }
    $basename = Split-Path -Leaf $file
    
    git add $file
    
    $prefix = "test:"
    if ($action -match "D") {
        git commit -m "$prefix remove $basename"
    } elseif ($action -match "M" -or $action -match "A" -or $action -match "\?\?") {
        git commit -m "$prefix add/update $basename"
    } else {
        git commit -m "$prefix sync $basename"
    }
}
git push
