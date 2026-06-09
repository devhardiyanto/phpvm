@{
    Run = @{
        Path     = @('tests')
        PassThru = $true
    }
    Filter = @{
        ExcludeTag = @('Network')
    }
    Output = @{
        Verbosity = 'Detailed'
    }
    Should = @{
        ErrorAction = 'Continue'
    }
}
