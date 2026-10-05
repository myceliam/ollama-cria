#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:Tool = Join-Path $PSScriptRoot '../tools/Test-RecoveryPath.ps1'
    $script:Root = Join-Path $TestDrive 'root'
    New-Item -ItemType Directory -Path (Join-Path $script:Root 'real/inner') -Force | Out-Null

    function Get-Reason {
        param([string]$P, [switch]$Relative, [switch]$SyntaxOnly, [switch]$AllowRoot, [string]$Root = $script:Root)
        (& $script:Tool -Path $P -Root $Root -Relative:$Relative -SyntaxOnly:$SyntaxOnly -AllowRoot:$AllowRoot -Detailed).Reason
    }

    # Junctions need no admin rights on Windows; symbolic links work unprivileged elsewhere.
    function New-TestLink {
        param([string]$LinkPath, [string]$Target)
        if ($IsWindows) { New-Item -ItemType Junction -Path $LinkPath -Target $Target | Out-Null }
        else { New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target | Out-Null }
    }
}

Describe 'Test-RecoveryPath' {

    Context 'ordinary paths pass' {
        It 'accepts <P>' -ForEach @(
            @{ P = 'a.txt' }
            @{ P = 'secrets/ntfy-publisher' }
            @{ P = 'secrets\ntfy-publisher' }
            @{ P = 'folder/' }
            @{ P = 'deep/er/file.name.json' }
            @{ P = 'real/inner/new-file' }
        ) {
            & $script:Tool -Path $P -Root $script:Root -Relative | Should -BeTrue
        }

        It 'accepts an absolute path under the root and reports where it resolves' {
            $r = & $script:Tool -Path (Join-Path $script:Root 'x/y.txt') -Root $script:Root -Detailed
            $r.IsValid | Should -BeTrue
            $r.FullPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:Root 'x/y.txt')))
        }

        It 'accepts the root itself only with -AllowRoot' {
            & $script:Tool -Path $script:Root -Root $script:Root | Should -BeFalse
            Get-Reason $script:Root | Should -Be 'the path is the root itself'
            & $script:Tool -Path $script:Root -Root $script:Root -AllowRoot | Should -BeTrue
        }
    }

    Context 'unsafe names are refused' {
        It 'refuses <P> (<Why>)' -ForEach @(
            @{ P = '../x'; Why = 'parent segment' }
            @{ P = 'a/../../x'; Why = 'parent segment' }
            @{ P = './x'; Why = 'dot segment' }
            @{ P = 'a//b'; Why = 'empty segment' }
            @{ P = 'name.'; Why = 'trailing dot' }
            @{ P = 'name '; Why = 'trailing space' }
            @{ P = 'CON'; Why = 'device name' }
            @{ P = 'con.txt'; Why = 'device name with extension' }
            @{ P = 'a/NUL.json'; Why = 'device name in a folder' }
            @{ P = 'LPT1'; Why = 'device name' }
            @{ P = 'COM9.log'; Why = 'device name' }
            @{ P = 'CONOUT$'; Why = 'console device' }
            @{ P = 'PROGRA~1/x'; Why = '8.3 short name' }
            @{ P = 'f.txt:stream'; Why = 'alternate data stream' }
            @{ P = '*.txt'; Why = 'wildcard' }
            @{ P = 'a?.txt'; Why = 'wildcard' }
            @{ P = 'a|b'; Why = 'pipe' }
            @{ P = ''; Why = 'empty' }
            @{ P = '   '; Why = 'blank' }
        ) {
            & $script:Tool -Path $P -Root $script:Root -Relative | Should -BeFalse
        }

        It 'refuses a control character' {
            & $script:Tool -Path ("a" + [char]9 + "b") -Root $script:Root -Relative | Should -BeFalse
        }

        It 'refuses superscript COM and LPT device names' {
            & $script:Tool -Path ('COM' + [char]0x00B9) -Root $script:Root -Relative | Should -BeFalse
            & $script:Tool -Path ('lpt' + [char]0x00B3 + '.txt') -Root $script:Root -Relative | Should -BeFalse
        }

        It 'refuses a bad name below the root even in an absolute path' {
            Get-Reason (Join-Path $script:Root 'name.') | Should -Be 'a segment ends in a dot or a space'
        }
    }

    Context 'rooted paths' {
        It 'refuses <P> when a relative path is required' -ForEach @(
            @{ P = '/etc/passwd' }
            @{ P = '\Windows\x' }
            @{ P = 'C:\Windows' }
            @{ P = 'C:Windows' }
            @{ P = '\\server\share\x' }
            @{ P = '//server/share' }
        ) {
            Get-Reason $P -Relative | Should -Be 'rooted path where a relative one is required'
        }

        It 'refuses UNC paths without -Relative' {
            Get-Reason '\\server\share\x' | Should -Be 'UNC or device path'
            Get-Reason '//server/share/x' | Should -Be 'UNC or device path'
        }

        It 'refuses device-namespace paths (\\?\ and \\.\)' {
            & $script:Tool -Path '\\?\C:\x' -Root $script:Root | Should -BeFalse
            Get-Reason '\\.\PhysicalDrive0' | Should -Be 'UNC or device path'
        }

        It 'refuses a drive-relative path' {
            Get-Reason 'C:folder' | Should -Be 'drive-relative path (for example C:folder)'
        }

        It 'refuses a sibling folder that shares the root name as a prefix' {
            Get-Reason ($script:Root + 'x/file') | Should -Be 'outside the root'
        }

        It 'refuses an absolute path that climbs out with ..' {
            Get-Reason (Join-Path $script:Root '../elsewhere') | Should -Be "'..' segment"
        }
    }

    Context 'the root' {
        It 'throws for the filesystem root' {
            { & $script:Tool -Path 'x' -Root '/' } | Should -Throw '*too broad*'
        }

        It 'throws for a whole drive' -Skip:(-not $IsWindows) {
            { & $script:Tool -Path 'x' -Root 'C:\' } | Should -Throw '*too broad*'
        }

        It 'throws for a drive-relative root such as E:' {
            { & $script:Tool -Path 'x' -Root 'E:' } | Should -Throw '*absolute*'
        }

        It 'throws for a UNC root' {
            { & $script:Tool -Path 'x' -Root '\\server\share' } | Should -Throw '*UNC*'
        }

        It 'throws for a relative root' {
            { & $script:Tool -Path 'x' -Root 'relative/folder' } | Should -Throw '*absolute*'
        }

        It 'throws for a root with a wildcard' {
            { & $script:Tool -Path 'x' -Root (Join-Path $TestDrive 'r*') } | Should -Throw '*wildcard*'
        }
    }

    Context 'junctions and symbolic links' {
        BeforeAll {
            $script:Outside = Join-Path $TestDrive 'outside'
            New-Item -ItemType Directory -Path $script:Outside -Force | Out-Null
            New-TestLink -LinkPath (Join-Path $script:Root 'escape') -Target $script:Outside

            $script:LinkedRoot = Join-Path $TestDrive 'linked-root'
            New-TestLink -LinkPath $script:LinkedRoot -Target $script:Outside
        }

        It 'refuses a path that passes through a link inside the root' {
            Get-Reason 'escape/file.txt' -Relative | Should -Be 'a junction or symbolic link on the way'
        }

        It 'refuses the link itself' {
            Get-Reason 'escape' -Relative | Should -Be 'a junction or symbolic link on the way'
        }

        It 'refuses everything when the root is a link' {
            Get-Reason 'file.txt' -Relative -Root $script:LinkedRoot | Should -Be 'the root is a junction or symbolic link'
        }

        It 'skips the filesystem checks with -SyntaxOnly' {
            & $script:Tool -Path 'escape/file.txt' -Root $script:Root -Relative -SyntaxOnly | Should -BeTrue
        }
    }

    Context 'several paths at once' {
        It 'refuses two paths that differ only by case' {
            $r = & $script:Tool -Path 'Secrets/A.txt', 'secrets/a.txt' -Root $script:Root -Relative -Detailed
            $r[0].IsValid | Should -BeTrue
            $r[1].IsValid | Should -BeFalse
            $r[1].Reason | Should -Be 'same place as path #1, ignoring case'
        }

        It 'returns $false when any one path fails' {
            & $script:Tool -Path 'ok.txt', '../bad' -Root $script:Root -Relative | Should -BeFalse
        }

        It 'returns one result per path with -Detailed' {
            $r = & $script:Tool -Path 'a', 'b', '../c' -Root $script:Root -Relative -Detailed
            $r | Should -HaveCount 3
            ($r | Where-Object IsValid) | Should -HaveCount 2
        }
    }
}
